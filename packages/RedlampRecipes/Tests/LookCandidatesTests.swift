import CoreGraphics
import Foundation
import ImageIO
import RedlampEngine
import RedlampEngineAPI
import simd
import Testing
import UniformTypeIdentifiers
@testable import RedlampRecipes

/// Candidate looks (TON-37) on a simulated app: a known warm, contrasty filter over the full
/// kit's charts and two photos, rendered through the real engine for the scores.
struct LookCandidatesTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "look-candidates-\(UUID().uuidString)")

    private static func filter(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let warm = simd_clamp(p * SIMD3(1.08, 1.0, 0.86), .zero, .one)
        return warm * warm * (3 - 2 * warm)
    }

    private static func filtered(_ image: PixelImage) -> PixelImage {
        PixelImage(width: image.width, height: image.height, pixels: image.pixels.map(filter))
    }

    /// Shapes on grey: each seed its own arrangement, like different photos.
    private static func photo(seed: UInt64) -> PixelImage {
        var generator = SeededGenerator(seed: seed)
        let w = 960, h = 640
        var pixels = [SIMD3<Float>](repeating: SIMD3(repeating: 0.45), count: w * h)
        for _ in 0 ..< 16 {
            let cx = Int.random(in: 0 ..< w, using: &generator), cy = Int.random(in: 0 ..< h, using: &generator)
            let r = Int.random(in: 40 ..< 150, using: &generator)
            let colour = SIMD3<Float>(
                .random(in: 0.1 ... 0.9, using: &generator), .random(in: 0.1 ... 0.9, using: &generator),
                .random(in: 0.1 ... 0.9, using: &generator),
            )
            for y in max(0, cy - r) ..< min(h, cy + r) {
                for x in max(0, cx - r) ..< min(w, cx + r) {
                    pixels[y * w + x] = colour
                }
            }
        }
        return PixelImage(width: w, height: h, pixels: pixels)
    }

    private func write(_ image: PixelImage, _ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: name)
        let cg = try #require(CaptureChart.cgImage8(image))
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil,
        ))
        CGImageDestinationAddImage(destination, cg, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// The capture: the charts through the filter, and two photos through it with `noise` added.
    private func inputs(noise: Float = 0) throws -> CaptureInputs {
        let charts = (0 ..< CaptureChart.chartCount).map { CaptureChart.pixels(chart: $0) }
        var generator = SeededGenerator(seed: 3)
        let photos = try [UInt64(11), 12].map { seed -> CaptureInputs.PhotoPair in
            let kit = Self.photo(seed: seed)
            var export = Self.filtered(kit)
            if noise > 0 {
                export = PixelImage(width: export.width, height: export.height, pixels: export.pixels.map { p in
                    let n = Float.random(in: -1 ... 1, using: &generator) + Float.random(
                        in: -1 ... 1,
                        using: &generator,
                    )
                    return simd_clamp(p + SIMD3(repeating: n * noise), .zero, .one)
                })
            }
            return try .init(
                export: "IMG_\(seed).png", exportImage: export, kitPhoto: "photo-\(seed)", kitImage: kit,
                kitFile: write(kit, "photo-\(seed).png"), matchedBy: "name", similarity: 1,
            )
        }
        return CaptureInputs(
            charts: charts.enumerated()
                .map { .init(name: "chart-\($0 + 1).png", image: Self.filtered($1), chartHint: $0) },
            originals: .init(charts: Dictionary(uniqueKeysWithValues: charts.enumerated().map { ($0, $1) })),
            photos: photos,
        )
    }

    private func renderer() throws -> RecipeRenderer {
        try RecipeRenderer(engine: RedlampEngine(), library: RecipeLibrary(root: root.appending(path: "library")))
    }

    @Test func `Every candidate is scored on the photos, the measured one matches the import, best first`(
    ) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = try inputs()
        let result = try inputs.read()
        let candidates = try await LookCandidates.make(inputs, result: result, name: "Warm Test", renderer: renderer())

        let kinds = Set(candidates.map(\.kind))
        #expect(kinds.isSuperset(of: [.measured, .smoothed, .chartsAndPhotos]))
        #expect(candidates.map(\.score.total) == candidates.map(\.score.total).sorted(by: >))
        let measured = try #require(candidates.first { $0.kind == .measured })
        #expect(measured.score.chartDeparture == 0)
        let imported = try AppLookRecipe.make(result, name: "Warm Test")
        #expect(measured.recipe.baseLook?.contentHash == imported.baseLook?.contentHash)
        #expect(measured.recipe.settings == imported.settings)
        #expect(candidates.allSatisfy { $0.score.photos == 2 && $0.renders.count == 2 })
        #expect(try #require(candidates.first { $0.kind == .chartsAndPhotos }).score.heldOut)
        let best = try #require(candidates.first)
        #expect(try #require(best.score.photoMean) < 2.5)
    }

    @Test func `Grain the charts can't see is fitted on the photos and scores better`() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = try inputs(noise: 0.02)
        let result = try inputs.read()
        let candidates = try await LookCandidates.make(
            inputs,
            result: result,
            name: "Grainy Test",
            renderer: renderer(),
        )

        let effects = try #require(candidates.first { $0.kind == .filmEffects })
        #expect((effects.recipe.settings.values[.grainAmount] ?? 0) > 0)
        let others = candidates.filter { $0.kind != .filmEffects }
        #expect(others.allSatisfy { effects.score.total > $0.score.total })
        #expect(others.allSatisfy { abs(effects.score.grain ?? 1) < abs($0.score.grain ?? 0) })
    }

    @Test func `Without photos the score is the charts' alone, and the photo candidates are left out`() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var inputs = try inputs()
        inputs.photos = []
        let candidates = try await LookCandidates.make(
            inputs,
            result: inputs.read(),
            name: "Charts Only",
            renderer: nil,
        )
        #expect(Set(candidates.map(\.kind)) == [.measured, .smoothed])
        #expect(candidates.allSatisfy { $0.score.photos == 0 && $0.score.basis == "the charts only" })
        #expect(candidates.first?.kind == .measured)
    }
}
