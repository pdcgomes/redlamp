import Foundation
import RedlampEngineAPI
import RedlampKernels

/// Point Color's sliders in the develop kernel's units (TON-29, `docs/plans/2026-10-05-point-color-design.md`).
enum PointColorMath {
    /// Where the selection ends on each axis: hue in degrees, chroma in stops either side of the
    /// swatch's, lightness in OKLab units. At the defaults (50) a swatch selects hue within 47.5°.
    static func halfWidths(_ swatch: PointColorSwatch) -> SIMD3<Double> {
        SIMD3(
            5 + 85 * swatch[.pointColorHueRange] / 100,
            0.25 + 2.75 * swatch[.pointColorSaturationRange] / 100,
            0.05 + 0.95 * swatch[.pointColorLuminanceRange] / 100,
        )
    }

    /// The share of each half-width over which the selection fades out (Smoothness).
    static func fade(_ swatch: PointColorSwatch) -> Double {
        0.1 + 0.9 * swatch[.pointColorSmoothness] / 100
    }

    /// The most a push (Uniformity below 0) may scale distances from the swatch's colour, as
    /// `1 + limit · weight`, while the mapping's slope stays at least `floor`, so colours keep their
    /// order across the range's fading edge. The slope of `d ↦ d (1 + k w(d))` is `1 + k (w + d w′)`,
    /// which in units of the half-width depends only on the fade.
    static func pushLimit(fade: Double, floor: Double = 0.25, cap: Double = 2) -> Double {
        var steepest = 0.0
        for step in 0 ... 512 {
            let t = Double(step) / 512
            let x = 1 - fade + fade * t
            let weight = 1 - t * t * (3 - 2 * t)
            let slope = -6 * t * (1 - t) / fade
            steepest = max(steepest, -(weight + x * slope))
        }
        return steepest > 0 ? min((1 - floor) / steepest, cap) : cap
    }

    /// The swatch as the kernel reads it; nil for a mask's own colour, which only a mask has.
    static func gpu(_ swatch: PointColorSwatch) -> PointColorGPU? {
        guard case let .oklch(color) = swatch.color else { return nil }
        let widths = halfWidths(swatch)
        let fade = fade(swatch)
        let limit = pushLimit(fade: fade)
        func spread(_ parameter: ParameterID) -> Float {
            let amount = swatch[parameter] / 100
            return Float(amount >= 0 ? amount : amount * limit)
        }
        return PointColorGPU(
            color: SIMD4(Float(color.lightness), Float(color.chroma), Float(color.hue), 0),
            range: SIMD4(Float(widths.x), Float(widths.y), Float(widths.z), Float(fade)),
            // As the Color Mixer's sliders: ±30° of hue, chroma by up to twice, ±0.15 lightness.
            shift: SIMD4(
                Float(swatch[.pointColorHueShift] / 100 * 30), Float(swatch[.pointColorSaturationShift] / 100),
                Float(swatch[.pointColorLuminanceShift] / 100 * 0.15), 0,
            ),
            uniformity: SIMD4(
                spread(.pointColorHueUniformity), spread(.pointColorSaturationUniformity),
                spread(.pointColorLuminanceUniformity), 0,
            ),
        )
    }

    /// The swatches the kernel runs: those that change something, and the one Visualize Range shows
    /// even when it doesn't; with that one's position plus one (0 for none).
    static func buffers(
        _ swatches: [PointColorSwatch],
        visualized: UUID?,
    ) -> (swatches: [PointColorGPU], visualized: Int) {
        var out: [PointColorGPU] = []
        var shown = 0
        for swatch in swatches.prefix(PointColorSwatch.maximumSwatches)
            where !swatch.isNeutral || swatch.id == visualized {
            guard let gpu = gpu(swatch) else { continue }
            out.append(gpu)
            if swatch.id == visualized {
                shown = out.count
            }
        }
        return (out, shown)
    }
}
