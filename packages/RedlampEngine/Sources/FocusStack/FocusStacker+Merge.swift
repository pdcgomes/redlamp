import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import simd

struct StackMergeSettings {
    var strategy = FocusStackStrategy.auto
    /// Auto: frames within this many of the depth estimate compete for fine detail.
    var window: Float = 2
    /// Auto: detail from outside the window wins only when this many times as salient (on the
    /// squared-luma salience of the prototype).
    var release: Float = 1.5
    /// Auto: on the two finest levels, detail below this many noise sigmas takes the depth blend.
    var noiseK: Float = 3
}

struct StackMergeResult {
    /// `.rgba16Float`, balanced linear camera RGB in the reference's geometry; alpha is 1 where
    /// every frame has data.
    let fused: any MTLTexture
    let alignment: StackAlignment
    let depth: StackDepthMap
    /// Seconds per phase.
    let timings: [String: Double]
}

extension FocusStacker {
    /// Merges `frameCount` frames in focus order. `load` returns frame `index` as balanced linear
    /// camera RGB; it is called twice per frame (analysis, then fusion) so only one frame is held
    /// at a time. `progress` receives 0 ... 1.
    func merge(
        frameCount: Int,
        settings: StackMergeSettings = StackMergeSettings(),
        load: (Int) throws -> any MTLTexture,
        progress: (Double) -> Void = { _ in },
    ) throws -> StackMergeResult {
        precondition(frameCount > 0)
        var timings: [String: Double] = [:]
        var clock = Date()
        func lap(_ phase: String) {
            timings[phase, default: 0] += Date().timeIntervalSince(clock)
            clock = Date()
        }

        // Pass 1: an analysis copy of every frame.
        var analyses: [FrameAnalysis] = []
        var size = (width: 0, height: 0)
        for index in 0 ..< frameCount {
            // Each frame's textures and buffers go as soon as it's done, not when the merge is.
            try autoreleasepool {
                let frame = try load(index)
                lap("decode")
                size = (frame.width, frame.height)
                try analyses.append(analyse(frame))
                lap("align")
            }
            progress(0.4 * Double(index + 1) / Double(frameCount))
        }
        let alignment = StackAligner.align(analyses)
        lap("align")
        // Sharpness is measured where each frame was captured and only then resampled: warping
        // softens every frame but the reference, which would then look sharpest everywhere.
        // Brightness is matched first (focus breathing changes exposure too), or where nothing
        // is sharp the brightest frame wins. Where a frame doesn't reach, it offers nothing.
        let depthSettings = StackDepthSolver.Settings()
        let aligned = Parallel.map(frameCount) { [analyses] index in
            let analysis = analyses[index]
            let gain = dot(alignment.gains[index], SIMD3<Float>(0.25, 0.5, 0.25)).squareRoot()
            var luma = analysis.luma.halved().halved()
            luma.pixels = luma.pixels.map { $0 * gain }
            let factor = analysis.factor * Float(analysis.luma.width) / Float(luma.width)
            let transform = StackAligner.analysisResolution(alignment.transforms[index], factor: factor)
            var focus = LumaImage(
                width: luma.width, height: luma.height,
                pixels: StackDepthSolver.sumModifiedLaplacian(luma, radius: depthSettings.focusRadius),
            )
            // A clipped highlight has hard edges in whichever frame blew it out, so it says
            // nothing about focus there.
            Self.ignoreClipped(&focus, colour: analysis, radius: depthSettings.focusRadius + 1)
            return (StackAligner.warp(focus, by: transform, outside: 0).pixels, StackAligner.warp(luma, by: transform))
        }
        let depth = StackDepthSolver.solve(volume: aligned.map(\.0), lumas: aligned.map(\.1), settings: depthSettings)
        let depthTexture = try makeDepthTexture(depth)
        lap("depth")
        progress(0.5)

        // Pass 2: warp and fuse, one frame at a time.
        let pyramid = try FusionPyramid(
            stacker: self,
            width: size.width,
            height: size.height,
            strategy: settings.strategy,
        )
        var grit: Float = 0
        for index in 0 ..< frameCount {
            try autoreleasepool {
                let frame = try load(index)
                lap("decode")
                guard let commands = queue.makeCommandBuffer() else { throw EngineError.gpuUnavailable }
                commands.label = "Stack fuse \(index)"
                try encodeWarp(
                    frame, transform: alignment.transforms[index], gain: alignment.gains[index],
                    into: pyramid.warped, commands: commands,
                )
                try pyramid.encodeFrame(index, depth: depthTexture, settings: settings, commands: commands)
                commands.commit()
                commands.waitUntilCompleted()
                if let error = commands.error {
                    throw EngineError.renderFailed(error.localizedDescription)
                }
                if index == alignment.reference, settings.strategy == .auto {
                    grit = try settings.noiseK * pyramid.finestNoiseSigma()
                }
                lap("fuse")
            }
            progress(0.5 + 0.45 * Double(index + 1) / Double(frameCount))
        }
        let fused = try pyramid.finish(frames: frameCount, settings: settings, grit: grit)
        lap("fuse")
        progress(1)
        timings["total"] = timings.values.reduce(0, +)
        return StackMergeResult(fused: fused, alignment: alignment, depth: depth, timings: timings)
    }

