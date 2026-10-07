import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders
import os
import RedlampEngineAPI
import RedlampKernels
import RedlampMasking
import RedlampServices
import Synchronization

/// The concrete rendering engine. UI code only ever sees it as an `EditingEngine`.
///
/// Threading: all GPU encoding runs on one dedicated serial queue, which owns the caches and
/// scratch textures. `render(_:)` only swaps the pending request, so a burst of slider events
/// collapses to the newest one. Stills wait in two lanes (previews before exports) and yield
/// between tiles, so the canvas never waits for more than a tile (see `yieldBetweenTiles`).
public final class RedlampEngine: EditingEngine, @unchecked Sendable {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let kernels: KernelLibrary
    let renderQueue = DispatchQueue(label: "app.redlamp.engine.render", qos: .userInteractive)
    static let renderQueueKey = DispatchSpecificKey<Bool>()
    private let signposts = OSSignposter(subsystem: "app.redlamp.engine", category: .pointsOfInterest)

    private struct RenderState {
        var pending: RenderRequest?
        var isRunning = false
        /// The latest request, to render again when a retouched photo's maps are made again.
        var latest: RenderRequest?
    }

    private let session = Mutex<ImageSession?>(nil)
    /// The current photo's analysis render, for AI masks.
    let analysisCache = Mutex<AnalysisCache?>(nil)
    /// Segment Anything, once loaded, and the open photo's embedding.
    let segmenter = Mutex<SAMSegmenter?>(nil)
    let depthModel = Mutex<DepthEstimator?>(nil)
    let depthAnything3Model = Mutex<DepthAnything3?>(nil)
    let depthAnything3Cache = Mutex<(hash: String, result: DepthAnything3.Result)?>(nil)
    let objectEmbeddingCache = Mutex<(hash: String, embedding: SAMSegmenter.Embedding)?>(nil)
    /// SAM 3 for Landscape and people parts, once loaded; the open photo's encoding, and its
    /// class and part masks.
    let sam3Model = Mutex<SAM3Concepts?>(nil)
    let vitMatteModel = Mutex<ViTMatte?>(nil)
    let sam3Features = Mutex<(hash: String, features: SAM3Concepts.Features)?>(nil)
    let landscapeCache = Mutex<(hash: String, classes: [LandscapeClass: GrayMask])?>(nil)
    let peoplePartsCache = Mutex<(hash: String, parts: SAM3Concepts.PeopleParts)?>(nil)
    /// OWLv2, for things found by name, once loaded.
    let thingFinder = Mutex<OWLv2Detector?>(nil)
    /// Each person's matte for the open photo, solved per pixel, which their parts' edges take.
    let personMatteCache = Mutex<(hash: String, mattes: [GrayMask])?>(nil)
    /// The analysis render at the size masks are stored at.
    let matteCache = Mutex<AnalysisCache?>(nil)
    /// Set once the Masking tool has opened: photos opened after get their AI masks ready too.
    let masksWanted = Mutex(false)
    /// What generative fill runs on, once loaded, and the model folder it was loaded from.
    let generativeFiller = Mutex<(directory: URL, filler: any GenerativeFiller)?>(nil)

    func currentSession() -> ImageSession? {
        session.withLock { $0 }
    }

    let sessions: SessionCache
    /// Lets go of cached sessions when the system runs short of memory.
    private let memoryPressure: any DispatchSourceMemoryPressure
    private let openGeneration = Mutex<UInt64>(0)
    private let renderState = Mutex(RenderState())
    let stillLanes = Mutex(StillLanes())
    /// The stills being rendered, innermost last (a preview can run inside an export's yield).
    /// Owned by `renderQueue`.
    var runningStills: [StillJob] = []
    let thermalState: @Sendable () -> ProcessInfo.ThermalState
    private let continuation = Mutex<AsyncStream<RenderedFrame>.Continuation?>(nil)

