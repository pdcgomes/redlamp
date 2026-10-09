import Foundation
import simd

/// CIELAB and the CIEDE2000 colour difference: relative to D65 for colour regression tests, and
/// to D50 for the histogram's readout.
public enum CIELab {
    private static let white = RGBPrimaries.sRGB.toXYZ * SIMD3<Double>(1, 1, 1)

    /// The ICC profile connection space's white (D50), as ICC.1 gives it.
    public static let d50White = SIMD3<Double>(0.9642, 1, 0.8249)

    /// Bradford's cone response matrix (Lam 1985), as ICC.1 Annex E uses it.
    private static let bradford = simd_double3x3(rows: [
        SIMD3(0.8951, 0.2664, -0.1614),
        SIMD3(-0.7502, 1.7135, 0.0367),
        SIMD3(0.0389, -0.0685, 1.0296),
    ])

    /// Linear Display P3 to XYZ adapted to D50 by Bradford.
    private static let displayP3ToD50: simd_double3x3 = {
        let source = bradford * white
        let target = bradford * d50White
        let adapt = bradford.inverse * simd_double3x3(diagonal: target / source) * bradford
        return adapt * RGBPrimaries.displayP3.toXYZ
    }()

    /// Linear sRGB to L*a*b*, relative to the sRGB (D65) white.
    public static func fromLinearSRGB(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        lab(RGBPrimaries.sRGB.toXYZ * rgb / white)
    }

    /// Linear Display P3 to L*a*b* relative to D50, adapted by Bradford, as ICC profiles and
    /// Photoshop report it.
    public static func d50(fromLinearDisplayP3 rgb: SIMD3<Double>) -> SIMD3<Double> {
        lab(displayP3ToD50 * rgb / d50White)
    }

    /// L*a*b* of XYZ already divided by its white's.
    private static func lab(_ xyz: SIMD3<Double>) -> SIMD3<Double> {
        func f(_ t: Double) -> Double {
            t > 216.0 / 24389 ? cbrt(t) : t * 841.0 / 108 + 4.0 / 29
        }
        let (fx, fy, fz) = (f(xyz.x), f(xyz.y), f(xyz.z))
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIEDE2000 (Sharma, Wu and Dalal 2005), with unit weights.
    public static func deltaE2000(_ first: SIMD3<Double>, _ second: SIMD3<Double>) -> Double {
        func degrees(_ radians: Double) -> Double {
            radians * 180 / .pi
        }
        func radians(_ degrees: Double) -> Double {
            degrees * .pi / 180
        }
        /// How close a chroma is to neutral's weighting, c^7 / (c^7 + 25^7).
        func chromaWeight(_ c: Double) -> Double {
            let c7 = c * c * c * c * c * c * c
            return (c7 / (c7 + 6_103_515_625)).squareRoot()
        }
        let chroma: Double = (hypot(first.y, first.z) + hypot(second.y, second.z)) / 2
        let g = 0.5 * (1 - chromaWeight(chroma))
        let a1 = (1 + g) * first.y, a2 = (1 + g) * second.y
        let c1 = hypot(a1, first.z), c2 = hypot(a2, second.z)
        func hue(_ a: Double, _ b: Double) -> Double {
            guard a != 0 || b != 0 else { return 0 }
            let h = degrees(atan2(b, a))
            return h < 0 ? h + 360 : h
        }
        let h1 = hue(a1, first.z), h2 = hue(a2, second.z)

        let deltaL = second.x - first.x
        let deltaC = c2 - c1
        var deltaHue = 0.0
        if c1 * c2 != 0 {
            deltaHue = h2 - h1
            if deltaHue > 180 {
                deltaHue -= 360
            } else if deltaHue < -180 {
                deltaHue += 360
            }
        }
        let deltaH = 2 * (c1 * c2).squareRoot() * sin(radians(deltaHue / 2))

        let meanL = (first.x + second.x) / 2
        let meanC = (c1 + c2) / 2
        var meanHue = h1 + h2
        if c1 * c2 != 0 {
            if abs(h1 - h2) <= 180 {
                meanHue = (h1 + h2) / 2
            } else {
                meanHue = h1 + h2 < 360 ? (h1 + h2 + 360) / 2 : (h1 + h2 - 360) / 2
            }
        }
        let t1: Double = 1 - 0.17 * cos(radians(meanHue - 30)) + 0.24 * cos(radians(2 * meanHue))
        let t: Double = t1 + 0.32 * cos(radians(3 * meanHue + 6)) - 0.20 * cos(radians(4 * meanHue - 63))
        let hueOffset: Double = (meanHue - 275) / 25
        let rotation: Double = 30 * exp(-hueOffset * hueOffset)
        let rc: Double = 2 * chromaWeight(meanC)
        let lightnessOffset = (meanL - 50) * (meanL - 50)
        let sl = 1 + 0.015 * lightnessOffset / (20 + lightnessOffset).squareRoot()
        let sc = 1 + 0.045 * meanC
        let sh = 1 + 0.015 * meanC * t
        let rt = -sin(radians(2 * rotation)) * rc
        let (l, c, h) = (deltaL / sl, deltaC / sc, deltaH / sh)
        return (l * l + c * c + h * h + rt * c * h).squareRoot()
    }
}
