import Foundation
import RedlampEngineAPI
import simd

/// A parametric description of a look, turned into a look table by `LookSynthesizer`.
///
/// Everything happens in OKLCh on display-referred values, with smooth functions only, so
/// tables never band. Bundled Base Looks are designs; the fitter also moves designs.
public struct LookDesign: Codable, Sendable, Hashable {
    /// S-curve strength on lightness, -1...1 (0 none).
    public var contrast: Double = 0
    public var pivot: Double = 0.48
    /// Lifts black towards this lightness (faded film), 0...0.25.
    public var fade: Double = 0
    /// Pulls white down to 1 - this, 0...0.25.
    public var whiteRoll: Double = 0
    /// Chroma multiplier.
    public var saturation: Double = 1
    /// Saturated colors get darker and denser, like dye-based film, 0...1.
    public var density: Double = 0
    /// Chroma removed from highlights and shadows, 0...1.
    public var highlightDesaturation: Double = 0
    public var shadowDesaturation: Double = 0
    /// OKLab a/b added in shadows, midtones and highlights.
    public var shadowTint: [Double] = [0, 0]
    public var midtoneTint: [Double] = [0, 0]
    public var highlightTint: [Double] = [0, 0]
    /// Per mixer band (red, orange, yellow, green, aqua, blue, purple, magenta): hue shift in
    /// degrees, chroma multiplier and lightness shift.
    public var hueShifts: [Double] = Array(repeating: 0, count: 8)
    public var chromaScales: [Double] = Array(repeating: 1, count: 8)
    public var lightnessShifts: [Double] = Array(repeating: 0, count: 8)
    /// Black and white: weights of linear red, green and blue (a color filter), plus toning.
    public var monochrome: Monochrome?

    public struct Monochrome: Codable, Sendable, Hashable {
        public var weights: [Double]
        public var shadowTone: [Double] = [0, 0]
        public var highlightTone: [Double] = [0, 0]

        public init(weights: [Double], shadowTone: [Double] = [0, 0], highlightTone: [Double] = [0, 0]) {
            self.weights = weights
            self.shadowTone = shadowTone
            self.highlightTone = highlightTone
        }
    }

    public init() {}

    public static let identity = LookDesign()
}

public enum LookSynthesizer {
    static let bandHues: [Float] = ColorBand.allCases.map { Float($0.hueDegrees) }

    public static func table(for design: LookDesign, size: Int = LookTableImport.storedSize) throws -> LookTable {
        try LookTable(size: size) { transform($0, design) }
    }

    /// Band weights between the two nearest band centres, as the kernel's mixer.
    static func bandValue(_ values: [Double], hue: Float) -> Float {
        for i in 0 ..< 8 {
            let j = (i + 1) % 8
            let start = bandHues[i]
            let end = j == 0 ? bandHues[0] + 360 : bandHues[j]
            let h = hue < start ? hue + 360 : hue
            if h >= start, h < end {
                let t = ColorMath.smoothstep(0, 1, (h - start) / (end - start))
                return Float(values[i]) * (1 - t) + Float(values[j]) * t
            }
        }
        return Float(values[0])
    }

    static func transform(_ encoded: SIMD3<Float>, _ d: LookDesign) -> SIMD3<Float> {
        let linear = ColorMath.srgbDecode(simd_max(encoded, .zero))
        if let mono = d.monochrome {
            let w = SIMD3<Float>(Float(mono.weights[0]), Float(mono.weights[1]), Float(mono.weights[2]))
            let y = max(simd_dot(linear, w) / max(w.x + w.y + w.z, 1e-4), 0)
            var lab = ColorMath.rec2020ToOKLab(SIMD3(repeating: y))
            lab.x = tone(lab.x, d)
            let s = 1 - ColorMath.smoothstep(0.2, 0.6, lab.x)
            let h = ColorMath.smoothstep(0.45, 0.85, lab.x)
            lab.y = Float(mono.shadowTone[0]) * s + Float(mono.highlightTone[0]) * h
            lab.z = Float(mono.shadowTone[1]) * s + Float(mono.highlightTone[1]) * h
            return ColorMath.srgbEncode(simd_max(ColorMath.okLabToRec2020(lab), .zero))
        }

        var lab = ColorMath.rec2020ToOKLab(linear)
        var (l, c, h) = ColorMath.lch(lab)
        let colorful = ColorMath.smoothstep(0, 0.04, c)

        // Per band: hue, chroma, lightness.
        h += bandValue(d.hueShifts, hue: h) * colorful
        c *= max(bandValue(d.chromaScales, hue: h), 0)
        l += bandValue(d.lightnessShifts, hue: h) * colorful * ColorMath.smoothstep(0, 0.1, c)

        // Density: saturated colors deepen.
        let saturated = ColorMath.smoothstep(0.04, 0.2, c)
        l *= 1 - Float(d.density) * 0.15 * saturated

        l = tone(l, d)
        c *= Float(d.saturation)
        c *= 1 - Float(d.highlightDesaturation) * ColorMath.smoothstep(0.6, 0.95, l)
        c *= 1 - Float(d.shadowDesaturation) * (1 - ColorMath.smoothstep(0.1, 0.4, l))
        c = max(c, 0)

        lab = ColorMath.lab(l: l, c: c, h: h)
        let shadows = 1 - ColorMath.smoothstep(0.15, 0.5, l)
        let highlights = ColorMath.smoothstep(0.5, 0.9, l)
        let mids = max(0, 1 - shadows - highlights)
        lab
            .y += Float(d.shadowTint[0]) * shadows + Float(d.midtoneTint[0]) * mids + Float(d.highlightTint[0]) *
            highlights
        lab
            .z += Float(d.shadowTint[1]) * shadows + Float(d.midtoneTint[1]) * mids + Float(d.highlightTint[1]) *
            highlights

        // Into Rec.2020 keeping hue: pull chroma in until the color fits.
        var rgb = ColorMath.okLabToRec2020(lab)
        if rgb.min() < 0 || rgb.max() > 1 {
            var lo: Float = 0, hi: Float = 1
            let base = SIMD3<Float>(lab.x, lab.y, lab.z)
            for _ in 0 ..< 12 {
                let mid = (lo + hi) / 2
                let candidate = ColorMath.okLabToRec2020(SIMD3(base.x, base.y * mid, base.z * mid))
                if candidate.min() < 0 || candidate.max() > 1 {
                    hi = mid
                } else {
                    lo = mid
                }
            }
            rgb = ColorMath.okLabToRec2020(SIMD3(base.x, base.y * lo, base.z * lo))
        }
        return ColorMath.srgbEncode(simd_clamp(rgb, .zero, SIMD3(repeating: 1)))
    }

    /// Lightness: S-curve around the pivot, then fade and white roll.
    static func tone(_ l: Float, _ d: LookDesign) -> Float {
        var x = min(max(l, 0), 1)
        if d.contrast != 0 {
            let k = Float(d.contrast) * 0.9
            let p = Float(d.pivot)
            // A smooth, monotonic S-curve: blend towards a logistic around the pivot.
            let logistic = { (v: Float) -> Float in 1 / (1 + exp(-(v - p) * 8)) }
            let lo = logistic(0), hi = logistic(1)
            let s = (logistic(x) - lo) / (hi - lo)
            x = k >= 0 ? x + (s - x) * k : x + (x - s) * -k * 0.6
        }
        let black = Float(d.fade), white = 1 - Float(d.whiteRoll)
        return black + (white - black) * min(max(x, 0), 1)
    }
}