    // Owned by `renderQueue`.
    private let surfaces: SurfacePool
    private let histogramBuffer: any MTLBuffer
    /// Small whole-photo renders sent with region frames; they also feed the histogram.
    private let overviews: SurfacePool
    /// The request's comparison recipe gets its own rings, so a cached comparison is never
    /// overwritten by the main render.
    private let comparisons: SurfacePool
    private let comparisonOverviews: SurfacePool
    private var comparison: CachedComparison?
    /// The last region frame's overview and histogram, sent again while only the region moves.
    private var lastOverview: CachedOverview?
    private let detailStage: DetailStage
    let retouch: RetouchStage
    let masks: MaskResources
    private let baseLooks: BaseLookRegistry
    let stacks: FocusStackCache
    /// The stages that undo what they recorded for a command buffer that came to nothing.
    private let rollbacks: [any CommandBufferRollback]
    /// Output tile edge for stills, in pixels.
    let stillTile: Int

    public convenience init() throws {
        try self.init(stillTile: 2048)
    }

    /// An engine that decodes photos with `decoder`, such as the Mac app's sandboxed decode service,
    /// and corrects raws that carry no lens correction with the user's `lensProfiles`.
    public convenience init(decoder: any ImageDecoding, lensProfiles: LCPProfileLibrary? = nil) throws {
        try self.init(stillTile: 2048, decoder: decoder, lensProfiles: lensProfiles)
    }

    init(
        stillTile: Int,
        stackCache: URL = FocusStackCache.defaultRoot,
        decoder: any ImageDecoding = InProcessDecoder(),
        lensProfiles: LCPProfileLibrary? = nil,
        thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
    ) throws {
        self.stillTile = stillTile
        self.thermalState = thermalState
        renderQueue.setSpecific(key: Self.renderQueueKey, value: true)
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
        comparisons = SurfacePool(device: device)
        comparisonOverviews = SurfacePool(device: device)
        detailStage = DetailStage(device: device, kernels: kernels)
        retouch = RetouchStage(device: device, kernels: kernels, queue: queue)
        masks = try MaskResources(device: device, kernels: kernels)
        baseLooks = try BaseLookRegistry(device: device)
        rollbacks = [detailStage, retouch, masks]

        let stacks = FocusStackCache(device: device, kernels: kernels, root: stackCache, decoder: decoder)
        self.stacks = stacks
        let builder = SessionBuilder(device: device, queue: buildQueue, kernels: kernels, lensProfiles: lensProfiles)
        let signposter = signposts
        sessions = SessionCache(
            budget: min(Int(device.recommendedMaxWorkingSetSize) / 4, 3 << 30),
            build: { url in
                let state = signposter.beginInterval("Open", "\(url.lastPathComponent)")
                defer { signposter.endInterval("Open", state) }
                return try builder.build(SupportedFormats.isStack(url) ? stacks.decode(url) : decoder.decode(url))
            },
        )
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        pressure.setEventHandler { [weak sessions, weak pressure] in
            guard let pressure else { return }
            sessions?.relieve(pressure.data)
        }
        pressure.resume()
        memoryPressure = pressure
        retouch.onRefresh = { [weak self] in
            guard let latest = self?.renderState.withLock({ $0.latest }) else { return }
            self?.render(latest)
        }
    }

    deinit {
        memoryPressure.cancel()
    }

    // MARK: - Opening

    public func open(_ url: URL) async throws -> ImageInfo {
        let generation = openGeneration.withLock { value in
            value += 1
            return value
        }
        if SupportedFormats.isStack(url) {
            stacks.retryUnreadableFrames(of: url)
        }
        let built = try await sessions.session(for: url)
        let installed = openGeneration.withLock { latest in
            guard !Task.isCancelled, latest == generation else { return false }
            session.withLock { $0 = built }
            return true
        }
        guard installed else { throw CancellationError() }
        registerEmbeddedLook(built)
        warmIfWanted(built)
        return built.info
    }

