import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels

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
