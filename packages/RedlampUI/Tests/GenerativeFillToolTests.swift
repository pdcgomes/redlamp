import AppKit
import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// Generative Remove in the Healing tool (RM-10).
@MainActor
@Suite(.serialized)
struct GenerativeFillToolTests {
    private func openEditor(_ engine: StubEngine) async throws -> (EditorModel, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        engine.generativeAvailability = .ready
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.info != nil)
        model.activeTool = .heal
        await model.loadGenerativeFill()
        model.fillsGeneratively = true
        await model.setSpotMode(.remove)
        return (model, {
            model.fillsGeneratively = false
            try? FileManager.default.removeItem(at: folder)
        })
    }

    private func finishFilling(_ model: EditorModel) async throws {
        for _ in 0 ..< 400 where model.generating != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.generating == nil)
    }

    @Test func `with Fill set to Generative, a Remove spot gets three fills, the first in the edit`() async throws {
        let engine = StubEngine()
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        #expect(model.offersGenerativeFill && model.fillsNewSpotsGeneratively)
        await model.addSpot(at: ImagePoint(x: 0.5, y: 0.5))
        let spot = try #require(model.recipe.spots.first)
        #expect(model.generating?.spot == spot.id)
        try await finishFilling(model)
        let made = try #require(model.generatedFills[spot.id])
        #expect(made.count == EditorModel.fillVariations && engine.generatedFor == Array(repeating: spot.id, count: 3))
        #expect(model.recipe.spots[0].fill == made[0])
        #expect(model.history.map(\.name).suffix(2) == ["Remove", "Generative Fill"])
        let shown = try #require(model.fillVariations(of: model.recipe.spots[0]))
        #expect(shown.index == 0 && shown.count == 3)
    }

    @Test func `the arrows go through the fills, and Content-Aware fills from the photo again`() async throws {
        let (model, cleanup) = try await openEditor(StubEngine())
        defer { cleanup() }
        await model.addSpot(at: ImagePoint(x: 0.5, y: 0.5))
        try await finishFilling(model)
        let id = try #require(model.selectedSpotID)
        let made = try #require(model.generatedFills[id])
        model.showFillVariation(1)
        #expect(model.recipe.spots[0].fill == made[1] && model.history.last?.name == "Generative Fill Variation")
        model.showFillVariation(-1)
        model.showFillVariation(-1)
        #expect(model.recipe.spots[0].fill == made[2], "the first's previous is the last")
        model.useContentAwareFill()
        #expect(model.recipe.spots[0].fill == nil && model.history.last?.name == "Content-Aware Fill")
        #expect(model.fillVariations(of: model.recipe.spots[0]) == nil)

        model.fillGeneratively([id], more: true)
        try await finishFilling(model)
        #expect(model.generatedFills[id]?.count == 6 && model.recipe.spots[0].fill == model.generatedFills[id]?[3])
    }

    @Test func `More keeps the spot's fill and adds three to choose from`() async throws {
        let (model, cleanup) = try await openEditor(StubEngine())
        defer { cleanup() }
        await model.addSpot(at: ImagePoint(x: 0.5, y: 0.5))
        try await finishFilling(model)
        let id = try #require(model.selectedSpotID)
        let kept = model.recipe.spots[0].fill
        model.fillGeneratively([id], more: true)
        try await finishFilling(model)
        #expect(model.recipe.spots[0].fill == kept && model.generatedFills[id]?.count == 6)
        let shown = try #require(model.fillVariations(of: model.recipe.spots[0]))
        #expect(shown.index == 0 && shown.count == 6)
    }

    @Test func `moving a filled spot drops its fill until it's filled again; moving it back keeps it`() async throws {
        let (model, cleanup) = try await openEditor(StubEngine())
        defer { cleanup() }
        await model.addSpot(at: ImagePoint(x: 0.5, y: 0.5))
        try await finishFilling(model)
        let original = model.recipe.spots[0]
        let id = original.id

        model.beginEdit()
        model.updateSpot(id) { $0.center = ImagePoint(x: 0.6, y: 0.5) }
        #expect(model.recipe.spots[0].fill == nil)
        model.updateSpot(id) { $0 = original }
        #expect(model.recipe.spots[0].fill == original.fill, "back where it was made")
        model.endEdit(.retouch, "Move Spot")

        model.beginEdit()
        var moved = original
        moved.center = ImagePoint(x: 0.6, y: 0.5)
        model.updateSpot(id) { [moved] in $0 = moved }
        model.endEdit(.retouch, "Move Spot")
        #expect(model.recipe.spots[0].fill == nil)
        model.refillGeneratively(id)
        try await finishFilling(model)
        #expect(model.recipe.spots[0].fill != nil && model.recipe.spots[0].center == moved.center)
        #expect(model.generatedFills[id]?.count == 3, "the fills made where it was are gone")
    }

    @Test func `Cancel stops filling, and closing the tool lets the model go`() async throws {
        let engine = StubEngine()
        engine.generationTime = .seconds(30)
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        await model.addSpot(at: ImagePoint(x: 0.5, y: 0.5))
        #expect(model.generating != nil)
        model.cancelGenerativeFill()
        #expect(model.generating == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.recipe.spots[0].fill == nil && model.history.last?.name == "Remove")

        await model.addSpot(at: ImagePoint(x: 0.2, y: 0.5))
        #expect(model.generating != nil)
        model.activeTool = .edit
        #expect(model.generating == nil)
        for _ in 0 ..< 200 where engine.generativeReleases == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(engine.generativeReleases == 1)
    }

    @Test func `with Fill set to Content-Aware, or no model, nothing is generated`() async throws {
        let engine = StubEngine()
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        model.fillsGeneratively = false
        await model.addSpot(at: ImagePoint(x: 0.5, y: 0.5))
        #expect(model.generating == nil && engine.generatedFor.isEmpty)

        model.fillsGeneratively = true
        engine.generativeAvailability = .needsModel(ModelInfo(
            id: "flux2-klein-4b-fill", name: "FLUX.2 [klein] 4B", purpose: "Generative fill",
            downloadBytes: 2_410_000_000, state: .notDownloaded,
        ))
        await model.loadGenerativeFill()
        #expect(model.offersGenerativeFill && !model.fillsNewSpotsGeneratively)
        await model.addSpot(at: ImagePoint(x: 0.3, y: 0.5))
        #expect(model.generating == nil && engine.generatedFor.isEmpty)

        engine.generativeAvailability = .unavailable("This build has no generative model.")
        await model.loadGenerativeFill()
        #expect(!model.offersGenerativeFill)
    }

    @Test func `Remove All fills each spot once, one after another`() async throws {
        let engine = StubEngine()
        engine.things = ["car", "sign"]
        engine.found = [
            FoundThing(thing: "car", score: 0.6, box: ImageRect(x: 0.1, y: 0.5, width: 0.3, height: 0.2)),
            FoundThing(thing: "sign", score: 0.4, box: ImageRect(x: 0.7, y: 0.2, width: 0.1, height: 0.1)),
        ]
        engine.computed = try [Self.mask()]
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        await model.findThings()
        await model.removeAllFound()
        try await finishFilling(model)
        #expect(model.recipe.spots.count == 2 && model.recipe.spots.allSatisfy { $0.fill != nil })
        #expect(engine.generatedFor == model.recipe.spots.map(\.id))
    }

    /// A mask over the left half of the photo.
    private static func mask() throws -> AIMask {
        let (width, height) = (8, 4)
        let pixels = (0 ..< width * height).map { index -> UInt8 in index % width < width / 2 ? 255 : 0 }
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 1,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: width, bitsPerPixel: 8,
        ))
        rep.bitmapData?.update(from: pixels, count: pixels.count)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        return AIMask(
            kind: .objects, provider: "stub", revision: 1, analysisHash: "h", center: ImagePoint(x: 0.25, y: 0.5),
            bitmap: MaskBitmap(png: png, width: width, height: height),
        )
    }
}