    public func openIfReady(_ url: URL) -> ImageInfo? {
        guard let ready = sessions.cached(url) else { return nil }
        openGeneration.withLock { latest in
            latest += 1
            session.withLock { $0 = ready }
        }
        registerEmbeddedLook(ready)
        warmIfWanted(ready)
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
            state.latest = request
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
            serveInteractive()
            let done = renderState.withLock { state -> Bool in
                guard state.pending == nil else { return false }
                state.isRunning = false
                return true
            }
            if done {
                return
            }
        }
    }

    /// Renders pending interactive requests until none is left. On `renderQueue` only.
    func serveInteractive() {
        while let request = renderState.withLock({ state -> RenderRequest? in
            defer { state.pending = nil }
            return state.pending
        }) {
            guard let current = session.withLock({ $0 }) else { continue }
            do {
                let frame = try renderFrame(request, session: current)
                continuation.withLock { _ = $0?.yield(frame) }
            } catch {
                Logger(subsystem: "app.redlamp.engine", category: "render").error("Render failed: \(error)")
            }
        }
    }

    func renderFrame(_ request: RenderRequest, session: ImageSession) throws -> RenderedFrame {
        let state = signposts.beginInterval("Render")
        defer { signposts.endInterval("Render", state) }
        let clock = ContinuousClock()
        let started = clock.now

        let region = request.region ?? .full
        let developed = request.recipe.developedSize(imageSize: session.orientedSize)
        let size = request.region == nil ? developed.fitted(within: request.targetSize) : request.targetSize
        guard size.width > 0, size.height > 0 else { throw EngineError.renderFailed("empty target") }
        let target = try surfaces.next(size: size)
        memset(histogramBuffer.contents(), 0, histogramBuffer.length)

        guard let commands = queue.makeCommandBuffer() else { throw EngineError.gpuUnavailable }
        commands.label = "Interactive render"
        var overview: (key: OverviewKey, target: SurfacePool.Target)?
        var reused: CachedOverview?
        var overviewSize = PixelSize.zero
        let compared = try encoding(commands) {
            try encodeDevelop(
                request.recipe, session: session, into: target.texture, size: size, region: region,
                encoding: .linear, showClipping: request.showClipping, maskOverlay: request.maskOverlay,
                maskOverlayColor: request.maskOverlayColor, maskOverlayStyle: request.maskOverlayStyle,
                maskOverlayOpacity: request.maskOverlayOpacity,
                commands: commands, visualizeSpots: request.visualizeSpots,
                visualizePointColor: request.visualizePointColor, retouchMaps: .refreshLater,
            )
            // Visualize Spots and Visualize Range replace the photo in the frame, not in the histogram.
            if request.region == nil, request.visualizeSpots == nil, request.visualizePointColor == nil {
                try encodeHistogram(texture: target.texture, size: size, linear: true, commands: commands)
            } else {
                overviewSize = developed.fitted(within: PixelSize(width: 1024, height: 1024))
                let key = OverviewKey(
                    session: ObjectIdentifier(session), recipe: request.recipe, size: overviewSize,
                    showClipping: request.showClipping, maskOverlay: request.maskOverlay,
                    maskOverlayColor: request.maskOverlayColor, maskOverlayStyle: request.maskOverlayStyle,
                    maskOverlayOpacity: request.maskOverlayOpacity,
                    retouchMaps: retouch.mapsGeneration, looks: baseLooks.generation,
                )
                if let lastOverview, lastOverview.key == key {
                    reused = lastOverview
                } else {
                    let whole = try overviews.next(size: overviewSize)
                    try encodeDevelop(
                        request.recipe, session: session, into: whole.texture, size: overviewSize,
                        encoding: .linear, showClipping: request.showClipping, maskOverlay: request.maskOverlay,
                        maskOverlayColor: request.maskOverlayColor, maskOverlayStyle: request.maskOverlayStyle,
                        maskOverlayOpacity: request.maskOverlayOpacity,
                        commands: commands, retouchMaps: .refreshLater,
                    )
                    try encodeHistogram(texture: whole.texture, size: overviewSize, linear: true, commands: commands)
                    overview = (key, whole)
                }
            }
            // After the histogram, which describes the photo rather than the overlay.
            if request.showRawClipping {
                try encodeRawClipping(
                    request.recipe, session: session, into: target.texture, size: size, region: region,
                    commands: commands,
                )
            }
            return try encodeComparison(
                request, session: session, size: size, overviewSize: overviewSize, commands: commands,
            )
        }
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error {
            comparison = nil
            lastOverview = nil
            rollBack(commands, after: .failed)
            throw EngineError.renderFailed(error.localizedDescription)
        }
        comparison = compared
        let histogram = reused?.histogram ?? readHistogram()
        if let overview {
            lastOverview = CachedOverview(
                key: overview.key, session: session, surface: overview.target.surface, histogram: histogram,
            )
        } else if reused == nil {
            lastOverview = nil
        }

        return RenderedFrame(
            surface: target.surface,
            size: size,
            region: region,
            overview: overview?.target.surface ?? reused?.surface,
            overviewSize: overviewSize,
            comparison: compared?.surface,
            comparisonOverview: compared?.overview,
            histogram: histogram,
            generation: request.generation,
            renderDuration: clock.now - started,
        )
    }

    /// `session` with the recipe's spots in, and from process 10 the maps `maps` asks for; the
    /// photo's before.
    func retouched(
        _ recipe: EditRecipe, session: ImageSession, commands: any MTLCommandBuffer, maps: RetouchStage.Maps,
    ) throws -> ImageSession {
        try retouch.session(
            for: recipe, base: session, commands: commands, maps: recipe.processVersion >= 10 ? maps : .current,
        )
    }

    func encodeDevelop(
        _ recipe: EditRecipe,
        session: ImageSession,
        into texture: any MTLTexture,
        size: PixelSize,
        region: ImageRect = .full,
        encoding: OutputEncoding,
        showClipping: Bool,
        maskOverlay: UUID? = nil,
        maskOverlayColor: MaskOverlayColor = .red,
        maskOverlayStyle: MaskOverlayStyle = .colorOverlay,
        maskOverlayOpacity: Double = MaskOverlayStyle.defaultOpacity,
        commands: any MTLCommandBuffer,
        cacheDetail: Bool = true,
        detail: Bool = true,
        visualizeSpots: Double? = nil,
        visualizePointColor: UUID? = nil,
        pointColorCoverage: Int? = nil,
        retouchMaps: RetouchStage.Maps = .current,
    ) throws {
        let photo = session
        let session = try retouched(recipe, session: photo, commands: commands, maps: retouchMaps)
        let maskBindings = try prepareMasks(
            recipe, session: photo, retouched: session, commands: commands,
            needsGuide: maskOverlay != nil && maskOverlayStyle == .luminanceMap, retouchMaps: retouchMaps,
        )
        let processed = detail ? try detailStage.process(
            recipe, session: session, region: region, outputSize: size, commands: commands, cache: cacheDetail,
            masks: maskBindings,
        ) : nil
        var inputs = DevelopParameters.make(
            recipe: recipe, session: session, baseLook: baseLooks.resolve(recipe.baseLook), outputSize: size,
            region: region, encoding: encoding,
            showClipping: showClipping, maskOverlay: maskOverlay, maskOverlayColor: maskOverlayColor,
            maskOverlayStyle: maskOverlayStyle, maskOverlayOpacity: maskOverlayOpacity, masks: maskBindings,
            visualizePointColor: visualizePointColor, pointColorCoverage: pointColorCoverage,
        )
        let maskPointColors = encoding == .pointColorInput ? nil : try encodeMaskPointColors(
            inputs.pointColorMeasured, recipe: recipe, session: photo, commands: commands, retouchMaps: retouchMaps,
        )
        guard let encoder = commands.makeComputeCommandEncoder() else { throw EngineError.gpuUnavailable }
        inputs.params.denoised = processed?.area ?? .zero
        if let visualizeSpots {
            let sensitivity = Float(min(max(visualizeSpots, 0), 100) / 100)
            inputs.params.spots = SIMD4(1, 0.002 + 0.1 * (1 - sensitivity) * (1 - sensitivity), 0, 0)
        }
        encoder.setComputePipelineState(kernels.develop)
        encoder.setTexture(session.pyramid, index: 0)
        encoder.setTexture(texture, index: 1)
        encoder.setTexture(processed?.texture ?? session.pyramid, index: 2)
        encoder.setTexture(inputs.lookTable ?? baseLooks.identity, index: 3)
        encoder.setTexture(session.hazeMap, index: 4)
        encoder.setTexture(session.glowSource, index: 5)
        encoder.setTexture(session.glowLights, index: 8)
        encoder.setTexture(maskBindings.rasters ?? masks.emptyRasters, index: 6)
        encoder.setTexture(maskBindings.guide ?? masks.emptyGuide, index: 7)
        encoder.setTexture(maskBindings.edges ?? masks.emptyEdges, index: 14)
        encoder.setTexture(maskBindings.colors ?? masks.emptyEdges, index: 15)
        encoder.setTexture(session.hueSatMaps?.cool ?? baseLooks.identity, index: 9)
        encoder.setTexture(session.hueSatMaps?.warm ?? baseLooks.identity, index: 10)
        encoder.setTexture(session.gainTableMap?.texture ?? baseLooks.identity, index: 11)
        encoder.setTexture(session.toneBase, index: 12)
        encoder.setTexture(session.refinedHaze, index: 13)
        encoder.setBytes(&inputs.params, length: MemoryLayout<DevelopParams>.stride, index: 0)
        encoder.setBytes(&inputs.toneLUT, length: inputs.toneLUT.count * MemoryLayout<Float>.stride, index: 1)
        encoder.setBytes(&inputs.mixer, length: inputs.mixer.count * MemoryLayout<Float>.stride, index: 2)
        encoder.setBytes(&inputs.layers, length: inputs.layers.count * MemoryLayout<MaskLayerGPU>.stride, index: 3)
        encoder.setBytes(
            &inputs.lensTable, length: inputs.lensTable.count * MemoryLayout<SIMD4<Float>>.stride, index: 5,
        )
        try encoder.setArray(inputs.components, index: 4, device: device)
        try encoder.setArray(inputs.maskCurves, index: 6, device: device)
        try encoder.setArray(inputs.pointColor, index: 7, device: device)
        if let maskPointColors {
            encoder.setBuffer(maskPointColors, offset: 0, index: 8)
        } else {
            var none = SIMD4<Float>.zero
            encoder.setBytes(&none, length: MemoryLayout<SIMD4<Float>>.stride, index: 8)
        }
        encoder.dispatchGrid(width: size.width, height: size.height, pipeline: kernels.develop)
        encoder.endEncoding()
    }

    /// Paints photosites the sensor clipped over a developed frame (see RawClipping.metal).
    private func encodeRawClipping(
        _ recipe: EditRecipe,
        session: ImageSession,
        into texture: any MTLTexture,
        size: PixelSize,
        region: ImageRect,
        commands: any MTLCommandBuffer,
    ) throws {
        guard let encoder = commands.makeComputeCommandEncoder() else { throw EngineError.gpuUnavailable }
        var inputs = DevelopParameters.make(
            recipe: recipe, session: session, baseLook: baseLooks.resolve(recipe.baseLook), outputSize: size,
            region: region, encoding: .linear, showClipping: false, maskOverlay: nil, maskOverlayColor: .red,
        )
        // Mosaics clip where highlight reconstruction says they did; linear raws were clamped at 1.
        // Both just below, so values rounded to half floats still count.
        let mosaic = session.sensor == .bayer || session.sensor == .xTrans
        var clip = mosaic
            ? SIMD4<Float>(SIMD3<Float>(session.balanceMultipliers) * HighlightModel.clipFraction * 0.998, 1)
            : SIMD4<Float>(0.998, 0.998, 0.998, 0)
        encoder.setComputePipelineState(kernels.rawClipping)
        encoder.setTexture(session.pyramid, index: 0)
        encoder.setTexture(texture, index: 1)
        encoder.setTexture(session.noiseGain, index: 2)
        encoder.setBytes(&inputs.params, length: MemoryLayout<DevelopParams>.stride, index: 0)
        encoder.setBytes(&clip, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.setBytes(
            &inputs.lensTable, length: inputs.lensTable.count * MemoryLayout<SIMD4<Float>>.stride, index: 2,
        )
        encoder.dispatchGrid(width: size.width, height: size.height, pipeline: kernels.rawClipping)
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
        if let source = request.source, source.standardizedFileURL != current.info.url.standardizedFileURL {
            throw EngineError.imageChanged
        }
        let job = StillJob(request: request, session: current)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.continuation.withLock { $0 = continuation }
                schedule(job)
            }
        } onCancel: { [self] in
            cancel(job)
        }
    }

    func renderStillNow(_ request: StillRequest, session: ImageSession) throws -> CGImage {
        let developed = request.recipe.developedSize(imageSize: session.orientedSize)
        var size = developed
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
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
        if request.purpose == .export, size != developed, request.maskOverlay == nil {
            try developDownscaled(request, session: session, into: texture, size: size)
        } else {
            let encoding: OutputEncoding = request.colorSpace == .sRGB ? .sRGB : .displayP3
            try developStill(
                request.recipe, session: session, into: texture, size: size, encoding: encoding,
                maskOverlay: request.maskOverlay, maskOverlayStyle: request.maskOverlayStyle,
            )
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

    public func detectLines() async -> [DetectedLine] {
        guard let current = session.withLock({ $0 }) else { return [] }
        return LineDetector.lines(in: current)
    }

    public func maskColor(sampledAt point: CGPoint, recipe: EditRecipe) async -> SIMD3<Double>? {
        guard let current = session.withLock({ $0 }) else { return nil }
        return await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                continuation.resume(returning: try? sampleEditGuide(at: point, recipe: recipe, session: current))
            }
        }
    }

    public func thumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        let stacks = stacks
        return await Task.detached(priority: .utility) {
            let source = SupportedFormats.isStack(url) ? stacks.thumbnailFrame(for: url) : url
            return source.flatMap { Thumbnails.thumbnail(for: $0, maxPixelSize: maxPixelSize) }
        }.value
    }

    // MARK: - Base Looks

    public func registerBaseLook(_ look: BaseLookDefinition) {
        baseLooks.register(look)
    }

    public func canRender(_ reference: BaseLookReference) -> Bool {
        baseLooks.canRender(reference)
    }

    public func embeddedBaseLook() -> BaseLookDefinition? {
        session.withLock { $0 }?.embeddedLook
    }

    /// Makes the photo's embedded look renderable while it is open.
    private func registerEmbeddedLook(_ session: ImageSession) {
        if let look = session.embeddedLook {
            baseLooks.register(look)
        }
    }
}

