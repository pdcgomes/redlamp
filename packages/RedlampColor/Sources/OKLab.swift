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

    /// Unit (a, b) direction of an HSV hue (0...360, 0 = red), as shown on a color wheel.
    public static func direction(forWheelHue degrees: Double) -> SIMD2<Double> {
        let rgb = hsvToSRGB(hue: degrees, saturation: 1, value: 1)
        let linear = SIMD3(srgbDecode(rgb.x), srgbDecode(rgb.y), srgbDecode(rgb.z))
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

    public static func srgbDecode(_ x: Double) -> Double {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
}
