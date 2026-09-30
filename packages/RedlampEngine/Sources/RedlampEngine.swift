import CoreGraphics
import Foundation
import Metal
import os
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import Synchronization

/// The concrete rendering engine. UI code only ever sees it as an `EditingEngine`.
///
/// Threading: interactive renders run on one dedicated serial queue. `render(_:)` only
/// swaps the pending request, so a burst of slider events collapses to the newest one.
public final class RedlampEngine: EditingEngine, @unchecked Sendable {
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let kernels: KernelLibrary
    private let renderQueue = DispatchQueue(label: "app.redlamp.engine.render", qos: .userInteractive)
    private let signposts = OSSignposter(subsystem: "app.redlamp.engine", category: .pointsOfInterest)

    private struct RenderState {
        var pending: RenderRequest?
        var isRunning = false
    }

    private let session = Mutex<ImageSession?>(nil)
    private let sessions: SessionCache
    private let openGeneration = Mutex<UInt64>(0)
    private let renderState = Mutex(RenderState())
    private let continuation = Mutex<AsyncStream<RenderedFrame>.Continuation?>(nil)

    // Owned by `renderQueue`.
    private let surfaces: SurfacePool
    private let histogramBuffer: any MTLBuffer
    /// Small whole-photo renders sent with region frames; they also feed the histogram.
    private let overviews: SurfacePool

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              // Background decodes get their own queue so they never delay an interactive render.
              let buildQueue = device.makeCommandQueue(),
              let histogramBuffer = device.makeBuffer(
                  length: 1024 * MemoryLayout<UInt32>.stride,
                  options: .storageModeShared,
              )
        else {
            throw EngineError.gpuUnavailable
        }
        self.device = device
        self.queue = queue
        self.histogramBuffer = histogramBuffer
        kernels = try KernelLibrary(device: device)
        surfaces = SurfacePool(device: device)
        overviews = SurfacePool(device: device)

