import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampServices

/// Calibrated per-camera noise profiles (DN-01).
struct NoiseProfileTests {
    static let a = SIMD3<Float>(2.0e-4, 1.5e-4, 2.5e-4)
    static let b = SIMD3<Float>(4e-7, 3e-7, 5e-7)

    /// A flat frame: `level` falling off a third towards the corners, the same 2% pixel-to-pixel
    /// gain pattern in every frame (fixed-pattern noise), and Poisson–Gaussian noise per colour.
    private func flat(level: Float, iso: Double, seed: UInt64) -> DecodedImage {
        let (width, height) = (512, 384)
        let black: Float = 512, white: Float = 16383
        var pattern = CalibrationRandom(seed: 7)
        let gains = (0 ..< width * height).map { _ in 1 + 0.02 * pattern.gaussian() }
        var random = CalibrationRandom(seed: seed)
        var samples = [UInt16](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let dx = Float(x) / Float(width) - 0.5, dy = Float(y) / Float(height) - 0.5
                let signal = level * (1 - 0.66 * (dx * dx + dy * dy)) * gains[y * width + x]
                let color = [0, 1, 1, 2][(y % 2) * 2 + x % 2]
                let sigma = (Self.a[color] * signal + Self.b[color]).squareRoot()
                let raw = black + (signal + sigma * random.gaussian()) * (white - black)
                samples[y * width + x] = UInt16(min(max(raw, 0), 65535).rounded())
            }
        }
        var info = ImageInfo(
            url: URL(fileURLWithPath: "/flat.ARW"), pixelSize: PixelSize(width: width, height: height),
            isRaw: true, sensorDescription: "synthetic",
        )
        info.make = "SONY"
        info.model = "ILCE-7M3"
        info.iso = iso
        return DecodedImage(
            width: width, height: height, layout: .mosaic(CFAPattern(width: 2, height: 2, colors: [0, 1, 1, 2])),
            samples: samples, blackLevels: [black, black, black, black], whiteLevel: white,
            asShotMultipliers: SIMD3(1, 1, 1), cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil,
            orientation: 0, baselineExposure: 0, info: info,
        )
    }

    @Test func `photon transfer recovers each colour's noise from flat pairs`() throws {
        var measurements: [[NoiseCalibration.Measurement]] = [[], [], []]
        let levels: [Float] = [0, 0.03, 0.1, 0.2, 0.35, 0.5, 0.7]
        for (index, level) in levels.enumerated() {
            let pair = NoiseCalibration.measure(
                flat(level: level, iso: 400, seed: UInt64(10 + index)),
                flat(level: level, iso: 400, seed: UInt64(100 + index)),
            )
            for channel in 0 ..< 3 {
                measurements[channel] += pair[channel]
            }
        }
        let point = try #require(NoiseCalibration.point(iso: 400, pairs: levels.count, measurements: measurements))
        for channel in 0 ..< 3 {
            let a = point.a[channel], b = point.b[channel]
            #expect(abs(a - Self.a[channel]) < Self.a[channel] * 0.04, "a[\(channel)] = \(a)")
            #expect(abs(b - Self.b[channel]) < Self.b[channel] * 0.15, "b[\(channel)] = \(b)")
        }
    }

    @Test func `frames pair by ISO and level, each once`() {
        let frames = [
            NoiseCalibration.FrameSummary(iso: 100, level: 0.20),
            NoiseCalibration.FrameSummary(iso: 100, level: 0.001),
            NoiseCalibration.FrameSummary(iso: 400, level: 0.201),
            NoiseCalibration.FrameSummary(iso: 100, level: 0.203),
            NoiseCalibration.FrameSummary(iso: 100, level: 0.0012),
            NoiseCalibration.FrameSummary(iso: 100, level: 0.5),
        ]
        let pairs = NoiseCalibration.pairs(frames).map { Set([$0.0, $0.1]) }
        #expect(Set(pairs) == [[1, 4], [0, 3]], "the ISO 400 frame and the lone bright one stay out")
    }

    static let profile = CameraNoiseProfile(make: "Sony", model: "ILCE-7M3", source: "test", points: [
        .init(iso: 400, a: SIMD3(repeating: 4e-4), b: SIMD3(repeating: 1.6e-6)),
        .init(iso: 100, a: SIMD3(repeating: 1e-4), b: SIMD3(repeating: 1e-7)),
    ])

    @Test func `between calibrated ISOs the noise follows the gain, and a stop past them at most`() throws {
        let between = try #require(Self.profile.model(iso: 200))
        #expect(abs(between.a.y - 2e-4) < 1e-9 && abs(between.b.y - 4e-7) < 1e-12)
        let above = try #require(Self.profile.model(iso: 800))
        #expect(abs(above.a.y - 8e-4) < 1e-9 && abs(above.b.y - 6.4e-6) < 1e-11)
        #expect(Self.profile.model(iso: 1600) == nil)
        #expect(Self.profile.model(iso: 50) != nil && Self.profile.model(iso: 25) == nil)
    }

    @Test func `a profile is the camera's whatever the maker's name`() {
        #expect(Self.profile.matches(make: "SONY", model: "ILCE-7M3"))
        #expect(Self.profile.matches(make: "Sony Group Corporation", model: "ilce-7m3"))
        #expect(!Self.profile.matches(make: "Sony", model: "ILCE-7M4"))
        #expect(!Self.profile.matches(make: "Nikon", model: "ILCE-7M3"))
    }

    @Test func `the camera's profile renders, unless the raw is far cleaner than it`() {
        let image = flat(level: 0.2, iso: 400, seed: 3)
        let exact = NoiseProfileCatalog(profiles: [CameraNoiseProfile(
            make: "Sony", model: "ILCE-7M3", source: "test", points: [.init(iso: 400, a: Self.a, b: Self.b)],
        )])
        #expect(image.noise(profiles: exact) == NoiseModel(a: Self.a, b: Self.b))
        // Ten times the noise this raw has: noise reduction in camera, or another camera's profile.
        let noisier = NoiseProfileCatalog(profiles: [CameraNoiseProfile(
            make: "Sony", model: "ILCE-7M3", source: "test", points: [.init(iso: 400, a: Self.a * 10, b: Self.b)],
        )])
        #expect(image.noise(profiles: noisier) == NoiseEstimator.estimate(image))
        // The file's own profile comes first.
        var tagged = image
        tagged.noiseProfile = NoiseModel(a: SIMD3(repeating: 1e-3), b: SIMD3(repeating: 1e-6))
        #expect(tagged.noise(profiles: exact) == tagged.noiseProfile)
    }
}

/// xorshift64* with Box–Muller, so tests are reproducible.
private struct CalibrationRandom {
    var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }

    mutating func uniform() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    mutating func gaussian() -> Float {
        let u1 = max(uniform(), 1e-7)
        let u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
