import RedlampEngineAPI
import simd

/// A camera's color calibration: the matrix from XYZ to camera RGB, and the derived
/// conversions between white balance settings and per-channel multipliers.
///
/// This is the single-illuminant (matrix-only) model. Dual-illuminant DCP profiles with
/// hue/saturation maps replace it in Phase 2.
public struct CameraColorModel: Sendable {
    public let xyzToCamera: simd_double3x3
    public let cameraToXYZ: simd_double3x3

    /// `rows` is row-major XYZ → camera (LibRaw's `cam_xyz`, Adobe's ColorMatrix).
    public init?(xyzToCameraRowMajor rows: [Double]) {
        guard rows.count == 9, rows.contains(where: { $0 != 0 }) else { return nil }
        let matrix = simd_double3x3(rowMajor: rows)
        guard abs(matrix.determinant) > 1e-12 else { return nil }
        xyzToCamera = matrix
        cameraToXYZ = matrix.inverse
    }

    /// Camera RGB of a neutral object lit by the given white.
    public func cameraNeutral(for value: WhiteBalanceValue) -> SIMD3<Double> {
        let xyz = ColorTemperature.xyz(for: ColorTemperature.chromaticity(for: value))
        return xyzToCamera * xyz
    }

    /// Per-channel white-balance multipliers, normalised so green is 1.
    public func multipliers(for value: WhiteBalanceValue) -> SIMD3<Double> {
        let neutral = cameraNeutral(for: value)
        let safe = simd_max(neutral, SIMD3(repeating: 1e-6))
        let multipliers = SIMD3<Double>(repeating: 1) / safe
        return multipliers / multipliers.y
    }

    /// The white balance whose neutral is the given camera RGB.
    public func whiteBalance(forCameraNeutral neutral: SIMD3<Double>) -> WhiteBalanceValue {
        let xyz = cameraToXYZ * neutral
        let sum = xyz.x + xyz.y + xyz.z
        guard sum > 1e-9 else { return WhiteBalanceValue(temperature: 5500, tint: 0) }
        let value = ColorTemperature.whiteBalance(for: SIMD2(xyz.x / sum, xyz.y / sum))
        return WhiteBalanceValue(
            temperature: min(max(value.temperature, 2000), 50000),
            tint: min(max(value.tint, -150), 150),
        )
    }

    /// The white balance implied by per-channel multipliers (e.g. the camera's as-shot).
    public func whiteBalance(forMultipliers multipliers: SIMD3<Double>) -> WhiteBalanceValue {
        let safe = simd_max(multipliers, SIMD3(repeating: 1e-9))
        return whiteBalance(forCameraNeutral: SIMD3(repeating: 1) / safe)
    }
}
