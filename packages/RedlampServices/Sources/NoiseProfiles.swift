import Foundation
import RedlampEngineAPI

/// One camera's sensor noise, measured from calibration frames (`NoiseCalibration`) at a series
/// of ISOs, in `NoiseModel`'s units (DN-01).
public struct CameraNoiseProfile: Codable, Sendable, Hashable {
    public struct Point: Codable, Sendable, Hashable {
        public var iso: Double
        public var a: SIMD3<Float>
        public var b: SIMD3<Float>
        /// Frame pairs and tiles the point was fitted from.
        public var pairs: Int
        public var tiles: Int

        public init(iso: Double, a: SIMD3<Float>, b: SIMD3<Float>, pairs: Int = 0, tiles: Int = 0) {
            self.iso = iso
            self.a = a
            self.b = b
            self.pairs = pairs
            self.tiles = tiles
        }

        public var model: NoiseModel {
            NoiseModel(a: a, b: b)
        }
    }

    /// As LibRaw names them (`ImageInfo.make` and `model`).
    public var make: String
    public var model: String
    /// How and when the frames were captured.
    public var source: String
    /// By ISO.
    public var points: [Point]

    public init(make: String, model: String, source: String, points: [Point]) {
        self.make = make
        self.model = model
        self.source = source
        self.points = points.sorted { $0.iso < $1.iso }
    }

    /// How far past the calibrated ISOs the profile still answers, in stops.
    public static let extrapolation = 1.0

    /// The noise at `iso`: between calibrated ISOs, `a` and `b` are interpolated on log scales
    /// (each grows as a power of the gain); within a stop beyond them, the nearest point is
    /// scaled as gain scales them, `a` with ISO and `b` with its square. Nil further out.
    public func model(iso: Double) -> NoiseModel? {
        guard iso > 0, let first = points.first, let last = points.last else { return nil }
        if iso <= first.iso {
            return Self.scaled(first, to: iso)
        }
        if iso >= last.iso {
            return Self.scaled(last, to: iso)
        }
        guard let upper = points.firstIndex(where: { $0.iso >= iso }) else { return nil }
        let high = points[upper], low = points[upper - 1]
        let t = Float(log(iso / low.iso) / log(high.iso / low.iso))
        func blend(_ x: SIMD3<Float>, _ y: SIMD3<Float>) -> SIMD3<Float> {
            var result = SIMD3<Float>()
            for channel in 0 ..< 3 {
                result[channel] = exp(log(max(x[channel], 1e-12)) * (1 - t) + log(max(y[channel], 1e-12)) * t)
            }
            return result
        }
        return NoiseModel(a: blend(low.a, high.a), b: blend(low.b, high.b))
    }

    private static func scaled(_ point: Point, to iso: Double) -> NoiseModel? {
        let ratio = iso / point.iso
        guard abs(log2(ratio)) <= extrapolation + 1e-9 else { return nil }
        let gain = Float(ratio)
        return NoiseModel(a: point.a * gain, b: point.b * gain * gain)
    }

    /// Whether the profile is this camera's: the same model, from a maker of the same first word
    /// ("NIKON CORPORATION" and "Nikon").
    public func matches(make: String?, model: String?) -> Bool {
        guard let model else { return false }
        func words(_ text: String) -> [String] {
            text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        }
        guard words(model) == words(self.model) else { return false }
        guard let make, let maker = words(make).first else { return true }
        return words(self.make).first == maker
    }
}

/// The calibrated cameras Redlamp ships with (`Resources/NoiseProfiles`).
public struct NoiseProfileCatalog: Sendable {
    public var profiles: [CameraNoiseProfile]

    public init(profiles: [CameraNoiseProfile]) {
        self.profiles = profiles
    }

    public static let bundled: NoiseProfileCatalog = {
        let bundle = Bundle(for: BundleToken.self)
        // Xcode may flatten the NoiseProfiles folder into the bundle's root.
        let nested = bundle.urls(forResourcesWithExtension: "json", subdirectory: "NoiseProfiles") ?? []
        let urls = !nested.isEmpty ? nested
            : (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("noise-") }
        let profiles = urls.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(CameraNoiseProfile.self, from: $0) }
        }
        return NoiseProfileCatalog(profiles: profiles)
    }()

    public func profile(for info: ImageInfo) -> CameraNoiseProfile? {
        profiles.first { $0.matches(make: info.make, model: info.model) }
    }

    /// The photo's noise from its camera's profile, at its ISO.
    public func model(for info: ImageInfo) -> NoiseModel? {
        guard let iso = info.iso else { return nil }
        return profile(for: info)?.model(iso: iso)
    }
}

private final class BundleToken {}
