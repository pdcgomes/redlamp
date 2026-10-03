import Foundation
import simd

/// The camera log encodings LUTs for log footage are built for: a curve and a gamut each.
///
/// Curves map scene-linear reflectance (0.18 is middle grey) to the camera's signal in 0...1,
/// in the form its maker publishes. Gamut matrices are derived from the maker's primaries by
/// SMPTE RP 177, as `RGBPrimaries` does in RedlampColor; every white is D65, as Rec.2020's.
public enum CameraLogSpace: String, Sendable, CaseIterable {
    /// Sony S-Log3 with S-Gamut3.Cine: Sony, "Technical Summary for S-Gamut3.Cine/S-Log3 and
    /// S-Gamut3/S-Log3".
    case sLog3SGamut3Cine = "slog3-sgamut3cine"
    /// Sony S-Log3 with S-Gamut3, from the same summary.
    case sLog3SGamut3 = "slog3-sgamut3"
    /// ARRI LogC3 at EI 800 with ARRI Wide Gamut 3 (ALEXA Wide Gamut RGB): ARRI, "ALEXA Log C
    /// Curve: Usage in VFX" (Harald Brendel, 2017), the parameters for exposure values.
    case logC3 = "logc3-awg3"
    /// Panasonic V-Log with V-Gamut: Panasonic, "V-Log/V-Gamut Reference Manual" (2014).
    case vLog = "vlog-vgamut"
    /// Apple Log, with Rec.2020 primaries: Apple, "Apple Log Profile White Paper" (2023).
    case appleLog = "applelog"

    public var name: String {
        switch self {
        case .sLog3SGamut3Cine: "Sony S-Log3 / S-Gamut3.Cine"
        case .sLog3SGamut3: "Sony S-Log3 / S-Gamut3"
        case .logC3: "ARRI LogC3 (EI 800) / AWG3"
        case .vLog: "Panasonic V-Log / V-Gamut"
        case .appleLog: "Apple Log"
        }
    }

    /// Scene-linear light to the camera's log signal.
    public func encode(_ x: Float) -> Float {
        switch self {
        case .sLog3SGamut3Cine, .sLog3SGamut3:
            x >= SLog3.cut
                ? (420 + log10((x + 0.01) / (0.18 + 0.01)) * 261.5) / 1023
                : (x * (SLog3.codeAtCut - 95) / SLog3.cut + 95) / 1023
        case .logC3:
            x > LogC3.cut ? LogC3.c * log10(LogC3.a * x + LogC3.b) + LogC3.d : LogC3.e * x + LogC3.f
        case .vLog:
            x < VLog.cut ? 5.6 * x + 0.125 : VLog.c * log10(x + VLog.b) + VLog.d
        case .appleLog:
            if x >= AppleLog.rt {
                AppleLog.gamma * log2(x + AppleLog.beta) + AppleLog.delta
            } else if x >= AppleLog.r0 {
                AppleLog.c * (x - AppleLog.r0) * (x - AppleLog.r0)
            } else {
                0
            }
        }
    }

    /// The camera's log signal to scene-linear light.
    public func decode(_ y: Float) -> Float {
        switch self {
        case .sLog3SGamut3Cine, .sLog3SGamut3:
            y >= SLog3.codeAtCut / 1023
                ? pow(10, (y * 1023 - 420) / 261.5) * (0.18 + 0.01) - 0.01
                : (y * 1023 - 95) * SLog3.cut / (SLog3.codeAtCut - 95)
        case .logC3:
            y > LogC3.e * LogC3.cut + LogC3.f
                ? (pow(10, (y - LogC3.d) / LogC3.c) - LogC3.b) / LogC3.a
                : (y - LogC3.f) / LogC3.e
        case .vLog:
            y < 0.181 ? (y - 0.125) / 5.6 : pow(10, (y - VLog.d) / VLog.c) - VLog.b
        case .appleLog:
            y >= AppleLog.c * (AppleLog.rt - AppleLog.r0) * (AppleLog.rt - AppleLog.r0)
                ? exp2((y - AppleLog.delta) / AppleLog.gamma) - AppleLog.beta
                : (max(y, 0) / AppleLog.c).squareRoot() + AppleLog.r0
        }
    }

