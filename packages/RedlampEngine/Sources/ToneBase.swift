import Foundation
import simd

/// The base edge-aware Highlights and Shadows read (TON-05,
/// `docs/plans/2026-10-02-edge-aware-tone-design.md`): each region's brightness, smooth, with its
/// edges kept, so the controls move a region by its brightness and keep the detail inside it.
///
/// A self-guided filter (K. He, J. Sun & X. Tang, "Guided image filtering", 2010) on log
/// luminance. In log space it doesn't depend on exposure: scaling the photo adds a constant to log
/// luminance, and the base moves by the same constant, so `epsilon` is an edge threshold in stops
/// squared that means the same in the shadows as in the highlights. Computed once per photo at
/// `mapLongEdge`, as its two coefficients per texel, which the develop kernel upsamples and
/// applies to each pixel's own log luminance (K. He & J. Sun, "Fast guided filter", 2015), so the
/// base's edges are as sharp as the photo's: `base = a * ev + b`.
///
/// `ev` is the log luminance of the pyramid's camera RGB with `lumaWeights`, before white balance
/// and exposure; the kernel computes it the same way, then moves the base with the pixel into the
/// edit's scene (`base + (sceneEV - ev)`).
enum ToneBase {
    static let mapLongEdge = 512
    /// The filter's window radius, as a fraction of the map's long edge. REDLAMP_TONE_RADIUS
    /// overrides it, to tune.
    static let radiusFraction = Float(ProcessInfo.processInfo.environment["REDLAMP_TONE_RADIUS"] ?? "") ?? 0.03
    /// Detail below this variance (stops squared) is texture and stays in the detail; edges above
    /// it are kept in the base. REDLAMP_TONE_EPSILON overrides it, to tune.
    static let epsilon = Float(ProcessInfo.processInfo.environment["REDLAMP_TONE_EPSILON"] ?? "") ?? 0.25
    /// Camera RGB to a luminance for the base: green-weighted, independent of the edit.
    static let lumaWeights = SIMD3<Float>(0.25, 0.5, 0.25)

    static func logLuminance(_ rgb: SIMD3<Float>) -> Float {
        log2(max(simd_dot(rgb, lumaWeights), 1e-6))
    }

    /// The filter's coefficients for `image` at the map's size: the base is `a * ev + b`.
    static func coefficients(_ image: AnalysisImage) -> GuidedMap {
        let scale = max(1, (Double(max(image.width, image.height)) / Double(mapLongEdge)).rounded(.up))
        let block = Int(scale)
        let width = max(1, (image.width + block - 1) / block)
        let height = max(1, (image.height + block - 1) / block)
        // Log luminance averaged over each block: the map's own image.
        var ev = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                var sum: Float = 0
                var count: Float = 0
                for sy in y * block ..< min((y + 1) * block, image.height) {
                    for sx in x * block ..< min((x + 1) * block, image.width) {
                        sum += logLuminance(image.pixel(x: sx, y: sy))
                        count += 1
                    }
                }
                ev[y * width + x] = count > 0 ? sum / count : 0
            }
        }
        return coefficients(ev, width: width, height: height)
    }

    /// A self-guided filter's coefficients for log luminance `ev`.
    static func coefficients(_ ev: [Float], width: Int, height: Int) -> GuidedMap {
        let radius = max(1, Int((Float(max(width, height)) * radiusFraction).rounded()))
        return GuidedMap(
            input: ev, guide: ev, width: width, height: height, radius: radius, epsilon: epsilon,
        )
    }
}