// MARK: - Tiled stills

extension RedlampEngine {
    /// Develops a still at `size`, in tiles when a spatial stage needs them.
    private func developStill(
        _ recipe: EditRecipe,
        session: ImageSession,
        into texture: any MTLTexture,
        size: PixelSize,
        encoding: OutputEncoding,
        maskOverlay: UUID? = nil,
        maskOverlayStyle: MaskOverlayStyle = .colorOverlay,
    ) throws {
        if DetailStage.isActive(recipe) {
            try renderTiles(
                recipe, session: session, into: texture, size: size, encoding: encoding,
                maskOverlay: maskOverlay, maskOverlayStyle: maskOverlayStyle,
            )
        } else {
            guard let commands = queue.makeCommandBuffer() else { throw EngineError.gpuUnavailable }
            try self.encoding(commands) {
                try encodeDevelop(
                    recipe, session: session, into: texture, size: size,
                    encoding: encoding, showClipping: false, maskOverlay: maskOverlay,
                    maskOverlayStyle: maskOverlayStyle, commands: commands, retouchMaps: .fresh,
                )
            }
            try finish(commands)
        }
    }

    /// An export below full size: developed at full resolution in linear light, downscaled
    /// (Lanczos), then encoded.
    private func developDownscaled(
        _ request: StillRequest,
        session: ImageSession,
        into texture: any MTLTexture,
        size: PixelSize,
    ) throws {
        let full = request.recipe.developedSize(imageSize: session.orientedSize)
        func linearTexture(_ size: PixelSize) throws -> any MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: size.width, height: size.height, mipmapped: false,
            )
            descriptor.usage = [.shaderWrite, .shaderRead]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
            return texture
        }
        let fullTexture = try linearTexture(full)
        let encoding: OutputEncoding = request.colorSpace == .sRGB ? .linearSRGB : .linear
        try developStill(request.recipe, session: session, into: fullTexture, size: full, encoding: encoding)
        try yieldBetweenTiles()
        let scaled = try linearTexture(size)
        guard let commands = queue.makeCommandBuffer() else { throw EngineError.gpuUnavailable }
        MPSImageLanczosScale(device: device).encode(
            commandBuffer: commands, sourceTexture: fullTexture, destinationTexture: scaled,
        )
        guard let encoder = commands.makeComputeCommandEncoder() else { throw EngineError.gpuUnavailable }
        encoder.setComputePipelineState(kernels.encodeSRGB)
        encoder.setTexture(scaled, index: 0)
        encoder.setTexture(texture, index: 1)
        encoder.dispatchGrid(width: size.width, height: size.height, pipeline: kernels.encodeSRGB)
        encoder.endEncoding()
        try finish(commands)
    }

    /// Develops a still in tiles, so spatial stages only ever need a tile's worth of memory.
    private func renderTiles(
        _ recipe: EditRecipe,
        session: ImageSession,
        into texture: any MTLTexture,
        size: PixelSize,
        encoding: OutputEncoding,
        maskOverlay: UUID? = nil,
        maskOverlayStyle: MaskOverlayStyle = .colorOverlay,
    ) throws {
        let tile = stillTile
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: min(tile, size.width), height: min(tile, size.height),
            mipmapped: false,
        )
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .private
        guard let scratch = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
        for y in stride(from: 0, to: size.height, by: tile) {
            for x in stride(from: 0, to: size.width, by: tile) {
                let tileSize = PixelSize(width: min(tile, size.width - x), height: min(tile, size.height - y))
                let region = ImageRect(
                    x: Double(x) / Double(size.width), y: Double(y) / Double(size.height),
                    width: Double(tileSize.width) / Double(size.width),
                    height: Double(tileSize.height) / Double(size.height),
                )
                guard let commands = queue.makeCommandBuffer() else { throw EngineError.gpuUnavailable }
                try self.encoding(commands) {
                    try encodeDevelop(
                        recipe, session: session, into: scratch, size: tileSize, region: region,
                        encoding: encoding, showClipping: false, maskOverlay: maskOverlay,
                        maskOverlayStyle: maskOverlayStyle, commands: commands, cacheDetail: false, retouchMaps: .fresh,
                    )
                    guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
                    blit.copy(
                        from: scratch, sourceSlice: 0, sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: tileSize.width, height: tileSize.height, depth: 1),
                        to: texture, destinationSlice: 0, destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: x, y: y, z: 0),
                    )
                    blit.endEncoding()
                }
                try finish(commands)
                try yieldBetweenTiles()
            }
        }
    }

    /// Encodes into `commands`; if that fails they are dropped uncommitted, and the stages roll
    /// back what they recorded for them.
    func encoding<T>(_ commands: any MTLCommandBuffer, _ encode: () throws -> T) throws -> T {
        do {
            return try encode()
        } catch {
            rollBack(commands, after: .abandoned)
            throw error
        }
    }

    /// Commits `commands` and waits; if they fail on the GPU, the stages roll back what they
    /// recorded for them.
    func finish(_ commands: any MTLCommandBuffer) throws {
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error {
            rollBack(commands, after: .failed)
            throw EngineError.renderFailed(error.localizedDescription)
        }
    }

    /// What every render error path runs for a command buffer that came to nothing: each stage
    /// undoes what it recorded for it.
    func rollBack(_ commands: any MTLCommandBuffer, after failure: CommandBufferFailure) {
        for stage in rollbacks {
            stage.rollBack(commands, after: failure)
        }
    }
}

