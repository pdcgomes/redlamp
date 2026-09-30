import Foundation
import RedlampColor
import RedlampServices
import simd

/// Dual-illuminant DNG colour: the calibrations interpolated by the white balance's colour
/// temperature, as the DNG specification describes (linear in inverse temperature, clamped to
/// the two calibration illuminants).
extension DNGColorCalibration {
    /// Bradford adaptation, XYZ D50 to XYZ D65.
    static let bradfordD50ToD65 = simd_double3x3(rows: [
        SIMD3(0.9555766, -0.0230393, 0.0631636),
        SIMD3(-0.0282895, 1.0099416, 0.0210077),
        SIMD3(0.0122982, -0.0204830, 1.3299098),
    ])

    /// White-balanced camera RGB to linear Rec. 2020, for a white balance at `temperature`.
    ///
    /// With forward matrices, balanced camera RGB goes straight to XYZ D50 (the specification's
    /// preferred path), then to D65 and Rec. 2020. Without, the interpolated XYZ-to-camera matrix
    /// is inverted with each row normalised so neutral stays neutral, as for other raw files.
    func cameraToWorking(temperature: Double) -> simd_float3x3 {
        let weight = weight(temperature)
        if let forward = interpolate(calibrations.compactMap(\.forwardMatrix), weight: weight) {
            let xyzToRec2020 = ColorMatrices.rec2020ToXYZ.inverse
            return (xyzToRec2020 * Self.bradfordD50ToD65 * forward).floatMatrix
        }
        let cameraFromRGB = xyzToCamera(weight: weight) * RGBPrimaries.sRGB.toXYZ
        var rows = (0 ..< 3).map { cameraFromRGB.transpose[$0] }
        for row in 0 ..< 3 {
            let sum = rows[row].sum()
            if abs(sum) > 1e-9 {
                rows[row] /= sum
            }
        }
        let cameraToSRGB = simd_double3x3(rows: rows).inverse
        return (ColorMatrices.sRGBToRec2020 * cameraToSRGB).floatMatrix
    }

    /// The colour temperature of a camera neutral (as-shot white balance), found by iterating:
    /// the interpolation needs the temperature, and the temperature needs the interpolation.
    func temperature(ofNeutral neutral: SIMD3<Double>) -> Double {
        var temperature = 5000.0
        for _ in 0 ..< 8 {
            let xyz = xyzToCamera(weight: weight(temperature)).inverse * neutral
            let sum = xyz.sum()
            guard sum > 1e-9 else { break }
            let next = Self.temperature(x: xyz.x / sum, y: xyz.y / sum)
            if abs(next - temperature) < 1 {
                return next
            }
            temperature = next
        }
        return temperature
    }

    /// How much of the coolest calibration to use.
    func weight(_ temperature: Double) -> Double {
        guard calibrations.count == 2 else { return 1 }
        let (cool, warm) = (calibrations[0].temperature, calibrations[1].temperature)
        guard cool < warm else { return 1 }
        let t = min(max(temperature, cool), warm)
        return (1 / t - 1 / warm) / (1 / cool - 1 / warm)
    }

    /// AnalogBalance x CameraCalibration x ColorMatrix, interpolated.
    func xyzToCamera(weight: Double) -> simd_double3x3 {
        let calibration = interpolate(calibrations.map(\.cameraCalibration), weight: weight) ?? simd_double3x3(1)
        let color = interpolate(calibrations.map(\.colorMatrix), weight: weight) ?? simd_double3x3(1)
        let balance = simd_double3x3(diagonal: SIMD3(analogBalance[0], analogBalance[1], analogBalance[2]))
        return balance * calibration * color
    }

    /// One matrix per calibration, blended; nil unless every calibration has one.
    private func interpolate(_ matrices: [[Double]], weight: Double) -> simd_double3x3? {
        guard matrices.count == calibrations.count, let first = matrices.first else { return nil }
        let cool = simd_double3x3(rowMajor: first)
        guard matrices.count == 2 else { return cool }
        return weight * cool + (1 - weight) * simd_double3x3(rowMajor: matrices[1])
    }

    /// McCamy's approximation, accurate to a few kelvin over daylight and tungsten.
    static func temperature(x: Double, y: Double) -> Double {
        let n = (x - 0.3320) / (0.1858 - y)
        return min(max(449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33, 2000), 25000)
    }
}