    /// Balanced green at or above this is treated as clipped (green clips first after white
    /// balance; averaged over 4 x 4 analysis pixels, a clipped edge reads a little lower).
    static let clipLevel: Float = 0.9

    /// Zeroes `focus` within `radius` of any clipped pixel of the frame's colour copy, which is on
    /// the same grid.
    static func ignoreClipped(_ focus: inout LumaImage, colour analysis: FrameAnalysis, radius: Int) {
        let (w, h) = (min(focus.width, analysis.colourWidth), min(focus.height, analysis.colourHeight))
        for y in 0 ..< h {
            for x in 0 ..< w where analysis.colour[y * analysis.colourWidth + x].y >= clipLevel {
                for dy in max(y - radius, 0) ... min(y + radius, focus.height - 1) {
                    for dx in max(x - radius, 0) ... min(x + radius, focus.width - 1) {
                        focus.pixels[dy * focus.width + dx] = 0
                    }
                }
            }
        }
    }

    /// The depth map as a shared `.r32Float` texture, sampled bilinearly by the fusion kernels.
    func makeDepthTexture(_ depth: StackDepthMap) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: depth.width, height: depth.height, mipmapped: false,
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
        depth.depth.withUnsafeBytes {
            texture.replace(
                region: MTLRegionMake2D(0, 0, depth.width, depth.height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: depth.width * 4,
            )
        }
        return texture
    }

    func makeTexture(_ format: MTLPixelFormat, _ width: Int, _ height: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: max(1, width), height: max(1, height), mipmapped: false,
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
        return texture
    }
}

/// The full-resolution working set of a merge: the warped frame, its Gaussian and Laplacian
/// pyramids, and the strategy's accumulators, all half floats. Levels follow the prototype:
/// max(3, floor(log2(short edge)) - 5) detail levels; the two coarsest come from the depth blend.
final class FusionPyramid {
    let stacker: FocusStacker
    let strategy: FocusStackStrategy
    let levels: Int
    let coarseFrom: Int
    /// The current frame, warped into the reference (alpha: coverage). Also Gaussian level 0.
    let warped: any MTLTexture
    /// Gaussian levels 1 ... levels (index 0 is `warped`).
    private var gaussians: [any MTLTexture] = []
    /// Laplacian levels 0 ..< levels.
    private var details: [any MTLTexture] = []
    /// Smooth's image-domain blend; its alpha tracks coverage for every strategy.
    let smooth: any MTLTexture
    /// Auto: the depth blend per level (0 ... levels) and the near/far candidates on fine levels.
    private var blends: [any MTLTexture] = []
    private var nears: [any MTLTexture] = []
    private var fars: [any MTLTexture] = []
    /// Detail: the most salient coefficient per level; the last holds the sum of the base.
    private var bests: [any MTLTexture] = []
    private let placeholder: any MTLTexture