// MARK: - Overviews

extension RedlampEngine {
    /// Everything a region frame's overview is rendered from.
    fileprivate struct OverviewKey: Equatable {
        var session: ObjectIdentifier
        var recipe: EditRecipe
        var size: PixelSize
        var showClipping: Bool
        var maskOverlay: UUID?
        var maskOverlayColor: MaskOverlayColor
        var maskOverlayStyle: MaskOverlayStyle
        var maskOverlayOpacity: Double
        var retouchMaps: UInt64
        var looks: UInt64
    }

    struct CachedOverview {
        fileprivate var key: OverviewKey
        /// Keeps the session alive so its identifier can't be reused while cached.
        var session: ImageSession
        var surface: IOSurfaceRef
        var histogram: Histogram
    }
}

// MARK: - Comparison renders

extension RedlampEngine {
    fileprivate struct ComparisonKey: Equatable {
        var session: ObjectIdentifier
        var recipe: EditRecipe
        var size: PixelSize
        var region: ImageRect?
        var showClipping: Bool
        var looks: UInt64
    }

    struct CachedComparison {
        fileprivate var key: ComparisonKey
        /// Keeps the session alive so its identifier can't be reused while cached.
        var session: ImageSession
        var surface: IOSurfaceRef
        var overview: IOSurfaceRef?
    }

