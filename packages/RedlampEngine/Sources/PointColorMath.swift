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

    /// The swatch as the kernel reads it: the edit's, or one of the mask at `layer` (in the kernel's
    /// list of masks), its changes scaled by the mask's Amount. Nil for a mask's own colour on the edit.
    static func gpu(_ swatch: PointColorSwatch, layer: Int? = nil, amount: Double = 1) -> PointColorGPU? {
        let color: OKLCh
        switch swatch.color {
        case let .oklch(value):
            color = value
        case .mask:
            guard layer != nil else { return nil }
            color = OKLCh(lightness: 0, chroma: 0, hue: 0)
        }
        let widths = halfWidths(swatch)
        let fade = fade(swatch)
        let limit = pushLimit(fade: fade)
        let scale = Float(amount)
        func spread(_ parameter: ParameterID) -> Float {
            let amount = swatch[parameter] / 100
            return Float(amount >= 0 ? amount : amount * limit) * scale
        }
        return PointColorGPU(
            color: SIMD4(Float(color.lightness), Float(color.chroma), Float(color.hue), Float((layer ?? -1) + 1)),
            range: SIMD4(Float(widths.x), Float(widths.y), Float(widths.z), Float(fade)),
            // As the Color Mixer's sliders: ±30° of hue, chroma by up to twice, ±0.15 lightness.
            shift: SIMD4(
                Float(swatch[.pointColorHueShift] / 100 * 30) * scale,
                Float(swatch[.pointColorSaturationShift] / 100) * scale,
                Float(swatch[.pointColorLuminanceShift] / 100 * 0.15) * scale, 0,
            ),
            uniformity: SIMD4(
                spread(.pointColorHueUniformity), spread(.pointColorSaturationUniformity),
                spread(.pointColorLuminanceUniformity), swatch.color == .mask ? 1 : 0,
            ),
        )
    }

    /// What the develop kernel reads of an edit's swatches.
    struct Buffers {
        /// The edit's and then each visible mask's, in the kernel's order of masks.
        var swatches: [PointColorGPU] = []
        /// The position of the swatch Visualize Range shows, plus one (0 for none).
        var visualized = 0
        /// The masks, by their place in that order, whose own colour a swatch takes.
        var measured: [Int] = []
    }

    /// The swatches the kernel runs: those that change something, and the one Visualize Range shows
    /// even when it doesn't.
    static func buffers(_ recipe: EditRecipe, visualized: UUID?) -> Buffers {
        var buffers = Buffers()
        func add(_ swatches: [PointColorSwatch], layer: Int?, amount: Double) {
            for swatch in swatches.prefix(PointColorSwatch.maximumSwatches)
                where !swatch.isNeutral || swatch.id == visualized {
                guard let gpu = gpu(swatch, layer: layer, amount: amount) else { continue }
                buffers.swatches.append(gpu)
                if swatch.id == visualized {
                    buffers.visualized = buffers.swatches.count
                }
                if let layer, swatch.color == .mask, !buffers.measured.contains(layer) {
                    buffers.measured.append(layer)
                }
            }
        }
        add(recipe.pointColor, layer: nil, amount: 1)
        let layers = recipe.masks.filter(\.isVisible).prefix(MaskLayer.maximumLayers)
        for (layer, mask) in layers.enumerated() {
            add(mask.pointColor, layer: layer, amount: mask.amount / 100)
        }
        return buffers
    }
}
