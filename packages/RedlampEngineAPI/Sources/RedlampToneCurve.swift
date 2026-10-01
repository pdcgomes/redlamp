import simd

/// Redlamp's scene-to-display tone curve, the same as `toneCurve` in Develop.metal: linear
/// Rec.2020 scene light in, linear display Rec.2020 out. A scene-referred look table built
/// from it renders exactly like no look.
public enum RedlampToneCurve {
    private static let shoulderStart: Float = 0.54358851
    private static let shoulderStartY: Float = 0.8
    private static let shoulderWidthEV: Float = 2.40548194
    private static let shoulderPower: Float = 3.25537943
    private static let filmicAtOne: Float = 0.80379747

    private static func filmic(_ x: Float) -> Float {
        (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14)
    }

    public static func channel(_ x: Float) -> Float {
        if x <= shoulderStart {
            return filmic(x) / filmicAtOne
        }
        let u = min(log2(x / shoulderStart) / shoulderWidthEV, 1)
        return 1 - (1 - shoulderStartY) * pow(1 - u, shoulderPower)
    }

    /// Per channel, keeping each channel's position between the smallest and largest.
    public static func apply(_ x: SIMD3<Float>) -> SIMD3<Float> {
        let y = SIMD3(channel(x.x), channel(x.y), channel(x.z))
        let lo = x.min(), hi = x.max()
        guard hi - lo >= 1e-7 else { return y }
        let yLo = y.min(), yHi = y.max()
        return yLo + (yHi - yLo) * (x - lo) / (hi - lo)
    }
}
