import Foundation
import Metal
import RedlampEngineAPI
import RedlampKernels
import simd
import Testing
@testable import RedlampEngine

/// Noise-aware capture sharpening (SHP-01): noise passes through, deconvolution restores blur,
/// the caches render what a fresh stage renders, and masks' negative Sharpness still softens.
extension DetailStageTests {
    /// Sharpening measures detail on the separator's denoised luminance, so on a flat patch it has
    /// nothing to boost and the noise passes through as it was, at any Detail, masked or not.
    @Test func `sharpening leaves flat noise as it was`() throws {
        let session = try makeSession(.bayer, width: 512, height: 384)
        let before = try statistics(of: readLevel(session, level: 0)).deviation
        for (detail, masking) in [(0.0, 0.0), (25, 0), (100, 0), (25, 100)] {
            var recipe = Self.untouched
            recipe[.sharpenAmount] = 100
            recipe[.sharpenDetail] = detail
            recipe[.sharpenMasking] = masking
            let after = try statistics(of: processed(session, recipe: recipe)).deviation
            for channel in 0 ..< 3 {
                let ratio = after[channel] / before[channel]
                #expect(abs(ratio - 1) < 0.02, "Detail \(detail), Masking \(masking), channel \(channel): \(ratio)")
            }
        }
    }

    /// Dragging Amount reuses the cached analysis and dragging Radius the cached separation; both
    /// must render what a fresh stage renders.
    @Test func `sharpening's caches match a fresh render`() throws {
        let session = try makeSession(.bayer, width: 512, height: 384) { x, y in
            Float(0.2 + 0.1 * sin(Double(x) / 3) * cos(Double(y) / 5))
        }
        let stage = DetailStage(device: device, kernels: kernels)
        func render(_ stage: DetailStage, _ recipe: EditRecipe) throws -> [SIMD3<Float>] {
            try processAndRead(stage, session, recipe).texels
        }
        var recipe = Self.untouched
        recipe[.sharpenAmount] = 60
        recipe[.sharpenDetail] = 50
        _ = try render(stage, recipe)
        for change in [(ParameterID.sharpenAmount, 120.0), (.sharpenRadius, 2)] {
            recipe[change.0] = change.1
            let cached = try render(stage, recipe)
            let fresh = try render(DetailStage(device: device, kernels: kernels), recipe)
            let worst = zip(cached, fresh).map { simd_abs($0 - $1).max() }.max() ?? 0
            #expect(worst < 1e-5, "\(change.0): \(worst)")
        }
    }

    /// A step blurred as a soft lens blurs it (Gaussian, sigma 1.2 px). With the Radius matching the
    /// blur, Detail 100 (deconvolution) brings it closer to the sharp step than Detail 0 (unsharp
    /// masking) does. A perfect step is the hardest case for four iterations: the NumPy reference
    /// (`shp01_calibrate.py`, no demosaic) gets 0.91 of the unsharp mask's error; the GPU about 0.93.
    @Test func `deconvolution restores a blurred edge better than unsharp masking`() throws {
        let sigma = 1.2
        func step(_ x: Int, blurred: Bool) -> Float {
            let t = Double(x) + 0.5 - 256
            let edge = blurred ? 0.5 * (1 + erf(t / (sigma * 2.0.squareRoot()))) : (t > 0 ? 1 : 0)
            return Float(0.1 + 0.3 * edge)
        }
        let sharp = try readLevel(
            makeSession(.bayer, width: 512, height: 64, noiseScale: 0) { x, _ in step(x, blurred: false) }, level: 0,
        )
        let soft = try makeSession(.bayer, width: 512, height: 64, noiseScale: 0) { x, _ in step(x, blurred: true) }
        func error(_ pixels: [SIMD3<Float>]) -> Float {
            let row = 32 * 512
            let differences = (236 ... 276).map { pixels[row + $0].y - sharp[row + $0].y }
            return (differences.map { $0 * $0 }.reduce(0, +) / Float(differences.count)).squareRoot()
        }
        var recipe = Self.untouched
        recipe[.sharpenAmount] = 100
        recipe[.sharpenRadius] = sigma / 0.8
        let input = try error(readLevel(soft, level: 0))
        recipe[.sharpenDetail] = 0
        let unsharp = try error(processed(soft, recipe: recipe))
        recipe[.sharpenDetail] = 100
        let deconvolved = try error(processed(soft, recipe: recipe))
        #expect(unsharp < input, "unsharp \(unsharp), input \(input)")
        #expect(deconvolved < unsharp * 0.95, "deconvolved \(deconvolved), unsharp \(unsharp)")
    }

