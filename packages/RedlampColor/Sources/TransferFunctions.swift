import Foundation

/// The sRGB transfer functions (IEC 61966-2-1), as `Develop.metal`'s `srgbEncode` and
/// `srgbDecode` write them, so a value computed here matches the kernels'.
public enum SRGB {
    @inlinable
    public static func encode(_ x: Float) -> Float {
        x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    @inlinable
    public static func decode(_ x: Float) -> Float {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    @inlinable
    public static func decode(_ x: Double) -> Double {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    @inlinable
    public static func encode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(encode(c.x), encode(c.y), encode(c.z))
    }

    @inlinable
    public static func decode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(decode(c.x), decode(c.y), decode(c.z))
    }
}

/// Luminance weights of linear RGB.
public enum Luma {
    /// ITU-R BT.2020, the working space's (`Develop.metal`'s `kRec2020Luma`).
    public static let rec2020 = SIMD3<Float>(0.2627, 0.6780, 0.0593)
    /// The same weights in Double, for code that works in Double: widening the Float ones
    /// would change their values.
    public static let rec2020Double = SIMD3<Double>(0.2627, 0.6780, 0.0593)
    /// ITU-R BT.709, sRGB's.
    public static let rec709 = SIMD3<Float>(0.2126, 0.7152, 0.0722)
}
