import Foundation
import Metal
import RedlampEngine
import RedlampEngineAPI
import RedlampRecipes
import simd
import Testing

struct FingerprintTests {
    private func image(_ color: (Int, Int) -> SIMD3<Float>) -> PixelImage {
        let w = 96, h = 64
        var pixels: [SIMD3<Float>] = []
        for y in 0 ..< h {
            for x in 0 ..< w {
                pixels.append(color(x, y))
            }
        }
        return PixelImage(width: w, height: h, pixels: pixels)
    }

    @Test func `identical images have no distance, and style differences show`() throws {
        let neutral = StyleFingerprint(image { x, y in SIMD3(repeating: Float(x + y) / 160) })
        #expect(neutral.distance(to: neutral) == 0)
        #expect(neutral.isMonochrome)
        let warm = StyleFingerprint(image { x, y in
            let v = Float(x + y) / 160
            return SIMD3(min(v * 1.08, 1), v, v * 0.88)
        })
        #expect(!warm.isMonochrome || warm.highlightTint[1] > 0)
        #expect(warm.distance(to: neutral) > 0.5)
        #expect(warm.highlightTint[1] > neutral.highlightTint[1])
        let average = try StyleFingerprint.average([neutral, neutral])
        #expect(average.distance(to: neutral) < 1e-9)
    }
}

struct RunStoreTests {
    @Test func `runs round trip candidates and append verdicts`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunStore.named("test-run", root: root)
        try store.prepare()
        let brief = RecipeRun.Brief(
            id: "b1", title: "Warm faded film", description: "Lifted blacks, amber highlights",
            requirements: ["skin stays natural"],
            references: ["ref.jpg"], targetFingerprint: nil, status: .proposed, createdBy: "curator",
        )
        try store.save(brief)
        let recipe = Recipe(
            id: "local/test-run/c1",
            name: "C1",
            group: "Runs",
            includes: [.tone],
            settings: RecipeSettings(values: [.contrast: 10]),
        )
        try store.save(recipe, as: RecipeRun.Candidate(id: "c1", brief: "b1", iteration: 1, origin: "fit"))
        try store.append(RecipeRun.Verdict.brief("b1", approved: true, rater: "human"))
        try store.append(RecipeRun.Verdict.pairwise("c1", "c2", winner: "c1", brief: "b1", rater: "human"))
        #expect(store.briefs() == [brief])
        #expect(store.briefStatus(brief) == .approved)
        #expect(store.candidates().map(\.id) == ["c1"])
        #expect(store.recipe(for: "c1") == recipe)
        #expect(store.verdicts().count == 2)
        #expect(RunStore.all(root: root).map(\.id) == ["test-run"])
    }
}

/// Renders through the real engine: lint, fitting and golden renders.
struct RenderedRecipeTests {
    static let canRender = MTLCreateSystemDefaultDevice() != nil

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func renderer() throws -> RecipeRenderer {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try RecipeRenderer(engine: RedlampEngine(), library: RecipeLibrary(root: root))
    }

    @Test(.enabled(if: canRender))
    func `no bundled recipe fails lint`() async throws {
        let tools = try renderer()
        for recipe in BuiltInRecipes.all {
            let results = try await tools.lint(recipe)
            let failures = results.filter { $0.status == .fail }
            #expect(failures.isEmpty, "\(recipe.id): \(failures.map(\.detail))")
        }
    }

    @Test(.enabled(if: canRender))
    func `a posterizing table fails lint`() async throws {
        let table = try LookTable(size: 17) { c in (c * 3).rounded(.toNearestOrAwayFromZero) / 3 }
        let recipe = LookTableImport.recipe(for: table, name: "Posterize")
        let results = try await renderer().lint(recipe)
        #expect(results.first { $0.check == .banding }?.status == .fail)
        #expect(RecipeLint.overall(results) == .fail)
    }

    @Test(.enabled(if: canRender))
    func `the fitter is reproducible and gets closer`() async throws {
        let tools = try renderer()
        let chart = try RecipeChart.fileURL()
        let target = try await StyleFitter(renderer: tools, images: [chart])
            .fingerprint(of: BuiltInRecipes.recipe(id: "redlamp/essentials/moody"))
        let first = try await StyleFitter(renderer: tools, images: [chart]).fit(
            to: target,
            name: "A",
            evaluations: 30,
            seed: 7,
            id: "local/fit",
        )
        let second = try await StyleFitter(renderer: tools, images: [chart]).fit(
            to: target,
            name: "A",
            evaluations: 30,
            seed: 7,
            id: "local/fit",
        )
        #expect(first.distance < first.startDistance)
        #expect(first.recipe.settings == second.recipe.settings)
    }

    /// Every bundled recipe matches its golden render (tests/golden/recipes), recorded once
    /// with `redlamp recipe golden --record` and never regenerated.
    @Test(.enabled(if: canRender))
    func `bundled recipes match their golden renders`() async throws {
        let tools = try renderer()
        let folder = GoldenRender.directory(root: Self.repositoryRoot, processVersion: EditRecipe.currentProcessVersion)
        for recipe in BuiltInRecipes.all {
            let url = folder.appendingPathComponent(GoldenRender.fileName(for: recipe))
            let golden = try #require(
                try? LookTableImport.readImage(url),
                "no golden render for \(recipe.id); record it",
            )
            let rendered = try await GoldenRender.render(recipe, with: tools)
            let comparison = try #require(GoldenRender.compare(golden, rendered))
            #expect(comparison.passes, "\(recipe.id): mean ΔE \(comparison.meanDeltaE), max \(comparison.maxDeltaE)")
        }
    }

    @Test func `bundled film looks match their designs`() throws {
        for slot in FilmSlot.allCases {
            let shipped = try #require(
                BuiltInBaseLooks.package(slot: slot.rawValue, version: StarterPackLooks.version),
                "\(slot) isn't bundled",
            )
            let designed = try StarterPackLooks.package(for: slot)
            #expect(shipped.version == designed.version)
            // Values rather than hashes: libm may round differently on another OS release.
            let a = try #require(try shipped.definition().table), b = try #require(try designed.definition().table)
            let worst = zip(a.values, b.values).map { abs(Float($0) - Float($1)) }.max() ?? 0
            #expect(worst < 2e-3, "\(slot): the design changed; run `redlamp recipe build-pack` and bump the version")
        }
    }
}
