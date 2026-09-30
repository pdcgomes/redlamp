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
        let steps = Parallel.map(frames.count - 1) { index in
            ECCAligner.align(template: frames[index].luma, image: frames[index + 1].luma).transform
        }
        var chained = [Similarity.identity]
        for step in steps {
            chained.append(step.composed(after: chained.last!))
        }
        // The frame whose content appears largest has the narrowest view (focus breathing).
        let reference = chained.last!.scale > 1 ? frames.count - 1 : 0
        let toReference = chained[reference].inverse
        let initials = chained.map { $0.composed(after: toReference) }

        let refined = Parallel.map(frames.count) { index -> (Similarity, Float) in
            guard index != reference else { return (.identity, 1) }
            let direct = ECCAligner.align(
                template: frames[reference].luma, image: frames[index].luma, initial: initials[index],
            )
            let useDirect = direct.correlation >= minimumDirectCorrelation
            return (useDirect ? direct.transform : initials[index], direct.correlation)
        }
        let transforms = refined.map(\.0)
        let correlations = refined.map(\.1)
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

    /// The inverse of `fullResolution(_:factor:)`: a full-resolution transform at analysis resolution.
    static func analysisResolution(_ transform: Similarity, factor: Float) -> Similarity {
        let toAnalysis = Similarity(a: 1 / factor, b: 0, tx: 0.5 / factor - 0.5, ty: 0.5 / factor - 0.5)
        return toAnalysis.composed(after: transform.composed(after: toAnalysis.inverse))
    }

    /// `image` resampled into the reference's geometry (bilinear): `transform` maps reference
    /// pixels to the image's. Outside the image, `outside` if given, else the nearest edge.
    static func warp(_ image: LumaImage, by transform: Similarity, outside: Float? = nil) -> LumaImage {
        let width = image.width
        let height = image.height
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let (u, v) = transform.apply(Float(x), Float(y))
                if let outside, image.sample(u, v) == nil {
                    pixels[y * width + x] = outside
                    continue
                }
                let cu = min(max(u, 0), Float(width - 1))
                let cv = min(max(v, 0), Float(height - 1))
                pixels[y * width + x] = image.sample(cu, cv) ?? 0
            }
        }
        return LumaImage(width: width, height: height, pixels: pixels)
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
