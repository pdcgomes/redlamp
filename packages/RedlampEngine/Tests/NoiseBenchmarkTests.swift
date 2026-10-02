import Foundation
import Metal
import RedlampEngineAPI
import RedlampServices
import simd
import Testing
@testable import RedlampEngine

/// Measures noise reduction on a synthetic scene with known truth: dead leaves (texture at every
/// scale, natural-image statistics), a flat patch, and a clipped highlight, mosaicked with exact
/// Poisson–Gaussian noise and run through the real session builder and detail stage. Scores are
/// against the same pipeline without noise.
///
/// The full sweep prints a table and runs on request (`TEST_RUNNER_REDLAMP_NR_BENCHMARK=1`); a
/// light version checks that the default settings help.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct NoiseBenchmarkTests {
    static let width = 1024
    static let height = 768
    static let benchmarking = ProcessInfo.processInfo.environment["REDLAMP_NR_BENCHMARK"] == "1"

    let detail: DetailStageTests

    init() throws {
        detail = try DetailStageTests()
    }

    /// The scene in linear camera RGB (white-balanced, 1 = clip), per pixel.
    static let scene: [SIMD3<Float>] = {
        var pixels = [SIMD3<Float>](repeating: SIMD3(repeating: 0.18), count: width * height)
        var random = BenchmarkRandom(seed: 17)
        let leavesWidth = width * 2 / 3
        // Dead leaves: discs with sizes distributed as 1/r³, drawn back to front.
        let (minimum, maximum): (Float, Float) = (2, 90)
        for _ in 0 ..< 4000 {
            let u = random.uniform()
            let radius = 1 / (pow(minimum, -2) - u * (pow(minimum, -2) - pow(maximum, -2))).squareRoot()
            let cx = random.uniform() * Float(leavesWidth), cy = random.uniform() * Float(height)
            let grey = 0.04 + 0.6 * random.uniform() * random.uniform()
            let tint = SIMD3(random.uniform(), random.uniform(), random.uniform()) - 0.5
            let colour = simd_max(SIMD3(repeating: grey) * (1 + 0.8 * tint), SIMD3(repeating: 0.01))
            let x0 = max(0, Int(cx - radius)), x1 = min(leavesWidth - 1, Int(cx + radius))
            let y0 = max(0, Int(cy - radius)), y1 = min(height - 1, Int(cy + radius))
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0 ... y1 {
                for x in x0 ... x1
                    where (Float(x) - cx) * (Float(x) - cx) + (Float(y) - cy) * (Float(y) - cy) <= radius * radius {
                    pixels[y * width + x] = colour
                }
            }
        }
        // A coloured light with only its red clipped (a lamp at dusk), on a blue ground, bottom right.
        let (hx, hy) = (Float(leavesWidth + (width - leavesWidth) / 2), Float(height * 3 / 4))
        for y in height / 2 ..< height {
            for x in leavesWidth ..< width {
                let distance = hypot(Float(x) - hx, Float(y) - hy)
                pixels[y * width + x] = distance < 80 ? SIMD3(1.5, 0.7, 0.35) : SIMD3(0.12, 0.18, 0.3)
            }
        }
        return pixels
    }()

    enum Region {
        case leaves, flat, highlightRing

        func contains(_ x: Int, _ y: Int) -> Bool {
            let leavesWidth = NoiseBenchmarkTests.width * 2 / 3
            let (hx, hy) = (
                Double(leavesWidth + (NoiseBenchmarkTests.width - leavesWidth) / 2),
                Double(NoiseBenchmarkTests.height * 3 / 4),
            )
            switch self {
            case .leaves: return x > 8 && x < leavesWidth - 8 && y > 8 && y < NoiseBenchmarkTests.height - 8
            case .flat: return x > leavesWidth + 16 && x < NoiseBenchmarkTests.width - 16 && y > 16
                && y < NoiseBenchmarkTests.height / 2 - 16
            case .highlightRing:
                let distance = hypot(Double(x) - hx, Double(y) - hy)
                return distance > 82 && distance < 100
            }
        }
    }

    struct Score {
        /// Luminance PSNR in a square-root (roughly perceptual) encoding, over the dead leaves.
        var psnr: Double
        /// How much of the clean texture's high-pass survives (1 kept, 0 gone), over the leaves.
        var texture: Double
        /// RMS chroma error in the flat patch, in the square-root encoding.
        var chroma: Double
        /// The colour cast just outside the clipped highlight: the ring's mean chroma error (noise
        /// averages out of it; a spread of the highlight's colour doesn't).
        var fringe: Double
    }

    func session(noise: Float) throws -> ImageSession {
        let pattern: [Int] = [0, 1, 1, 2]
        // The file's noise profile matches the noise, as a calibrated or measured one would.
        let variance = max(noise * noise, 1e-6)
        let profile = NoiseModel(a: DetailStageTests.noise.a * variance, b: DetailStageTests.noise.b * variance)
        return try detail.makeSession(
            .bayer, width: Self.width, height: Self.height, noiseScale: noise, profile: profile,
        ) { x, y in
            Self.scene[y * Self.width + x][pattern[(y % 2) * 2 + x % 2]]
        }
    }

    func score(_ result: [SIMD3<Float>], truth: [SIMD3<Float>]) -> Score {
        func encode(_ v: SIMD3<Float>) -> SIMD3<Double> {
            SIMD3<Double>(simd_max(v, .zero)).squareRoot()
        }
        func luma(_ v: SIMD3<Double>) -> Double {
            (v.x + v.y + v.z) / 3
        }
        func chroma(_ v: SIMD3<Double>) -> SIMD2<Double> {
            SIMD2(v.x - v.y, v.z - v.y)
        }
        func highPass(_ image: [SIMD3<Float>], _ x: Int, _ y: Int) -> Double {
            let centre = luma(encode(image[y * Self.width + x]))
            var sum = 0.0
            for dy in -1 ... 1 {
                for dx in -1 ... 1 {
                    sum += luma(encode(image[(y + dy) * Self.width + x + dx]))
                }
            }
            return centre - sum / 9
        }
        var squared = 0.0, count = 0.0, kept = 0.0, clean = 0.0
        var chromaSquared = 0.0, chromaCount = 0.0, fringe = SIMD2<Double>.zero, ringCount = 0.0
        for y in stride(from: 1, to: Self.height - 1, by: 1) {
            for x in stride(from: 1, to: Self.width - 1, by: 1) {
                let index = y * Self.width + x
                let a = encode(result[index]), b = encode(truth[index])
                if Region.leaves.contains(x, y) {
                    squared += (luma(a) - luma(b)) * (luma(a) - luma(b))
                    count += 1
                    if x % 2 == 0, y % 2 == 0 {
                        let hc = highPass(truth, x, y)
                        kept += highPass(result, x, y) * hc
                        clean += hc * hc
                    }
                } else if Region.flat.contains(x, y) {
                    chromaSquared += simd_length_squared(chroma(a) - chroma(b))
                    chromaCount += 1
                } else if Region.highlightRing.contains(x, y) {
                    fringe += chroma(a) - chroma(b)
                    ringCount += 1
                }
            }
        }
        return Score(
            psnr: 10 * log10(1 / max(squared / count, 1e-12)),
            texture: kept / max(clean, 1e-12),
            chroma: (chromaSquared / max(chromaCount, 1)).squareRoot(),
            fringe: simd_length(fringe / max(ringCount, 1)),
        )
    }

    /// The noisy session through noise reduction at these settings (with none, the stage is
    /// skipped and the pyramid is what renders).
    private func reduced(_ session: ImageSession, luminance: Double, color: Double) throws -> [SIMD3<Float>] {
        var recipe = DetailStageTests.unsharpened
        recipe[.noiseLuminance] = luminance
        recipe[.noiseColor] = color
        guard luminance > 0 || color > 0 else { return try detail.readLevel(session, level: 0) }
        return try detail.processed(session, recipe: recipe)
    }

    /// Default noise reduction (Color 25) and a typical Luminance setting must improve on none.
    @Test func `noise reduction improves the scene it is meant for`() throws {
        let truth = try detail.readLevel(session(noise: 0), level: 0)
        let noisy = try session(noise: 2)
        let none = try score(reduced(noisy, luminance: 0, color: 0), truth: truth)
        let some = try score(reduced(noisy, luminance: 40, color: 25), truth: truth)
        #expect(some.psnr > none.psnr + 0.5, "PSNR \(none.psnr) → \(some.psnr)")
        #expect(some.chroma < none.chroma * 0.8, "chroma \(none.chroma) → \(some.chroma)")
        // The wavelet alone keeps about 87% here; non-local means brings back most of the rest.
        #expect(some.texture > 0.88, "texture kept \(some.texture)")
    }

    @Test(.enabled(if: benchmarking))
    func `the noise reduction benchmark`() throws {
        let truth = try detail.readLevel(session(noise: 0), level: 0)
        var lines = ["noise  luminance  color  PSNR dB  texture  chroma   fringe"]
        for noise: Float in [1, 2, 4] {
            let noisy = try session(noise: noise)
            for (luminance, color) in [(0.0, 0.0), (0, 25), (25, 25), (50, 25), (75, 50), (100, 100)] {
                let s = try score(reduced(noisy, luminance: luminance, color: color), truth: truth)
                lines.append(String(
                    format: "%5.0f  %9.0f  %5.0f  %7.2f  %7.3f  %6.4f  %6.4f",
                    noise, luminance, color, s.psnr, s.texture, s.chroma, s.fringe,
                ))
            }
        }
        print(lines.joined(separator: "\n"))
    }
}

/// xorshift64*, so the scene is the same on every run.
struct BenchmarkRandom {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func uniform() -> Float {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return Float((state &* 2_685_821_657_736_338_717) >> 40) / Float(1 << 24)
    }
}