    /// The request's comparison recipe, from the cache when nothing it depends on changed.
    func encodeComparison(
        _ request: RenderRequest,
        session: ImageSession,
        size: PixelSize,
        overviewSize: PixelSize,
        commands: any MTLCommandBuffer,
    ) throws -> CachedComparison? {
        guard let recipe = request.comparison?.withGeometry(of: request.recipe) else {
            if comparison != nil {
                comparison = nil
                comparisons.removeAll()
                comparisonOverviews.removeAll()
            }
            return nil
        }
        let key = ComparisonKey(
            session: ObjectIdentifier(session), recipe: recipe, size: size, region: request.region,
            showClipping: request.showClipping, looks: baseLooks.generation,
        )
        if let comparison, comparison.key == key {
            return comparison
        }
        let region = request.region ?? .full
        let target = try comparisons.next(size: size)
        // Cached, so its maps are made once for it, rather than refreshed for the frame.
        try encodeDevelop(
            recipe, session: session, into: target.texture, size: size, region: region,
            encoding: .linear, showClipping: request.showClipping, commands: commands, retouchMaps: .fresh,
        )
        var overview: IOSurfaceRef?
        if request.region != nil {
            let whole = try comparisonOverviews.next(size: overviewSize)
            try encodeDevelop(
                recipe, session: session, into: whole.texture, size: overviewSize,
                encoding: .linear, showClipping: request.showClipping, commands: commands, retouchMaps: .fresh,
            )
            overview = whole.surface
        }
        return CachedComparison(key: key, session: session, surface: target.surface, overview: overview)
    }
}
