import Foundation
import RedlampEngineAPI
import simd

/// Deterministic quality checks for a recipe, from renders of `RecipeChart`.
///
/// Lint compares the recipe's render with a neutral one (a default edit) of the same
/// chart, so it measures what the recipe does rather than what the pipeline does. The
/// thresholds are guardrails: they catch broken looks, not judge taste.
public enum RecipeLint {
    public enum Check: String, CaseIterable, Sendable, Codable {
        case neutralAxis = "neutral-axis"
        case skinHue = "skin-hue"
        case monotonicLuminance = "monotonic-luminance"
        case banding
        case clipping

        public var title: String {
            switch self {
            case .neutralAxis: "Neutrals stay neutral"
            case .skinHue: "Skin keeps its hue"
            case .monotonicLuminance: "Brighter in, brighter out"
            case .banding: "No banding in smooth gradients"
            case .clipping: "No extra clipping"
            }
        }

        /// (warn, fail) thresholds for `value`.
        public var thresholds: (warn: Double, fail: Double) {
            switch self {
            case .neutralAxis: (0.025, 0.05)
            case .skinHue: (10, 20)
            case .monotonicLuminance: (0.004, 0.012)
            case .banding: (2.5, 4.5)
            case .clipping: (0.03, 0.1)
            }
        }

        public var unit: String {
            switch self {
            case .neutralAxis: "OKLab chroma added to greys"
            case .skinHue: "degrees of hue shift, weighted by chroma"
            case .monotonicLuminance: "largest lightness drop"
            case .banding: "abrupt contrast changes in one gradient"
            case .clipping: "fraction of colors newly clipped to black or white"
            }
        }
    }

    public enum Status: String, Sendable, Codable, Comparable {
        case pass, warn, fail, waived

        private var rank: Int {
            switch self {
            case .pass, .waived: 0
            case .warn: 1
            case .fail: 2
            }
        }

        public static func < (lhs: Status, rhs: Status) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    public struct Result: Sendable, Codable, Hashable {
        public var check: Check
        public var status: Status
        public var value: Double
        public var detail: String
    }

    /// The worst status among results.
    public static func overall(_ results: [Result]) -> Status {
        results.map(\.status).max() ?? .pass
    }

    /// The edit lint renders: the recipe on a fresh photo, without the spatial effects
    /// (vignette, grain) that would swamp the chart measurements.
    public static func lintEdit(for recipe: Recipe) -> EditRecipe {
        var edit = recipe.edit()
        edit
            .reset(ParameterID.allCases
                .filter { $0.rawValue.hasPrefix("effects.vignette.") || $0.rawValue.hasPrefix("effects.grain.") })
        return edit
    }

    public static func check(recipe: Recipe, baseline: PixelImage, render: PixelImage) -> [Result] {
        precondition(baseline.width == RecipeChart.width && render.width == RecipeChart.width)
        let values: [(Check, Double, String)] = [
            neutralAxis(baseline, render),
            skinHue(baseline, render),
            monotonic(render),
            banding(baseline, render),
            clipping(baseline, render),
        ]
        return values.map { check, value, detail in
            let status: Status = if recipe.lintWaivers.contains(check.rawValue) {
                .waived
            } else if value > check.thresholds.fail {
                .fail
            } else if value > check.thresholds.warn {
                .warn
            } else {
                .pass
            }
            return Result(check: check, status: status, value: value, detail: detail)
        }
    }

    private static func lab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        ColorMath.encodedSRGBToOKLab(simd_clamp(c, .zero, SIMD3(repeating: 1)))
    }

    private static func rampRow(_ image: PixelImage) -> [SIMD3<Float>] {
        let y = RecipeChart.ramp.lowerBound + RecipeChart.ramp.count / 2
        return (0 ..< image.width).map { lab(image[$0, y]) }
    }

    /// Chroma the recipe adds to the grey ramp, ignoring the darkest and brightest 5%.
    static func neutralAxis(_ baseline: PixelImage, _ render: PixelImage) -> (RecipeLint.Check, Double, String) {
        let before = rampRow(baseline), after = rampRow(render)
        let range = (before.count / 20) ..< (before.count * 19 / 20)
        var worst: Float = 0
        var worstAt = 0
        for i in range {
            let added = ColorMath.lch(after[i]).c - ColorMath.lch(before[i]).c
            if added > worst {
                worst = added
                worstAt = i
            }
        }
        let tone = Int((Float(worstAt) / Float(before.count) * 100).rounded())
        return (
            .neutralAxis,
            Double(max(worst, 0)),
            "greys pick up \(String(format: "%.3f", worst)) chroma at \(tone)% grey",
        )
    }

    /// The largest hue shift of any skin patch, weighted by its chroma: a pale patch can
    /// swing many degrees under a gentle cast without looking any different.
    static func skinHue(_ baseline: PixelImage, _ render: PixelImage) -> (RecipeLint.Check, Double, String) {
        let y = RecipeChart.skin.lowerBound + RecipeChart.skin.count / 2
        var worst: Float = 0
        var worstPatch = 0
        for patch in 0 ..< RecipeChart.skinTones.count {
            let x = patch * RecipeChart.skinPatchWidth + RecipeChart.skinPatchWidth / 2
            let before = ColorMath.lch(lab(baseline[x, y]))
            let after = ColorMath.lch(lab(render[x, y]))
            guard before.c > 0.02, after.c > 0.02 else { continue }
            let shift = abs(ColorMath.hueDelta(from: before.h, to: after.h)) * min(1, min(before.c, after.c) / 0.08)
            if shift > worst {
                worst = shift
                worstPatch = patch
            }
        }
        return (.skinHue, Double(worst), "skin patch \(worstPatch + 1) of 8 shifts \(String(format: "%.1f", worst))°")
    }