        let builder = SessionBuilder(device: device, queue: buildQueue, kernels: kernels)
        let signposter = signposts
        sessions = SessionCache(
            budget: min(Int(device.recommendedMaxWorkingSetSize) / 4, 3 << 30),
            build: { url in
                let state = signposter.beginInterval("Open", "\(url.lastPathComponent)")
                defer { signposter.endInterval("Open", state) }
                return try builder.build(ImageDecoder.decode(url))
            },
        )
    }

    // MARK: - Opening

    public func open(_ url: URL) async throws -> ImageInfo {
        let generation = openGeneration.withLock { value in
            value += 1
            return value
        }
        let built = try await sessions.session(for: url)
        guard openGeneration.withLock({ $0 == generation }) else { throw CancellationError() }
        session.withLock { $0 = built }
        return built.info
    }

    public func openIfReady(_ url: URL) -> ImageInfo? {
        guard let ready = sessions.cached(url) else { return nil }
        openGeneration.withLock { $0 += 1 }
        session.withLock { $0 = ready }
        return ready.info
    }

    public func prefetch(_ urls: [URL]) {
        sessions.prefetch(urls)
    }

    // MARK: - Interactive rendering

    public func frames() -> AsyncStream<RenderedFrame> {
        let (stream, newContinuation) = AsyncStream<RenderedFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.withLock { existing in
            existing?.finish()
            existing = newContinuation
        }
        return stream
    }

    public func render(_ request: RenderRequest) {
        let start = renderState.withLock { state -> Bool in
            state.pending = request
            guard !state.isRunning else { return false }
            state.isRunning = true
            return true
        }
        if start {
            renderQueue.async { [self] in drainRenders() }
        }
    }

    private func drainRenders() {
        while true {
            let next = renderState.withLock { state -> RenderRequest? in
                if let pending = state.pending {
                    state.pending = nil
                    return pending
                }
                state.isRunning = false
                return nil
            }
            guard let request = next else { return }
            guard let current = session.withLock({ $0 }) else { continue }
            do {
                let frame = try renderFrame(request, session: current)
                continuation.withLock { _ = $0?.yield(frame) }
            } catch {
                Logger(subsystem: "app.redlamp.engine", category: "render").error("Render failed: \(error)")
            }
        }
    }

    private func renderFrame(_ request: RenderRequest, session: ImageSession) throws -> RenderedFrame {
        let state = signposts.beginInterval("Render")
        defer { signposts.endInterval("Render", state) }
        let clock = ContinuousClock()
        let started = clock.now

        let region = request.region ?? .full
        let size = request.region == nil ? session.orientedSize.fitted(within: request.targetSize) : request.targetSize
        guard size.width > 0, size.height > 0 else { throw EngineError.renderFailed("empty target") }
        let target = try surfaces.next(size: size)
        memset(histogramBuffer.contents(), 0, histogramBuffer.length)

        guard let commands = queue.makeCommandBuffer() else { throw EngineError.gpuUnavailable }
        commands.label = "Interactive render"
        try encodeDevelop(
            request.recipe, session: session, into: target.texture, size: size, region: region,
            encoding: .linear, showClipping: request.showClipping, maskOverlay: request.maskOverlay,
            maskOverlayColor: request.maskOverlayColor,
            commands: commands,
        )
        var overview: SurfacePool.Target?
        var overviewSize = PixelSize.zero
        if request.region == nil {
            try encodeHistogram(texture: target.texture, size: size, linear: true, commands: commands)
        } else {
            overviewSize = session.orientedSize.fitted(within: PixelSize(width: 1024, height: 1024))
            let whole = try overviews.next(size: overviewSize)
            try encodeDevelop(
                request.recipe, session: session, into: whole.texture, size: overviewSize,
                encoding: .linear, showClipping: request.showClipping, maskOverlay: request.maskOverlay,
                maskOverlayColor: request.maskOverlayColor,
                commands: commands,
            )
            try encodeHistogram(texture: whole.texture, size: overviewSize, linear: true, commands: commands)
            overview = whole
        }
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error {
            throw EngineError.renderFailed(error.localizedDescription)
        }

        return RenderedFrame(
            surface: target.surface,
            size: size,
            region: region,
            overview: overview?.surface,
            overviewSize: overviewSize,
            histogram: readHistogram(),
            generation: request.generation,
            renderDuration: clock.now - started,
        )
    }

    private func encodeDevelop(
        _ recipe: EditRecipe,
        session: ImageSession,
        into texture: any MTLTexture,
        size: PixelSize,
        region: ImageRect = .full,
        encoding: OutputEncoding,
        showClipping: Bool,
        maskOverlay: UUID? = nil,
        maskOverlayColor: MaskOverlayColor = .red,
        commands: any MTLCommandBuffer,
    ) throws {
        guard let encoder = commands.makeComputeCommandEncoder() else { throw EngineError.gpuUnavailable }
        var inputs = DevelopParameters.make(
            recipe: recipe, session: session, outputSize: size, region: region, encoding: encoding,
            showClipping: showClipping, maskOverlay: maskOverlay, maskOverlayColor: maskOverlayColor,
        )
        encoder.setComputePipelineState(kernels.develop)
        encoder.setTexture(session.pyramid, index: 0)
        encoder.setTexture(texture, index: 1)
        encoder.setBytes(&inputs.params, length: MemoryLayout<DevelopParams>.stride, index: 0)
        encoder.setBytes(&inputs.toneLUT, length: inputs.toneLUT.count * MemoryLayout<Float>.stride, index: 1)
        encoder.setBytes(&inputs.mixer, length: inputs.mixer.count * MemoryLayout<Float>.stride, index: 2)
        encoder.setBytes(&inputs.layers, length: inputs.layers.count * MemoryLayout<MaskLayerGPU>.stride, index: 3)
        encoder.setBytes(
            &inputs.components, length: inputs.components.count * MemoryLayout<MaskComponentGPU>.stride, index: 4,
        )
        encoder.dispatchGrid(width: size.width, height: size.height, pipeline: kernels.develop)
        encoder.endEncoding()
    }

    private func encodeHistogram(
        texture: any MTLTexture,
        size: PixelSize,
        linear: Bool,
        commands: any MTLCommandBuffer,
    ) throws {
        guard let encoder = commands.makeComputeCommandEncoder() else { throw EngineError.gpuUnavailable }
        let step = max(1, Int((Double(size.width * size.height) / 400_000).squareRoot().rounded(.up)))
        var params = HistogramParams(
            width: UInt32(size.width),
            height: UInt32(size.height),
            step: UInt32(step),
            linearInput: linear,
        )
        encoder.setComputePipelineState(kernels.histogram)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(histogramBuffer, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<HistogramParams>.stride, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: (size.width + step - 1) / step, height: (size.height + step - 1) / step, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1),
        )
        encoder.endEncoding()
    }

    private func readHistogram() -> Histogram {
        let bins = UnsafeBufferPointer(
            start: histogramBuffer.contents().assumingMemoryBound(to: UInt32.self),
            count: 1024,
        )
        return Histogram(
            red: Array(bins[0 ..< 256]),
            green: Array(bins[256 ..< 512]),
            blue: Array(bins[512 ..< 768]),
            luminance: Array(bins[768 ..< 1024]),
        )
    }

    // MARK: - Still rendering

    public func renderStill(_ request: StillRequest) async throws -> CGImage {
        guard let current = session.withLock({ $0 }) else { throw EngineError.noImageOpen }
        return try await withCheckedThrowingContinuation { continuation in
            renderQueue.async { [self] in
                continuation.resume(with: Result { try renderStillNow(request, session: current) })
            }
        }
    }

    private func renderStillNow(_ request: StillRequest, session: ImageSession) throws -> CGImage {
        var size = session.orientedSize
        if let limit = request.maxLongEdge, limit < size.longEdge {
            size = size.fitted(within: PixelSize(width: limit, height: limit))
        }
        let sixteenBit = request.bitsPerComponent > 8
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: sixteenBit ? .rgba16Unorm : .rgba8Unorm,
            width: size.width, height: size.height, mipmapped: false,
        )
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commands = queue.makeCommandBuffer()
        else {
            throw EngineError.gpuUnavailable
        }
        let encoding: OutputEncoding = request.colorSpace == .sRGB ? .sRGB : .displayP3
        try encodeDevelop(
            request.recipe, session: session, into: texture, size: size,
            encoding: encoding, showClipping: false, commands: commands,
        )
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error {
            throw EngineError.renderFailed(error.localizedDescription)
        }

        let bytesPerPixel = sixteenBit ? 8 : 4
        let bytesPerRow = size.width * bytesPerPixel
        var data = Data(count: bytesPerRow * size.height)
        data.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!, bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, size.width, size.height), mipmapLevel: 0,
            )
        }
        let colorSpaceName = request.colorSpace == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
            | (sixteenBit ? CGImageByteOrderInfo.order16Little.rawValue : 0)
        guard let colorSpace = CGColorSpace(name: colorSpaceName),
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: size.width,
                  height: size.height,
                  bitsPerComponent: sixteenBit ? 16 : 8,
                  bitsPerPixel: bytesPerPixel * 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent,
              )
        else {
            throw EngineError.renderFailed("could not create the output image")
        }
        return image
    }

    // MARK: - Analysis

    public func autoWhiteBalance() async -> WhiteBalanceValue? {
        guard let current = session.withLock({ $0 }), let model = current.colorModel else { return nil }
        return ImageAnalysis.autoWhiteBalance(session: current, model: model)
    }

    public func whiteBalance(sampledAt point: CGPoint) async -> WhiteBalanceValue? {
        guard let current = session.withLock({ $0 }), let model = current.colorModel else { return nil }
        return ImageAnalysis.whiteBalance(session: current, model: model, at: SIMD2(point.x, point.y))
    }

    public func autoTone(for recipe: EditRecipe) async -> [ParameterID: Double] {
        guard let current = session.withLock({ $0 }) else { return [:] }
        return ImageAnalysis.autoTone(session: current, recipe: recipe)
    }

    public func thumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        await Task.detached(priority: .utility) {
            Thumbnails.thumbnail(for: url, maxPixelSize: maxPixelSize)
        }.value
    }
}
