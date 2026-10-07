import Foundation

/// Björn Ottosson's OKLab, matching the implementation in the Metal kernels.
public enum OKLab {
    public static func fromLinearSRGB(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = cbrt(0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z)
        let m = cbrt(0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z)
        let s = cbrt(0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z)
        return SIMD3(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
        )
    }

    /// OKLab of linear sRGB in Float, with the cone responses clamped at zero, so a colour
    /// outside the gamut has no negative cube root.
    public static func fromLinearSRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let l = cbrt(max(0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z, 0))
        let m = cbrt(max(0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z, 0))
        let s = cbrt(max(0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z, 0))
        return SIMD3(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
        )
    }

    /// OKLab from linear Rec.2020, as `Develop.metal`'s `rec2020ToOKLab`.
    public static func fromLinearRec2020(_ c: SIMD3<Float>) -> SIMD3<Float> {
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

    /// Linear Rec.2020 from OKLab, as `Develop.metal`'s `okLabToRec2020`.
    public static func toLinearRec2020(_ lab: SIMD3<Float>) -> SIMD3<Float> {
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

    /// Unit (a, b) direction of an HSV hue (0...360, 0 = red), as shown on a color wheel.
    public static func direction(forWheelHue degrees: Double) -> SIMD2<Double> {
        let rgb = hsvToSRGB(hue: degrees, saturation: 1, value: 1)
        let linear = SIMD3(SRGB.decode(rgb.x), SRGB.decode(rgb.y), SRGB.decode(rgb.z))
        let lab = fromLinearSRGB(linear)
        let direction = SIMD2(lab.y, lab.z)
        let length = (direction.x * direction.x + direction.y * direction.y).squareRoot()
        return length > 0 ? direction / length : .zero
    }

    public static func hsvToSRGB(hue: Double, saturation: Double, value: Double) -> SIMD3<Double> {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = value * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = value - c
        let rgb: SIMD3<Double> = switch Int(h) {
        case 0: [c, x, 0]
        case 1: [x, c, 0]
        case 2: [0, c, x]
        case 3: [0, x, c]
        case 4: [x, 0, c]
        default: [c, 0, x]
        }
        return rgb + m
    }
}