    init(stacker: FocusStacker, width: Int, height: Int, strategy: FocusStackStrategy) throws {
        self.stacker = stacker
        self.strategy = strategy
        levels = max(3, Int(log2(Double(min(width, height)))) - 5)
        coarseFrom = levels - 2
        var sizes = [(width, height)]
        for _ in 0 ..< levels {
            let (w, h) = sizes.last!
            sizes.append(((w + 1) / 2, (h + 1) / 2))
        }
        warped = try stacker.makeTexture(.rgba16Float, width, height)
        smooth = try stacker.makeTexture(.rgba16Float, width, height)
        placeholder = try stacker.makeTexture(.rgba16Float, 1, 1)
        guard strategy != .smooth else { return }
        gaussians = try [warped] + sizes.dropFirst().map { try stacker.makeTexture(.rgba16Float, $0.0, $0.1) }
        details = try sizes.dropLast().map { try stacker.makeTexture(.rgba16Float, $0.0, $0.1) }
        switch strategy {
        case .auto:
            blends = try sizes.map { try stacker.makeTexture(.rgba16Float, $0.0, $0.1) }
            nears = try sizes.prefix(coarseFrom).map { try stacker.makeTexture(.rgba16Float, $0.0, $0.1) }
            fars = try sizes.prefix(coarseFrom).map { try stacker.makeTexture(.rgba16Float, $0.0, $0.1) }
        case .detail:
            bests = try sizes.map { try stacker.makeTexture(.rgba16Float, $0.0, $0.1) }
        case .smooth:
            break
        }
    }

    private var kernels: KernelLibrary {
        stacker.kernels
    }

    private func dispatch(
        _ encoder: any MTLComputeCommandEncoder,
        _ pipeline: any MTLComputePipelineState,
        _ textures: [any MTLTexture],
        grid: any MTLTexture,
        params: StackFuseParams? = nil,
    ) {
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        if var params {
            encoder.setBytes(&params, length: MemoryLayout<StackFuseParams>.stride, index: 0)
        }
        encoder.dispatchGrid(width: grid.width, height: grid.height, pipeline: pipeline)
    }

    /// Adds the warped frame `index` to the accumulators.
    func encodeFrame(
        _ index: Int, depth: any MTLTexture, settings: StackMergeSettings, commands: any MTLCommandBuffer,
    ) throws {
        guard let encoder = commands.makeComputeCommandEncoder() else { throw EngineError.gpuUnavailable }
        encoder.label = "Stack accumulate"
        let first: Int32 = index == 0 ? 1 : 0
        let frame = Float(index)
        dispatch(
            encoder, kernels.stackFuseSmooth, [warped, depth, smooth], grid: warped,
            params: StackFuseParams(frame: SIMD4(frame, 0, 0, 0), flags: SIMD4(0, 0, first, 0)),
        )
        if strategy != .smooth {
            for level in 0 ..< levels {
                dispatch(
                    encoder,
                    kernels.stackPyramidDown,
                    [gaussians[level], gaussians[level + 1]],
                    grid: gaussians[level + 1],
                )
            }
            for level in 0 ..< levels {
                dispatch(
                    encoder, kernels.stackLaplacian, [gaussians[level], gaussians[level + 1], details[level]],
                    grid: details[level],
                )
            }
        }
        switch strategy {
        case .auto:
            let window = settings.window
            for level in 0 ... levels {
                let selects = level < coarseFrom
                let source = level < levels ? details[level] : gaussians[levels]
                dispatch(
                    encoder, kernels.stackFuseAuto,
                    [
                        source,
                        depth,
                        blends[level],
                        selects ? nears[level] : placeholder,
                        selects ? fars[level] : placeholder,
                    ],
                    grid: source,
                    params: StackFuseParams(
                        frame: SIMD4(frame, window, 0, 0),
                        flags: SIMD4(selects ? 1 : 0, 0, first, 0),
                    ),
                )
            }
        case .detail:
            for level in 0 ... levels {
                let source = level < levels ? details[level] : gaussians[levels]
                dispatch(
                    encoder, kernels.stackFuseDetail, [source, bests[level]], grid: source,
                    params: StackFuseParams(
                        frame: SIMD4(frame, 0, 0, 0),
                        flags: SIMD4(level < levels ? 1 : 0, 0, first, 0),
                    ),
                )
            }
        case .smooth:
            break
        }
        encoder.endEncoding()
    }

