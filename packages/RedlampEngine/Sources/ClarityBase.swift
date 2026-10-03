import Foundation
import simd

/// Edge-aware Clarity's base (process 9, TON-06,
/// `docs/plans/2026-10-03-edge-aware-clarity-design.md`): the coarse end of Clarity's band, kept
/// sharp across edges. A self-guided filter on log luminance at Clarity's scale, so inside a
/// region it's the local mean, as the pyramid's level 6 is, and across an edge stronger than
/// `epsilon` it keeps the edge, so the band and its halo go to zero there.
///
/// Computed once per photo from the analysis image, as the filter's two coefficients per texel;
/// the detail stage applies them to the band's fine level, `base = a * fine + b`, with log
/// luminance from `ToneBase.lumaWeights` in both.
enum ClarityBase {
    /// The filter's window radius in full-resolution pixels: Clarity's coarse end (a level 6
    /// texel spans 64). REDLAMP_CLARITY_RADIUS overrides it, to tune.
    static let radiusPixels = Float(ProcessInfo.processInfo.environment["REDLAMP_CLARITY_RADIUS"] ?? "") ?? 32
    /// Detail below this variance (stops squared) is Clarity's to boost; edges above it are kept
    /// in the base. REDLAMP_CLARITY_EPSILON overrides it, to tune.
    static let epsilon = Float(ProcessInfo.processInfo.environment["REDLAMP_CLARITY_EPSILON"] ?? "") ?? 0.25
    /// Clarity's gain on the band (per-level Clarity's is 0.7): the filter keeps part of strong
    /// texture in the base, so the band is smaller. REDLAMP_CLARITY_GAIN overrides it, to tune.
    static let gain = Float(ProcessInfo.processInfo.environment["REDLAMP_CLARITY_GAIN"] ?? "") ?? 1.25
    /// Added to luminance before the log, as the detail stage does (`DetailStage.luma`).
    static let floor: Float = 1.0 / 1024

    static func logLuminance(_ rgb: SIMD3<Float>) -> Float {
        log2(max(simd_dot(rgb, ToneBase.lumaWeights), 0) + floor)
    }

    /// The coefficients for `image`, a photo `fullLongEdge` pixels on its long side.
    static func coefficients(_ image: AnalysisImage, fullLongEdge: Int) -> GuidedMap {
        coefficients(
            image.pixels.map(logLuminance), width: image.width, height: image.height, fullLongEdge: fullLongEdge,
        )
    }

    static func coefficients(_ ev: [Float], width: Int, height: Int, fullLongEdge: Int) -> GuidedMap {
        let scale = Float(max(width, height)) / Float(max(fullLongEdge, 1))
        let radius = max(1, Int((radiusPixels * scale).rounded()))
        return GuidedMap(input: ev, guide: ev, width: width, height: height, radius: radius, epsilon: epsilon)
    }
}
