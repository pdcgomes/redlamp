import Foundation
import RedlampEngine
import RedlampEngineAPI
import Testing

/// Renders every downloaded fixture (tests/fixtures/raw, fetched from raw.pixls.us).
struct EngineSmokeTests {
    static let fixtures: [URL] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/fixtures/raw")
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.filter(SupportedFormats.isSupported).sorted { $0.path < $1.path }
    }()

    @Test(.enabled(if: !fixtures.isEmpty), arguments: fixtures)
    func `opens and renders`(url: URL) async throws {
        let engine = try RedlampEngine()
        let info = try await engine.open(url)
        #expect(info.pixelSize.width > 0)
        #expect(info.isRaw)
        let image = try await engine.renderStill(StillRequest(recipe: EditRecipe(), maxLongEdge: 512))
        #expect(max(image.width, image.height) == 512)
    }

    @Test(.enabled(if: !fixtures.isEmpty))
    func `interactive render delivers frame`() async throws {
        let engine = try RedlampEngine()
        _ = try await engine.open(Self.fixtures[0])
        let frames = engine.frames()
        engine.render(RenderRequest(
            recipe: EditRecipe(),
            targetSize: PixelSize(width: 800, height: 800),
            generation: 7,
        ))
        var iterator = frames.makeAsyncIterator()
        let frame = try #require(await iterator.next())
        #expect(frame.generation == 7)
        #expect(frame.size.longEdge == 800)
        #expect(frame.histogram.totalCount > 0)
    }
}
