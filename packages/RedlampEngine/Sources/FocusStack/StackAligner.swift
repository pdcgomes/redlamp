import Foundation
import simd

/// What alignment needs from one frame: a small linear RGB copy and its encoded luminance.
struct FrameAnalysis {
    /// Linear, balanced camera RGB, downscaled.
    let rgb: [SIMD3<Float>]
    /// Square-root-encoded luminance of `rgb`: closer to perceptual, so dark detail counts.
    let luma: LumaImage
    /// Full-resolution pixels per analysis pixel.
    let factor: Float

    init(width: Int, height: Int, rgb: [SIMD3<Float>], factor: Float) {
        self.rgb = rgb
        self.factor = factor
        let weights = SIMD3<Float>(0.25, 0.5, 0.25)
        luma = LumaImage(width: width, height: height, pixels: rgb.map { simd_dot($0, weights).squareRoot() })
    }
}

/// Where every frame of a stack sits relative to the reference, and how bright it is.
struct StackAlignment: Equatable, Codable {
    /// The reference frame: the narrowest field of view, so every other frame is scaled down into it.
    var reference: Int
    /// Per frame, reference pixel coordinates to that frame's pixel coordinates, at full resolution.
    var transforms: [Similarity]
    /// Per frame, the per-channel gain that matches its brightness to the reference.
    var gains: [SIMD3<Float>]
    /// Per frame, ECC's correlation with the reference after alignment (1 for the reference).
    var correlations: [Float]
}

enum StackAligner {
    /// Below this correlation against the reference, a frame keeps its chained transform: frames
    /// focused far from the reference share too little sharp detail to align to it directly.
    static let minimumDirectCorrelation: Float = 0.5

    /// Aligns frames given in focus order (either direction).
    static func align(_ frames: [FrameAnalysis]) -> StackAlignment {
        precondition(!frames.isEmpty)
        // Chain: each frame to its neighbour, so consecutive frames (similar focus) do the matching.
        var chained = [Similarity.identity]
        for index in 1 ..< frames.count {
            let step = ECCAligner.align(template: frames[index - 1].luma, image: frames[index].luma)
            chained.append(step.transform.composed(after: chained[index - 1]))
        }
        // The frame whose content appears largest has the narrowest view (focus breathing).
        let reference = chained.last!.scale > 1 ? frames.count - 1 : 0
        let toReference = chained[reference].inverse

        var transforms: [Similarity] = []
        var correlations: [Float] = []
        for index in frames.indices {
            let initial = chained[index].composed(after: toReference)
            if index == reference {
                transforms.append(.identity)
                correlations.append(1)
                continue
            }
            let direct = ECCAligner.align(template: frames[reference].luma, image: frames[index].luma, initial: initial)
            let useDirect = direct.correlation >= minimumDirectCorrelation
            transforms.append(useDirect ? direct.transform : initial)
            correlations.append(direct.correlation)
        }
        let gains = frames.indices.map { gain(frames[$0], to: frames[reference], transform: transforms[$0]) }
        let fullTransforms = transforms.enumerated().map { index, transform in
            fullResolution(transform, factor: frames[index].factor)
        }
        return StackAlignment(
            reference: reference,
            transforms: fullTransforms,
            gains: gains,
            correlations: correlations,
        )
    }

    /// An analysis-resolution transform at full resolution, with pixel centres mapped exactly:
    /// analysis x_a = (x_f + 0.5) / factor - 0.5.
    static func fullResolution(_ transform: Similarity, factor: Float) -> Similarity {
        let toAnalysis = Similarity(a: 1 / factor, b: 0, tx: 0.5 / factor - 0.5, ty: 0.5 / factor - 0.5)
        return toAnalysis.inverse.composed(after: transform.composed(after: toAnalysis))
    }

    /// Per-channel gain matching `frame` to `reference` over their overlap, in linear light.
    static func gain(_ frame: FrameAnalysis, to reference: FrameAnalysis, transform: Similarity) -> SIMD3<Float> {
        let width = reference.luma.width
        let height = reference.luma.height
        var sumReference = SIMD3<Double>.zero
        var sumFrame = SIMD3<Double>.zero
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let (u, v) = transform.apply(Float(x), Float(y))
                let fx = Int(u.rounded())
                let fy = Int(v.rounded())
                guard fx >= 0, fy >= 0, fx < frame.luma.width, fy < frame.luma.height else { continue }
                let r = reference.rgb[y * width + x]
                let f = frame.rgb[fy * frame.luma.width + fx]
                // Clipped or black areas say nothing about exposure.
                guard r.max() < 0.95, f.max() < 0.95, r.min() > 0.002, f.min() > 0.002 else { continue }
                sumReference += SIMD3<Double>(r)
                sumFrame += SIMD3<Double>(f)
            }
        }
        guard sumFrame.min() > 0 else { return SIMD3(repeating: 1) }
        return SIMD3<Float>(sumReference / sumFrame)
    }
}
