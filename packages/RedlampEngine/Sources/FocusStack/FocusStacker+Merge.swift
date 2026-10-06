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

/// What a merge's first pass finds, which no merge method changes: where each frame sits, and
/// which is sharpest where.
struct StackAnalysis {
    let alignment: StackAlignment
    let depth: StackDepthMap
    /// The frames' size, in pixels.
    let width: Int
    let height: Int
}

extension FocusStacker {
    /// Merges `frameCount` frames in focus order. `load` returns frame `index` as balanced linear
    /// camera RGB; it is called twice per frame (analysis, then fusion) so only one frame is held
    /// at a time, or once, for fusion, when `analysed` holds the frames' first pass. `progress`
    /// receives 0 ... 1.
    func merge(
        frameCount: Int,
        settings: StackMergeSettings = StackMergeSettings(),
        analysed: StackAnalysis? = nil,
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
        let analysis = try analysed ?? analyse(frameCount: frameCount, load: load, lap: lap, progress: progress)
        let alignment = analysis.alignment
        let depthTexture = try makeDepthTexture(analysis.depth)
        progress(0.5)

        // Pass 2: warp and fuse, one frame at a time.
        let pyramid = try FusionPyramid(
            stacker: self,
            width: analysis.width,
            height: analysis.height,
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
        return StackMergeResult(fused: fused, alignment: alignment, depth: analysis.depth, timings: timings)
    }

    /// Pass 1: an analysis copy of every frame, from which the frames are aligned and the depth
    /// map solved.
    private func analyse(
        frameCount: Int, load: (Int) throws -> any MTLTexture, lap: (String) -> Void, progress: (Double) -> Void,
    ) throws -> StackAnalysis {
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
        lap("depth")
        return StackAnalysis(alignment: alignment, depth: depth, width: size.width, height: size.height)
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
