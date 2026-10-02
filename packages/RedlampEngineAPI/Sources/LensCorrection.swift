import Foundation
import simd

/// A lens correction the photo carries (LNS-01, LNS-02): every source, whether DNG warp opcodes or
/// a maker's correction tags, as the same tables over the distance from the optical centre.
///
/// Positions are in the EXIF-oriented photo. A radius of 1 is the farthest corner from the
/// centre (the DNG specification's normalisation, which for a centred lens is the half-diagonal).
public struct LensCorrection: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable {
        /// The DNG's OpcodeList3 (WarpRectilinear, FixVignetteRadial), as phones write them.
        case dng
        /// Sony's correction tags in the ARW, the camera's own built-in profile.
        case sony
        /// Measured from the photo's own edges (Remove Chromatic Aberration).
        case measured

        public var name: String {
            switch self {
            case .dng: "DNG"
            case .sony: "Sony"
            case .measured: "Measured"
            }
        }
    }

    public var source: Source
    /// The optical centre, 0...1.
    public var center: SIMD2<Double>
    /// Radii of the table entries, increasing, starting at or below 0.
    public var radii: [Double]
    /// Per radius of the corrected photo: where each of red, green and blue was recorded, as a
    /// multiple of the radius. Empty without distortion correction.
    public var distortion: [SIMD3<Double>]
    /// Per radius of the recorded photo: the gain that undoes the lens's vignetting. Empty
    /// without vignetting correction.
    public var vignetting: [Double]

    public init(
        source: Source, center: SIMD2<Double>, radii: [Double], distortion: [SIMD3<Double>], vignetting: [Double],
    ) {
        self.source = source
        self.center = center
        self.radii = radii
        self.distortion = distortion
        self.vignetting = vignetting
    }

    /// Whether red and blue are recorded at another scale than green (lateral chromatic aberration).
    public var correctsColorFringes: Bool {
        distortion.contains { abs($0.x - $0.y) > 1e-7 || abs($0.z - $0.y) > 1e-7 }
    }

    /// Linear interpolation of a table over `radii`, holding the ends.
    public func interpolate<T: SIMD>(_ values: [T], at radius: Double) -> T where T.Scalar == Double {
        guard let first = values.first else { return T(repeating: 1) }
        guard radius > radii[0] else { return first }
        for index in 1 ..< min(radii.count, values.count) where radius <= radii[index] {
            let t = (radius - radii[index - 1]) / (radii[index] - radii[index - 1])
            return values[index - 1] + (values[index] - values[index - 1]) * T(repeating: t)
        }
        return values[min(radii.count, values.count) - 1]
    }

    public func interpolate(_ values: [Double], at radius: Double) -> Double {
        interpolate(values.map { SIMD2(repeating: $0) }, at: radius).x
    }

    /// The same correction at a strength: distortion's departure from 1 and vignetting's gain in
    /// stops scale with the amounts (1 as recorded).
    public func scaled(distortion distortionAmount: Double, vignetting vignettingAmount: Double) -> LensCorrection {
        var scaled = self
        scaled.distortion = distortion.map { 1 + ($0 - 1) * distortionAmount }
        scaled.vignetting = vignetting.map { pow(max($0, 1e-4), vignettingAmount) }
        return scaled
    }

    /// The correction scaled up just enough that the corrected frame stays inside the photo, as
    /// Lightroom's profile corrections do: a correction that pulls the edges in (pincushion)
    /// would otherwise leave the corners empty. The zoom folds into the distortion table.
    public func filling(imageSize: PixelSize) -> LensCorrection {
        guard !distortion.isEmpty else { return self }
        let scale = offsetScale(imageSize: imageSize)
        let border = (0 ... 16).flatMap { index -> [SIMD2<Double>] in
            let t = Double(index) / 16
            return [SIMD2(t, 0), SIMD2(t, 1), SIMD2(0, t), SIMD2(1, t)]
        }
        func fits(_ zoom: Double) -> Bool {
            border.allSatisfy { point in
                let offset = (point - center) / zoom
                let source = center + offset * interpolate(distortion, at: simd_length(offset * scale)).y
                return source.min() >= -1e-6 && source.max() <= 1 + 1e-6
            }
        }
        guard !fits(1) else { return self }
        var (low, high) = (1.0, 1.5)
        for _ in 0 ..< 40 {
            let middle = (low + high) / 2
            if fits(middle) {
                high = middle
            } else {
                low = middle
            }
        }
        var zoomed = self
        zoomed.distortion = radii.map { interpolate(distortion, at: $0 / high) / high }
        return zoomed
    }

    /// Photo coordinates (0...1) to the lens's normalised offset from the centre, for a photo of `size`.
    public func offsetScale(imageSize size: PixelSize) -> SIMD2<Double> {
        let (w, h) = (Double(size.width), Double(size.height))
        let reach = SIMD2(max(center.x, 1 - center.x) * w, max(center.y, 1 - center.y) * h)
        return SIMD2(w, h) / simd_length(reach)
    }
}