    /// Negative Sharpness softens the source itself, noise included, unlike sharpening, which
    /// leaves noise alone.
    @Test func `a mask's negative sharpness softens inside it`() throws {
        let session = try makeSession(.bayer, width: 768, height: 256)
        var recipe = Self.untouched
        recipe.masks = [leftHalf(.localSharpness, -100)]
        let before = try readLevel(session, level: 0)
        let after = try processed(session, recipe: recipe)
        let deviation = { (pixels: [SIMD3<Float>], columns: Range<Int>) -> Float in
            let values = (32 ..< 224).flatMap { y in columns.map { pixels[y * 768 + $0].y } }
            let mean = values.reduce(0, +) / Float(values.count)
            return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot()
        }
        let inside = deviation(after, 32 ..< 300) / deviation(before, 32 ..< 300)
        let outside = deviation(after, 468 ..< 736) / deviation(before, 468 ..< 736)
        #expect(inside < 0.9, "inside \(inside)")
        #expect(abs(outside - 1) < 0.02, "outside \(outside)")
    }

    static let benchmarking = ProcessInfo.processInfo.environment["REDLAMP_BENCHMARK_DETAIL"] == "1"

    /// GPU time of the stage for a 2560 x 1600 view at 1:1 on a 24 MP frame, per setting. On
    /// request (`TEST_RUNNER_REDLAMP_BENCHMARK_DETAIL=1`); prints medians of 16 uncached runs.
    @Test(.enabled(if: benchmarking))
    func `stage GPU time at 1:1`() throws {
        let session = try makeSession(.bayer, width: 6000, height: 4000)
        let view = PixelSize(width: 2560, height: 1600)
        let region = ImageRect(x: 0.3, y: 0.3, width: 2560.0 / 6000, height: 1600.0 / 4000)
        // (label, whether the stage may cache, the recipe for drag step i)
        let cases: [(String, Bool, (Int) -> EditRecipe)] = [
            ("noise reduction only", false, { _ in
                var recipe = Self.unsharpened
                recipe[.noiseLuminance] = 50
                return recipe
            }),
            ("default sharpening, uncached", false, { _ in EditRecipe() }),
            ("dragging Amount (analysis cached)", true, { step in
                var recipe = EditRecipe()
                recipe[.sharpenAmount] = Double(40 + step)
                return recipe
            }),
            ("dragging Radius (separation cached)", true, { step in
                var recipe = EditRecipe()
                recipe[.sharpenRadius] = 1 + 0.05 * Double(step)
                return recipe
            }),
            ("dragging Luminance with default sharpening (analysis cached)", true, { step in
                var recipe = EditRecipe()
                recipe[.noiseLuminance] = Double(20 + step)
                return recipe
            }),
        ]
        for (label, cache, recipe) in cases {
            let stage = DetailStage(device: device, kernels: kernels)
            // Submitted back to back, as a drag does, so the GPU stays clocked up.
            var buffers: [any MTLCommandBuffer] = []
            for step in 0 ..< 24 {
                let commands = try #require(queue.makeCommandBuffer())
                _ = try stage.process(
                    recipe(step), session: session, region: region, outputSize: view, commands: commands, cache: cache,
                )
                commands.commit()
                buffers.append(commands)
            }
            buffers.last?.waitUntilCompleted()
            let times = buffers.map { ($0.gpuEndTime - $0.gpuStartTime) * 1000 }
            let sorted = times.dropFirst(8).sorted()
            print(String(format: "detail stage GPU, %@: median %.2f ms", label, sorted[sorted.count / 2]))
        }
    }
}
