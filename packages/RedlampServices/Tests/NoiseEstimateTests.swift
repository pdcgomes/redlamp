import Foundation
import RedlampEngineAPI
import RedlampServices
import Testing

struct NoiseEstimateTests {
    static let a: Float = 4e-4
    static let b: Float = 2e-6

    @Test func `recovers the noise of a Bayer mosaic`() throws {
        let pattern = CFAPattern(width: 2, height: 2, colors: [0, 1, 1, 2])
        let model = try #require(NoiseEstimator.estimate(synthetic(.mosaic(pattern), channels: 1)))
        expectClose(model)
    }

    /// Texture everywhere, no flat areas: the patch-covariance method must still see only the noise.
    @Test func `sees through texture on a Bayer mosaic`() throws {
        let pattern = CFAPattern(width: 2, height: 2, colors: [0, 1, 1, 2])
        let image = synthetic(.mosaic(pattern), channels: 1) { x, y in
            let wave = sin(Float(x) * 0.37 + 2 * sin(Float(y) * 0.11)) * cos(Float(y) * 0.29)
            return 0.05 + 0.6 * (0.5 + 0.5 * wave) * (0.4 + 0.6 * Float((x / 64 + y / 64) % 3) / 2)
        }
        let model = try #require(NoiseEstimator.estimate(image))
        for channel in 0 ..< 3 {
            for level: Float in [0.1, 0.3, 0.6] {
                let predicted = model.a[channel] * level + model.b[channel]
                let truth = Self.a * level + Self.b
                #expect(abs(predicted / truth - 1) < 0.25, "channel \(channel) at \(level): \(predicted / truth)")
            }
        }
    }

    @Test func `recovers the noise of an X-Trans mosaic`() throws {
        let colors: [UInt8] = [
            1, 1, 0, 1, 1, 2,
            1, 1, 2, 1, 1, 0,
            2, 0, 1, 0, 2, 1,
            1, 1, 2, 1, 1, 0,
            1, 1, 0, 1, 1, 2,
            0, 2, 1, 2, 0, 1,
        ]
        let pattern = CFAPattern(width: 6, height: 6, colors: colors)
        let model = try #require(NoiseEstimator.estimate(synthetic(.mosaic(pattern), channels: 1)))
        expectClose(model)
    }

    @Test func `recovers the noise of linear RGB`() throws {
        let model = try #require(NoiseEstimator.estimate(synthetic(.linearRGB, channels: 3)))
        expectClose(model)
    }

    /// Every sample camera gets a plausible estimate; a DNG with its own profile also checks the
    /// blind estimate against it.
    @Test(.enabled(if: !DecodeRegressionTests.fixtures.isEmpty), arguments: DecodeRegressionTests.fixtures)
    func `estimates real sensors`(url: URL) throws {
        let decoded = try ImageDecoder.decode(url)
        let clock = ContinuousClock()
        let start = clock.now
        let blind = try #require(NoiseEstimator.estimate(decoded))
        let elapsed = clock.now - start
        print("noise \(url.lastPathComponent): a \(blind.a) b \(blind.b) in \(elapsed)")
        if let profile = decoded.noiseProfile {
            print("noise \(url.lastPathComponent) profile: a \(profile.a) b \(profile.b)")
        }
        for channel in 0 ..< 3 {
            let sigma = (blind.a[channel] * 0.18 + blind.b[channel]).squareRoot()
            #expect(sigma > 1e-4 && sigma < 0.05, "channel \(channel): σ at mid-grey \(sigma)")
        }
    }

    @Test func `white balance gains scale the model`() {
        let model = NoiseModel(a: SIMD3(1, 1, 1), b: SIMD3(1, 1, 1)).scaled(by: SIMD3(2, 1, 3))
        #expect(model.a == SIMD3(2, 1, 3))
        #expect(model.b == SIMD3(4, 1, 9))
    }

    /// The variance the model predicts, from deep shadow to highlight, within 20%.
    private func expectClose(_ model: NoiseModel) {
        for channel in 0 ..< 3 {
            for level: Float in [0.01, 0.05, 0.2, 0.6] {
                let predicted = model.a[channel] * level + model.b[channel]
                let truth = Self.a * level + Self.b
                #expect(
                    abs(predicted / truth - 1) < 0.2,
                    "channel \(channel) at \(level): a = \(model.a[channel]), b = \(model.b[channel])",
                )
            }
        }
    }

    /// Flat 16×16 patches of random brightness, a band of strong texture that the estimate must
    /// ignore, and Poisson–Gaussian noise with known `a` and `b`.
    private func synthetic(
        _ layout: DecodedImage.Layout,
        channels: Int,
        scene: ((Int, Int) -> Float)? = nil,
    ) -> DecodedImage {
        let width = 1536
        let height = 1024
        let black: Float = 512
        let white: Float = 16383
        var random = SeededRandom(seed: 42)
        let patches = (0 ..< (width / 16) * (height / 16)).map { _ in 0.01 + 0.8 * random.uniform() }
        var samples = [UInt16](repeating: 0, count: width * height * channels)
        for y in 0 ..< height {
            for x in 0 ..< width {
                for channel in 0 ..< channels {
                    var signal = scene?(x, y) ?? patches[(y / 16) * (width / 16) + x / 16]
                    if scene == nil, y < 128 {
                        signal = 0.4 + 0.35 * sin(Float(x) * 0.7) * cos(Float(y) * 0.9)
                    }
                    let sigma = (Self.a * signal + Self.b).squareRoot()
                    let value = signal + sigma * random.gaussian()
                    let raw = black + value * (white - black)
                    samples[(y * width + x) * channels + channel] = UInt16(min(max(raw, 0), 65535).rounded())
                }
            }
        }
        let blacks = [Float](repeating: black, count: channels == 1 ? 4 : 3)
        return DecodedImage(
            width: width, height: height, layout: layout, samples: samples,
            blackLevels: blacks, whiteLevel: white, asShotMultipliers: SIMD3(1, 1, 1),
            cameraToSRGB: [1, 0, 0, 0, 1, 0, 0, 0, 1], xyzToCamera: nil, orientation: 0, baselineExposure: 0,
            info: ImageInfo(
                url: URL(fileURLWithPath: "/synthetic.dng"), pixelSize: PixelSize(width: width, height: height),
                isRaw: true, sensorDescription: "synthetic",
            ),
        )
    }
}

/// xorshift64* with Box–Muller, so tests are reproducible.
private struct SeededRandom {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
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
