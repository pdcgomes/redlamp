import Foundation
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

    public static let rec2020Luma = SIMD3<Float>(0.2627, 0.6780, 0.0593)
    public static let rec709Luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    @inline(__always)
    public static func srgbEncode(_ x: Float) -> Float {
        x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    @inline(__always)
    public static func srgbDecode(_ x: Float) -> Float {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    public static func srgbEncode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(srgbEncode(c.x), srgbEncode(c.y), srgbEncode(c.z))
    }

    public static func srgbDecode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(srgbDecode(c.x), srgbDecode(c.y), srgbDecode(c.z))
    }

    /// Björn Ottosson's OKLab from linear Rec.2020, as in `Develop.metal`.
    public static func rec2020ToOKLab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        var l = 0.6167557872 * c.x + 0.3601983994 * c.y + 0.0230458134 * c.z
        var m = 0.2651330640 * c.x + 0.6358393641 * c.y + 0.0990275718 * c.z
        var s = 0.1001026342 * c.x + 0.2039065194 * c.y + 0.6959908464 * c.z
        l = cbrt(l)
        m = cbrt(m)
        s = cbrt(s)
        return SIMD3(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
        )
    }

    public static func okLabToRec2020(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        var l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        var m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        var s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        l = l * l * l
        m = m * m * m
        s = s * s * s
        return SIMD3(
            2.1399067357 * l - 1.2463895088 * m + 0.1064827730 * s,
            -0.8847358625 * l + 2.1632309821 * m - 0.2784951194 * s,
            -0.0485737580 * l - 0.4545031429 * m + 1.5030769009 * s,
        )
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