public extension LensCorrection {
    /// DNG WarpRectilinear coefficients (one set per plane, or one for all), tabulated: the source
    /// radius is f(r)·r with f = kr0 + kr1 r² + kr2 r⁴ + kr3 r⁶. Tangential terms are left out:
    /// they don't survive a radial table, and phones write them as zero.
    static func tabulated(warp planes: [SIMD4<Double>], vignette: [Double]?, center: SIMD2<Double>) -> LensCorrection {
        let radii = (0 ... 32).map { Double($0) / 32 * 1.05 }
        func f(_ k: SIMD4<Double>, _ r: Double) -> Double {
            let r2 = r * r
            return k.x + k.y * r2 + k.z * r2 * r2 + k.w * r2 * r2 * r2
        }
        let distortion = planes.isEmpty ? [] : radii.map { r -> SIMD3<Double> in
            planes.count >= 3 ? SIMD3(f(planes[0], r), f(planes[1], r), f(planes[2], r)) : SIMD3(repeating: f(
                planes[0],
                r,
            ))
        }
        let vignetting = vignette.map { k in
            radii.map { r -> Double in
                let r2 = r * r
                return 1 + k[0] * r2 + k[1] * pow(r2, 2) + k[2] * pow(r2, 3) + k[3] * pow(r2, 4) + k[4] * pow(r2, 5)
            }
        } ?? []
        return LensCorrection(
            source: .dng,
            center: center,
            radii: radii,
            distortion: distortion,
            vignetting: vignetting,
        )
    }

    /// Sony's correction tags: up to 16 knots at radii (i + ½) / (n − 1) of the half-diagonal.
    /// Distortion is 1 + d·2⁻¹⁴, red and blue further 1 + c·2⁻²¹, and the vignetting gain the
    /// inverse of (2^(½ − 2^(v·2⁻¹³ − 1)))², the conventions darktable and RawTherapee use.
    static func sony(distortion: [Int], chromaticAberration: [Int], vignetting: [Int]) -> LensCorrection? {
        let count = [distortion.count, vignetting.count, chromaticAberration.count / 2].filter { $0 > 0 }.min() ?? 0
        guard count >= 2 else { return nil }
        let radii = (0 ..< count).map { (Double($0) + 0.5) / Double(count - 1) }
        let scales = distortion.isEmpty ? [] : (0 ..< count).map { i -> SIMD3<Double> in
            let green = 1 + Double(distortion[i]) * pow(2, -14)
            guard chromaticAberration.count >= 2 * count else { return SIMD3(repeating: green) }
            let red = green * (1 + Double(chromaticAberration[i]) * pow(2, -21))
            let blue = green * (1 + Double(chromaticAberration[count + i]) * pow(2, -21))
            return SIMD3(red, green, blue)
        }
        let gains = vignetting.isEmpty ? [] : (0 ..< count).map { i -> Double in
            let shading = pow(2, 0.5 - pow(2, Double(vignetting[i]) * pow(2, -13) - 1))
            return 1 / max(shading * shading, 1e-4)
        }
        return LensCorrection(
            source: .sony, center: SIMD2(0.5, 0.5), radii: radii, distortion: scales, vignetting: gains,
        )
    }
}