    public func encode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(encode(c.x), encode(c.y), encode(c.z))
    }

    public func decode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(decode(c.x), decode(c.y), decode(c.z))
    }

    /// Linear camera RGB to linear Rec.2020.
    public var toRec2020: simd_float3x3 {
        Self.toRec2020Matrices[self] ?? matrix_identity_float3x3
    }

    /// Linear Rec.2020 to linear camera RGB.
    public var fromRec2020: simd_float3x3 {
        Self.fromRec2020Matrices[self] ?? matrix_identity_float3x3
    }

    /// The primaries' CIE xy chromaticities, red, green and blue, as each maker publishes them.
    private var primaries: [SIMD2<Double>] {
        switch self {
        case .sLog3SGamut3Cine: [[0.766, 0.275], [0.225, 0.800], [0.089, -0.087]]
        case .sLog3SGamut3: [[0.730, 0.280], [0.140, 0.855], [0.100, -0.050]]
        case .logC3: [[0.6840, 0.3130], [0.2210, 0.8480], [0.0861, -0.1020]]
        case .vLog: [[0.730, 0.280], [0.165, 0.840], [0.100, -0.030]]
        case .appleLog: Self.rec2020Primaries
        }
    }

    private static let rec2020Primaries: [SIMD2<Double>] = [[0.708, 0.292], [0.170, 0.797], [0.131, 0.046]]
    private static let d65 = SIMD2<Double>(0.3127, 0.3290)

    private static let toRec2020Matrices = Dictionary(uniqueKeysWithValues: allCases.map { space in
        (space, float(toXYZ(rec2020Primaries).inverse * toXYZ(space.primaries)))
    })
    private static let fromRec2020Matrices = Dictionary(uniqueKeysWithValues: allCases.map { space in
        (space, float(toXYZ(space.primaries).inverse * toXYZ(rec2020Primaries)))
    })

    /// Linear RGB to CIE XYZ (Y = 1 for white) for primaries with a D65 white.
    private static func toXYZ(_ primaries: [SIMD2<Double>]) -> simd_double3x3 {
        func xyz(_ xy: SIMD2<Double>) -> SIMD3<Double> {
            SIMD3(xy.x / xy.y, 1, (1 - xy.x - xy.y) / xy.y)
        }
        let unscaled = simd_double3x3(columns: (xyz(primaries[0]), xyz(primaries[1]), xyz(primaries[2])))
        let scale = unscaled.inverse * xyz(d65)
        return simd_double3x3(columns: (
            unscaled.columns.0 * scale.x,
            unscaled.columns.1 * scale.y,
            unscaled.columns.2 * scale.z,
        ))
    }

    private static func float(_ m: simd_double3x3) -> simd_float3x3 {
        simd_float3x3(columns: (SIMD3<Float>(m.columns.0), SIMD3<Float>(m.columns.1), SIMD3<Float>(m.columns.2)))
    }

    private enum SLog3 {
        static let cut: Float = 0.01125
        static let codeAtCut: Float = 171.2102946929
    }

    private enum LogC3 {
        static let cut: Float = 0.010591
        static let a: Float = 5.555556
        static let b: Float = 0.052272
        static let c: Float = 0.247190
        static let d: Float = 0.385537
        static let e: Float = 5.367655
        static let f: Float = 0.092809
    }

    private enum VLog {
        static let cut: Float = 0.01
        static let b: Float = 0.00873
        static let c: Float = 0.241514
        static let d: Float = 0.598206
    }

    private enum AppleLog {
        static let r0: Float = -0.05641088
        static let rt: Float = 0.01
        static let c: Float = 47.28711236
        static let beta: Float = 0.00964052
        static let gamma: Float = 0.08550479
        static let delta: Float = 0.69336945
    }
}

/// The display a camera LUT's output is encoded for. Both have Rec.709 primaries.
public enum LookTableOutput: String, Sendable, CaseIterable {
    /// Rec.709 for a BT.1886 display with black at zero: a pure 2.4 gamma (ITU-R BT.1886).
    /// Camera makers' LUTs to Rec.709 target it.
    case rec709
    case sRGB

    public var name: String {
        switch self {
        case .rec709: "Rec.709 (gamma 2.4)"
        case .sRGB: "sRGB"
        }
    }

    /// The LUT's output to linear display light.
    public func decode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        switch self {
        case .rec709: SIMD3(pow(max(c.x, 0), 2.4), pow(max(c.y, 0), 2.4), pow(max(c.z, 0), 2.4))
        case .sRGB: ColorMath.srgbDecode(c)
        }
    }
}
