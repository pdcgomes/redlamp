import Foundation
import simd

/// A spectral quantity sampled every 5 nm from 380 to 730 nm, the range film datasheets cover.
struct Spectrum: Sendable {
    static let wavelengths: [Double] = stride(from: 380.0, through: 730.0, by: 5.0).map(\.self)
    static let count = wavelengths.count
    static let step = 5.0

    var values: [Double]

    init(values: [Double]) {
        precondition(values.count == Self.count)
        self.values = values
    }

    init(_ function: (Double) -> Double) {
        values = Self.wavelengths.map(function)
    }

    static func constant(_ value: Double) -> Spectrum {
        Spectrum { _ in value }
    }

    /// Resamples measured points (any spacing, ascending) with linear interpolation; outside
    /// the measured range the nearest end value holds, or `outside` when given.
    init(wavelengths: [Double], values: [Double], outside: Double? = nil) {
        self.init { lambda in
            guard let first = wavelengths.first, let last = wavelengths.last else { return outside ?? 0 }
            if lambda < first {
                return outside ?? values[0]
            }
            if lambda > last {
                return outside ?? values[values.count - 1]
            }
            var i = 0
            while i < wavelengths.count - 2, wavelengths[i + 1] < lambda {
                i += 1
            }
            let t = (lambda - wavelengths[i]) / max(wavelengths[i + 1] - wavelengths[i], 1e-9)
            return values[i] + (values[i + 1] - values[i]) * min(max(t, 0), 1)
        }
    }

    static func * (a: Spectrum, b: Spectrum) -> Spectrum {
        Spectrum(values: zip(a.values, b.values).map(*))
    }

    static func * (a: Spectrum, k: Double) -> Spectrum {
        Spectrum(values: a.values.map { $0 * k })
    }

    static func + (a: Spectrum, b: Spectrum) -> Spectrum {
        Spectrum(values: zip(a.values, b.values).map(+))
    }

    /// ∫ self(λ) dλ, by the trapezoid rule.
    var integral: Double {
        var total = 0.0
        for i in 1 ..< values.count {
            total += 0.5 * (values[i - 1] + values[i]) * Self.step
        }
        return total
    }

    func dot(_ other: Spectrum) -> Double {
        (self * other).integral
    }

    /// 10^(−density).
    var transmittance: Spectrum {
        Spectrum(values: values.map { pow(10, -$0) })
    }
}

/// Colour-matching functions, illuminants and the conversions the film model needs.
enum Colorimetry {
    /// CIE 1931 2° observer, as the multi-lobe Gaussian fit of Wyman, Sloan and Shirley (2013).
    static let cmf: (x: Spectrum, y: Spectrum, z: Spectrum) = {
        func g(_ lambda: Double, _ mu: Double, _ below: Double, _ above: Double) -> Double {
            let t = (lambda - mu) / (lambda < mu ? below : above)
            return exp(-0.5 * t * t)
        }
        return (
            Spectrum { 1.056 * g($0, 599.8, 37.9, 31.0) + 0.362 * g($0, 442.0, 16.0, 26.7) - 0.065 * g(
                $0,
                501.1,
                20.4,
                26.2,
            ) },
            Spectrum { 0.821 * g($0, 568.8, 46.9, 40.5) + 0.286 * g($0, 530.9, 16.3, 31.1) },
            Spectrum { 1.217 * g($0, 437.0, 11.8, 36.0) + 0.681 * g($0, 459.0, 26.0, 13.8) },
        )
    }()

    /// Planck's law, normalised to 1 at 560 nm.
    static func blackbody(kelvin: Double) -> Spectrum {
        func planck(_ nm: Double) -> Double {
            let lambda = nm * 1e-9
            return 1 / (pow(lambda, 5) * (exp(1.438776877e-2 / (lambda * kelvin)) - 1))
        }
        let reference = planck(560)
        return Spectrum { planck($0) / reference }
    }

    /// Stand-ins for the CIE daylight illuminants; every white is normalised away, so only
    /// the spectral shape between whites matters.
    static let daylight65 = blackbody(kelvin: 6504)
    static let daylight50 = blackbody(kelvin: 5003)
    static let tungsten = blackbody(kelvin: 3200)
    /// A xenon cinema projector.
    static let xenon = blackbody(kelvin: 5900)

    static func xyz(_ spectrum: Spectrum) -> SIMD3<Double> {
        SIMD3(spectrum.dot(cmf.x), spectrum.dot(cmf.y), spectrum.dot(cmf.z))
    }

    static let xyzToRec2020 = simd_double3x3(rows: [
        SIMD3(1.7166512, -0.3556708, -0.2533663),
        SIMD3(-0.6666844, 1.6164812, 0.0157685),
        SIMD3(0.0176399, -0.0427706, 0.9421031),
    ])
    static let rec2020ToXYZ = xyzToRec2020.inverse
    static let whiteD65 = SIMD3(0.95047, 1.0, 1.08883)

    private static let bradford = simd_double3x3(rows: [
        SIMD3(0.8951, 0.2664, -0.1614),
        SIMD3(-0.7502, 1.7135, 0.0367),
        SIMD3(0.0389, -0.0685, 1.0296),
    ])

    /// Bradford chromatic adaptation from one white to another (both XYZ, any scale).
    static func adaptation(from source: SIMD3<Double>, to target: SIMD3<Double>) -> simd_double3x3 {
        let s = bradford * (source / source.y)
        let t = bradford * (target / target.y)
        return bradford.inverse * simd_double3x3(diagonal: t / s) * bradford
    }
}
