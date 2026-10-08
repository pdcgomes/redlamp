import Foundation
import RedlampEngineAPI

/// Conversion between chromaticity and correlated color temperature + tint, using
/// Robertson's method over the CIE 1960 UCS isotemperature lines.
///
/// Tint is the signed distance from the Planckian locus, scaled so that the familiar
/// Lightroom range (-150...+150) covers the useful span. As in Lightroom, a positive tint
/// describes a greener illuminant, which renders the image more magenta.
public enum ColorTemperature {
    /// Scale from UCS distance to tint units.
    static let tintScale = -3000.0

    /// Robertson's table: (reciprocal megakelvin, u, v, isotemperature line slope).
    private static let isotemperatureLines: [(r: Double, u: Double, v: Double, t: Double)] = [
        (0, 0.18006, 0.26352, -0.24341),
        (10, 0.18066, 0.26589, -0.25479),
        (20, 0.18133, 0.26846, -0.26876),
        (30, 0.18208, 0.27119, -0.28539),
        (40, 0.18293, 0.27407, -0.30470),
        (50, 0.18388, 0.27709, -0.32675),
        (60, 0.18494, 0.28021, -0.35156),
        (70, 0.18611, 0.28342, -0.37915),
        (80, 0.18740, 0.28668, -0.40955),
        (90, 0.18880, 0.28997, -0.44278),
        (100, 0.19032, 0.29326, -0.47888),
        (125, 0.19462, 0.30141, -0.58204),
        (150, 0.19962, 0.30921, -0.70471),
        (175, 0.20525, 0.31647, -0.84901),
        (200, 0.21142, 0.32312, -1.0182),
        (225, 0.21807, 0.32909, -1.2168),
        (250, 0.22511, 0.33439, -1.4512),
        (275, 0.23247, 0.33904, -1.7298),
        (300, 0.24010, 0.34308, -2.0637),
        (325, 0.24702, 0.34655, -2.4681),
        (350, 0.25591, 0.34951, -2.9641),
        (375, 0.26400, 0.35200, -3.5814),
        (400, 0.27218, 0.35407, -4.3633),
        (425, 0.28039, 0.35577, -5.3762),
        (450, 0.28863, 0.35714, -6.7262),
        (475, 0.29685, 0.35823, -8.5955),
        (500, 0.30505, 0.35907, -11.324),
        (525, 0.31320, 0.35968, -15.628),
        (550, 0.32129, 0.36011, -23.325),
        (575, 0.32931, 0.36038, -40.770),
        (600, 0.33724, 0.36051, -116.45),
    ]

    /// Unit vector along an isotemperature line (perpendicular to the locus).
    private static func direction(slope: Double) -> SIMD2<Double> {
        let length = (1 + slope * slope).squareRoot()
        return SIMD2(1 / length, slope / length)
    }

    /// CIE xy chromaticity for a temperature and tint.
    public static func chromaticity(for value: WhiteBalanceValue) -> SIMD2<Double> {
        let lines = isotemperatureLines
        let reciprocal = 1e6 / min(max(value.temperature, 1000), 100_000)
        let offset = value.tint / tintScale

        var index = 0
        while index < lines.count - 2, reciprocal >= lines[index + 1].r {
            index += 1
        }
        let lower = lines[index]
        let upper = lines[index + 1]
        let f = min(max((upper.r - reciprocal) / (upper.r - lower.r), 0), 1)

        var u = lower.u * f + upper.u * (1 - f)
        var v = lower.v * f + upper.v * (1 - f)
        let d1 = direction(slope: lower.t)
        let d2 = direction(slope: upper.t)
        var d = d1 * f + d2 * (1 - f)
        d /= (d.x * d.x + d.y * d.y).squareRoot()
        u += d.x * offset
        v += d.y * offset

        let denominator = u - 4 * v + 2
        return SIMD2(1.5 * u / denominator, v / denominator)
    }

    /// Temperature and tint for a CIE xy chromaticity.
    public static func whiteBalance(for xy: SIMD2<Double>) -> WhiteBalanceValue {
        let lines = isotemperatureLines
        let denominator = 1.5 - xy.x + 6 * xy.y
        let u = 2 * xy.x / denominator
        let v = 3 * xy.y / denominator

        var previousDistance = 0.0
        var previousDirection = SIMD2<Double>(0, 0)
        for index in 1 ..< lines.count {
            let line = lines[index]
            let d = direction(slope: line.t)
            let du = u - line.u
            let dv = v - line.v
            var distance = -du * d.y + dv * d.x

            if distance <= 0 || index == lines.count - 1 {
                distance = -min(distance, 0)
                let f = index == 1 ? 0 : distance / (previousDistance + distance)
                let previous = lines[index - 1]
                let reciprocal = previous.r * f + line.r * (1 - f)
                let temperature = reciprocal > 0 ? 1e6 / reciprocal : 100_000

                let uu = u - (previous.u * f + line.u * (1 - f))
                let vv = v - (previous.v * f + line.v * (1 - f))
                var blended = d * (1 - f) + previousDirection * f
                blended /= (blended.x * blended.x + blended.y * blended.y).squareRoot()
                let tint = (uu * blended.x + vv * blended.y) * tintScale
                return WhiteBalanceValue(temperature: temperature, tint: tint)
            }
            previousDistance = distance
            previousDirection = d
        }
        return WhiteBalanceValue(temperature: 5000, tint: 0)
    }

    /// XYZ (Y = 1) for a chromaticity. Past x + y = 1, where low temperatures with a strong
    /// positive tint reach, Z would be negative, a colour no light has: the chromaticity is scaled
    /// back to that line, keeping x : y.
    public static func xyz(for xy: SIMD2<Double>) -> SIMD3<Double> {
        let xy = xy / max(xy.x + xy.y, 1)
        return SIMD3(xy.x / xy.y, 1, max(1 - xy.x - xy.y, 0) / xy.y)
    }
}
