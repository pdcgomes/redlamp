import simd

/// RGB color spaces as primaries + white point, and the matrices between them.
///
/// Matrices are derived from the chromaticities at load time rather than hard-coded, so
/// every conversion in the engine shares one definition.
public struct RGBPrimaries: Sendable, Hashable {
    public let red: SIMD2<Double>
    public let green: SIMD2<Double>
    public let blue: SIMD2<Double>
    public let white: SIMD2<Double>

    public static let d65 = SIMD2<Double>(0.3127, 0.3290)

    public static let sRGB = RGBPrimaries(
        red: [0.640, 0.330], green: [0.300, 0.600], blue: [0.150, 0.060], white: d65,
    )
    public static let displayP3 = RGBPrimaries(
        red: [0.680, 0.320], green: [0.265, 0.690], blue: [0.150, 0.060], white: d65,
    )
    public static let rec2020 = RGBPrimaries(
        red: [0.708, 0.292], green: [0.170, 0.797], blue: [0.131, 0.046], white: d65,
    )
    /// ROMM RGB, the space DNG camera profiles' tables work in; its white is D50, so its
    /// `toXYZ` gives D50-relative XYZ.
    public static let proPhoto = RGBPrimaries(
        red: [0.7347, 0.2653], green: [0.1596, 0.8404], blue: [0.0366, 0.0001], white: [0.3457, 0.3585],
    )

    /// Linear RGB → CIE XYZ (Y = 1 for white).
    public var toXYZ: simd_double3x3 {
        func xyz(_ xy: SIMD2<Double>) -> SIMD3<Double> {
            SIMD3(xy.x / xy.y, 1, (1 - xy.x - xy.y) / xy.y)
        }
        let primaries = simd_double3x3(columns: (xyz(red), xyz(green), xyz(blue)))
        let scale = primaries.inverse * xyz(white)
        return simd_double3x3(columns: (
            primaries.columns.0 * scale.x,
            primaries.columns.1 * scale.y,
            primaries.columns.2 * scale.z,
        ))
    }

    public var fromXYZ: simd_double3x3 {
        toXYZ.inverse
    }

    public func conversion(to other: RGBPrimaries) -> simd_double3x3 {
        other.fromXYZ * toXYZ
    }
}

public enum ColorMatrices {
    public static let sRGBToRec2020 = RGBPrimaries.sRGB.conversion(to: .rec2020)
    public static let rec2020ToSRGB = RGBPrimaries.rec2020.conversion(to: .sRGB)
    public static let rec2020ToDisplayP3 = RGBPrimaries.rec2020.conversion(to: .displayP3)
    public static let rec2020ToXYZ = RGBPrimaries.rec2020.toXYZ
}

public extension simd_double3x3 {
    /// Builds a matrix from row-major values.
    init(rowMajor values: [Double]) {
        precondition(values.count == 9)
        self.init(rows: [
            SIMD3(values[0], values[1], values[2]),
            SIMD3(values[3], values[4], values[5]),
            SIMD3(values[6], values[7], values[8]),
        ])
    }

    var floatMatrix: simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3<Float>(columns.0),
            SIMD3<Float>(columns.1),
            SIMD3<Float>(columns.2),
        ))
    }
}