    /// The largest drop in lightness as the grey ramp brightens.
    static func monotonic(_ render: PixelImage) -> (RecipeLint.Check, Double, String) {
        let l = rampRow(render).map(\.x)
        var peak = l[0]
        var worst: Float = 0
        for value in l {
            peak = max(peak, value)
            worst = max(worst, peak - value)
        }
        return (
            .monotonicLuminance,
            Double(worst),
            worst > 0 ? "lightness falls by \(String(format: "%.4f", worst))" : "lightness only rises",
        )
    }

    /// Banding is plateaus separated by jumps. Along the ramp and each gradient, the recipe's
    /// local contrast relative to the neutral render is measured in 8-pixel windows; the
    /// value is the most abrupt changes of that gain in any one row. A smooth curve changes
    /// gain gradually; a gradient meeting the gamut edge makes one abrupt change; a
    /// posterized look makes one at every band edge.
    static func banding(_ baseline: PixelImage, _ render: PixelImage) -> (RecipeLint.Check, Double, String) {
        var rows = [RecipeChart.ramp.lowerBound + RecipeChart.ramp.count / 2]
        rows += stride(from: RecipeChart.gradients.lowerBound + 8, to: RecipeChart.gradients.upperBound, by: 32)
            .map(\.self)
        let window = 8
        var worst = 0
        for y in rows {
            let after = (0 ..< render.width).map { lab(render[$0, y]).x }
            let before = (0 ..< render.width).map { lab(baseline[$0, y]).x }
            let halves = RecipeChart.gradients.contains(y)
                ? [0 ..< render.width / 2, render.width / 2 ..< render.width]
                : [0 ..< render.width]
            for span in halves {
                var gains: [Float?] = []
                for i in stride(from: span.lowerBound, to: span.upperBound - window, by: window) {
                    let reference = abs(before[i + window] - before[i])
                    gains.append(reference < 0.004 ? nil : abs(after[i + window] - after[i]) / reference)
                }
                var abrupt = 0
                for (a, b) in zip(gains, gains.dropFirst()) {
                    guard let a, let b else { continue }
                    if abs(b - a) / max((a + b) / 2, 0.25) > 0.6 {
                        abrupt += 1
                    }
                }
                worst = max(worst, abrupt)
            }
        }
        return (
            .banding,
            Double(worst),
            worst == 0 ? "gradients stay smooth" : "\(worst) abrupt contrast changes in one gradient",
        )
    }

    /// Pixels of the sweep, skin and gradients that the recipe clips to pure black or white
    /// in every channel and the neutral render doesn't.
    static func clipping(_ baseline: PixelImage, _ render: PixelImage) -> (RecipeLint.Check, Double, String) {
        func clipped(_ c: SIMD3<Float>) -> Bool {
            c.min() >= 0.995 || c.max() <= 0.005
        }
        var added = 0, total = 0
        for y in RecipeChart.sweep.lowerBound ..< RecipeChart.gradients.upperBound {
            for x in 0 ..< render.width {
                if clipped(render[x, y]), !clipped(baseline[x, y]) {
                    added += 1
                }
                total += 1
            }
        }
        let extra = Double(added) / Double(max(total, 1))
        return (.clipping, extra, "\(String(format: "%.1f", extra * 100))% of colors newly clipped to black or white")
    }
}

/// What a look table does, for the Recipe Lab's inspector.
public struct LookTableStats: Sendable, Hashable {
    /// Mean distance from the identity, in encoded RGB.
    public var strength: Double
    /// The most chroma the table adds to a grey.
    public var neutralChroma: Double
    /// The steepest slope between neighbouring entries (1 is an identity's).
    public var maxSlope: Double
    /// Fraction of entries outside 0...1.
    public var outOfRange: Double

    public init(_ table: LookTable) {
        let n = table.size
        var distance = 0.0
        var outside = 0
        var steepest: Float = 0
        let step = 1 / Float(n - 1)
        for b in 0 ..< n {
            for g in 0 ..< n {
                for r in 0 ..< n {
                    let v = table.entry(r: r, g: g, b: b)
                    let identity = SIMD3(Float(r), Float(g), Float(b)) * step
                    distance += Double(simd_length(v - identity))
                    if v.min() < 0 || v.max() > 1 {
                        outside += 1
                    }
                    if r + 1 < n {
                        steepest = max(steepest, simd_length(table.entry(r: r + 1, g: g, b: b) - v) / step)
                    }
                    if g + 1 < n {
                        steepest = max(steepest, simd_length(table.entry(r: r, g: g + 1, b: b) - v) / step)
                    }
                    if b + 1 < n {
                        steepest = max(steepest, simd_length(table.entry(r: r, g: g, b: b + 1) - v) / step)
                    }
                }
            }
        }
        var neutral: Float = 0
        for i in 1 ..< 32 {
            let grey = SIMD3<Float>(repeating: Float(i) / 32)
            neutral = max(neutral, ColorMath.lch(ColorMath.rec2020ToOKLab(ColorMath.srgbDecode(table.sample(grey)))).c)
        }
        let count = Double(n * n * n)
        strength = distance / count
        neutralChroma = Double(neutral)
        maxSlope = Double(steepest)
        outOfRange = Double(outside) / count
    }
}