    /// The noise of the finest Laplacian level of the frame just added (the reference): the
    /// median absolute luma of a central crop over 0.6745, a robust sigma.
    func finestNoiseSigma() throws -> Float {
        let finest = details[0]
        let side = min(512, finest.width, finest.height)
        let origin = MTLOrigin(x: (finest.width - side) / 2, y: (finest.height - side) / 2, z: 0)
        let rowBytes = side * 8
        guard let buffer = stacker.device.makeBuffer(length: rowBytes * side, options: .storageModeShared),
              let commands = stacker.queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else {
            throw EngineError.gpuUnavailable
        }
        blit.copy(
            from: finest, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin,
            sourceSize: MTLSize(width: side, height: side, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * side,
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let halves = buffer.contents().assumingMemoryBound(to: Float16.self)
        var values = (0 ..< side * side).map { index in
            abs(0.25 * Float(halves[index * 4]) + 0.5 * Float(halves[index * 4 + 1]) + 0.25 *
                Float(halves[index * 4 + 2]))
        }
        values.sort()
        return values[values.count / 2] / 0.6745
    }

    /// Collapses the accumulators into the fused image.
    func finish(frames: Int, settings: StackMergeSettings, grit: Float) throws -> any MTLTexture {
        let fused = try stacker.makeTexture(.rgba16Float, warped.width, warped.height)
        guard let commands = stacker.queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder()
        else {
            throw EngineError.gpuUnavailable
        }
        commands.label = "Stack finish"
        switch strategy {
        case .smooth:
            dispatch(encoder, kernels.stackFinish, [smooth, smooth, fused], grid: fused)
        case .auto:
            // Salience is stored as a root, so the release ratio compares roots.
            let release = settings.release.squareRoot()
            var chosen: [any MTLTexture] = []
            for level in 0 ..< levels {
                guard level < coarseFrom else {
                    chosen.append(blends[level])
                    continue
                }
                dispatch(
                    encoder, kernels.stackChooseAuto, [blends[level], nears[level], fars[level], details[level]],
                    grid: details[level],
                    params: StackFuseParams(
                        frame: SIMD4(0, 0, release, grit),
                        flags: SIMD4(0, level <= 1 ? 1 : 0, 0, 0),
                    ),
                )
                chosen.append(details[level])
            }
            collapse(encoder, base: blends[levels], details: chosen)
            dispatch(encoder, kernels.stackFinish, [warped, smooth, fused], grid: fused)
        case .detail:
            dispatch(
                encoder, kernels.stackScale, [bests[levels]], grid: bests[levels],
                params: StackFuseParams(frame: SIMD4(1 / Float(frames), 0, 0, 0)),
            )
            collapse(encoder, base: bests[levels], details: Array(bests.prefix(levels)))
            dispatch(encoder, kernels.stackFinish, [warped, smooth, fused], grid: fused)
        }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error {
            throw EngineError.renderFailed(error.localizedDescription)
        }
        return fused
    }

    /// Rebuilds level 0 into `warped` from `base` and the per-level `details`, coarsest first,
    /// using the Gaussian levels as scratch.
    private func collapse(_ encoder: any MTLComputeCommandEncoder, base: any MTLTexture, details: [any MTLTexture]) {
        var current = base
        for level in (0 ..< levels).reversed() {
            let output = level == 0 ? warped : gaussians[level]
            dispatch(encoder, kernels.stackCollapse, [current, details[level], output], grid: output)
            current = output
        }
    }
}
