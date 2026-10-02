import RedlampEngineAPI
import simd

/// Lightroom's Calibration panel. Each primary's Hue turns it about the neutral axis (±30° at
/// ±100, positive towards the next hue: red towards yellow, green towards cyan, blue towards
/// magenta) and its Saturation scales its distance from neutral (×0.4 to ×1.6); the three new
/// primaries, rescaled so white stays white, make a matrix that follows the camera's.
enum Calibration {
    static let maximumHueTurn = 30.0
    static let saturationReach = 0.6

    /// The working-space matrix the recipe's primaries give, or nil when they're all at zero.
    static func matrix(_ recipe: EditRecipe) -> simd_double3x3? {
        let sliders: [(hue: ParameterID, saturation: ParameterID)] = [
            (.calibrationRedHue, .calibrationRedSaturation),
            (.calibrationGreenHue, .calibrationGreenSaturation),
            (.calibrationBlueHue, .calibrationBlueSaturation),
        ]
        guard sliders.contains(where: { recipe[$0.hue] != 0 || recipe[$0.saturation] != 0 }) else { return nil }
        let neutral = SIMD3<Double>(repeating: 1 / 3.0.squareRoot())
        let primaries = sliders.enumerated().map { index, slider -> SIMD3<Double> in
            var primary = SIMD3<Double>.zero
            primary[index] = 1
            let along = simd_dot(primary, neutral) * neutral
            let angle = recipe[slider.hue] / 100 * maximumHueTurn * .pi / 180
            let scale = 1 + recipe[slider.saturation] / 100 * saturationReach
            // Rodrigues' rotation of the chroma part about the neutral axis.
            let chroma = primary - along
            let turned = chroma * cos(angle) + simd_cross(neutral, chroma) * sin(angle)
            return along + turned * scale
        }
        let matrix = simd_double3x3(columns: (primaries[0], primaries[1], primaries[2]))
        guard abs(matrix.determinant) > 1e-9 else { return nil }
        let weights = matrix.inverse * SIMD3<Double>(repeating: 1)
        return matrix * simd_double3x3(diagonal: weights)
    }
}
