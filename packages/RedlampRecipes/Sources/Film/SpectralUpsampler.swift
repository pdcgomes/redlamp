import Foundation
import simd

/// Turns linear Rec.2020 scene colours into smooth spectra, so film layers can "see" them
/// through their own spectral sensitivities.
///
/// Each colour's shape is a sigmoid of a quadratic in wavelength (Jakob and Hanika, 2019),
/// fitted so the spectrum, lit by the scene illuminant, has the colour's XYZ. Shapes are fitted
/// at a reflectance of at most `peak` and scaled, so they only depend on chromaticity and are
/// cached by it.
final class SpectralUpsampler {
    let illuminant: Spectrum
    private let illuminantY: Double
    private let toIlluminant: simd_double3x3
    private let peak = 0.9
    private var cache: [SIMD3<Int32>: SIMD3<Double>] = [:]
    private let normalised: [Double]

    init(illuminant: Spectrum = Colorimetry.daylight65) {
        self.illuminant = illuminant
        let white = Colorimetry.xyz(illuminant)
        illuminantY = white.y
        toIlluminant = Colorimetry.adaptation(from: Colorimetry.whiteD65, to: white)
        normalised = Spectrum.wavelengths.map { ($0 - 380) / 350 }
    }

    /// The spectral radiance of a scene colour: its reflectance-like spectrum times the illuminant.
    func radiance(_ rgb: SIMD3<Double>) -> Spectrum {
        reflectance(rgb) * illuminant
    }

    func reflectance(_ rgb: SIMD3<Double>) -> Spectrum {
        let clipped = simd_max(rgb, SIMD3(repeating: 0))
        let top = clipped.max()
        guard top > 1e-9 else { return .constant(0) }
        let shape = clipped / top * peak
        let key = SIMD3<Int32>(
            Int32((shape.x * 20000).rounded()), Int32((shape.y * 20000).rounded()), Int32((shape.z * 20000).rounded()),
        )
        let coefficients = cache[key] ?? {
            let fitted = fit(shape)
            cache[key] = fitted
            return fitted
        }()
        return sigmoidSpectrum(coefficients) * (top / peak)
    }

    private func sigmoidSpectrum(_ c: SIMD3<Double>) -> Spectrum {
        Spectrum(values: normalised.map { t in
            let x = c.x * t * t + c.y * t + c.z
            return 0.5 + x / (2 * (1 + x * x).squareRoot())
        })
    }

    private func xyz(of c: SIMD3<Double>) -> SIMD3<Double> {
        Colorimetry.xyz(sigmoidSpectrum(c) * illuminant) / illuminantY
    }

    /// Levenberg–Marquardt on the three coefficients, towards the colour's XYZ under the
    /// illuminant. Colours no reflectance can reach land on the closest one it can.
    private func fit(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let target = toIlluminant * (Colorimetry.rec2020ToXYZ * rgb)
        var c = SIMD3<Double>(0, 0, 0)
        var residual = xyz(of: c) - target
        var damping = 1e-3
        for _ in 0 ..< 60 {
            let error = simd_length_squared(residual)
            if error < 1e-12 {
                break
            }
            var jacobian = simd_double3x3()
            for k in 0 ..< 3 {
                var step = c
                step[k] += 1e-4
                jacobian[k] = (xyz(of: step) - xyz(of: c)) / 1e-4
            }
            let normal = jacobian.transpose * jacobian
            let gradient = jacobian.transpose * residual
            let damped = normal + simd_double3x3(diagonal: SIMD3(repeating: damping) * SIMD3(
                normal[0][0],
                normal[1][1],
                normal[2][2],
            ) + 1e-12)
            let candidate = simd_clamp(c - damped.inverse * gradient, SIMD3(repeating: -2000), SIMD3(repeating: 2000))
            let next = xyz(of: candidate) - target
            if simd_length_squared(next) < error {
                c = candidate
                residual = next
                damping = max(damping * 0.3, 1e-7)
            } else {
                damping *= 10
                if damping > 1e8 {
                    break
                }
            }
        }
        return c
    }
}
