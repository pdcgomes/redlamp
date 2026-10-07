import Foundation
import RedlampColor
import simd

/// The color math recipe tools need, matching the develop kernel's definitions exactly.
public enum ColorMath {
    /// Linear Rec.709/sRGB <-> linear Rec.2020 (ITU-R BT.2087).
    public static let rec709ToRec2020 = simd_float3x3(rows: [
        SIMD3(0.6274040, 0.3292820, 0.0433136),
        SIMD3(0.0690970, 0.9195400, 0.0113612),
        SIMD3(0.0163916, 0.0880132, 0.8955950),
    ])
    public static let rec2020ToRec709 = rec709ToRec2020.inverse

    public static let rec2020Luma = Luma.rec2020
    public static let rec709Luma = Luma.rec709

    @inline(__always)
    public static func srgbEncode(_ x: Float) -> Float {
        SRGB.encode(x)
    }

    @inline(__always)
    public static func srgbDecode(_ x: Float) -> Float {
        SRGB.decode(x)
    }

    public static func srgbEncode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SRGB.encode(c)
    }

    public static func srgbDecode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SRGB.decode(c)
    }

    /// Björn Ottosson's OKLab from linear Rec.2020, as in `Develop.metal`.
    public static func rec2020ToOKLab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        OKLab.fromLinearRec2020(c)
    }

    public static func okLabToRec2020(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        OKLab.toLinearRec2020(lab)
    }

    /// OKLab from sRGB-encoded sRGB, for measuring ordinary images.
    public static func encodedSRGBToOKLab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        rec2020ToOKLab(rec709ToRec2020 * srgbDecode(c))
    }

    public static func okLabToEncodedSRGB(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        srgbEncode(simd_clamp(rec2020ToRec709 * okLabToRec2020(lab), .zero, SIMD3(repeating: 1)))
    }

    /// Lightness, chroma and hue in degrees (0..<360).
    public static func lch(_ lab: SIMD3<Float>) -> (l: Float, c: Float, h: Float) {
        let c = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        var h = atan2(lab.z, lab.y) * 180 / .pi
        if h < 0 {
            h += 360
        }
        return (lab.x, c, h)
    }

    public static func lab(l: Float, c: Float, h: Float) -> SIMD3<Float> {
        let radians = h * .pi / 180
        return SIMD3(l, c * cos(radians), c * sin(radians))
    }

    public static func hueDistance(_ a: Float, _ b: Float) -> Float {
        let d = fmod(abs(a - b), 360)
        return d > 180 ? 360 - d : d
    }

    /// Signed shortest rotation from `a` to `b`, in degrees.
    public static func hueDelta(from a: Float, to b: Float) -> Float {
        var d = fmod(b - a, 360)
        if d > 180 {
            d -= 360
        }
        if d < -180 {
            d += 360
        }
        return d
    }

    public static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
