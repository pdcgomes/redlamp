import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// Objects masks by rectangle and brush, beside hover and click (MSK-19).
@MainActor
struct ObjectSelectionTests {
    private static let object = AIMask(
        kind: .objects, provider: "stub", revision: 1, analysisHash: "h", center: ImagePoint(x: 0.5, y: 0.5),
        bitmap: MaskBitmap(sha256: "o", width: 4, height: 4),
    )

    private func openEditor() async throws -> (EditorModel, StubEngine, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = StubEngine()
        engine.computed = [Self.object]
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.info != nil)
        model.armObjectSelection()
        return (model, engine, { try? FileManager.default.removeItem(at: folder) })
    }

    @Test func `a dragged box selects what it bounds, and a later box replaces it, the clicks kept`() async throws {
        let (model, engine, cleanup) = try await openEditor()
        defer { cleanup() }
        let box = ImageRect(x: 0.2, y: 0.3, width: 0.4, height: 0.3)
        await model.selectObject(in: box)
        #expect(engine.lastRequest?.box == box && engine.lastRequest?.prompts == [])
        guard case let .ai(mask) = model.recipe.masks.first?.components.first?.shape else {
            Issue.record("no Objects mask")
            return
        }
        #expect(mask.box == box)
        #expect(MaskRequest(updating: mask).box == box, "Update AI Masks asks with the box again")

        let click = ImagePoint(x: 0.4, y: 0.45)
        await model.selectObject(at: click)
        #expect(engine.lastRequest?.box == box && engine.lastRequest?.prompts == [click])
        let tighter = ImageRect(x: 0.25, y: 0.3, width: 0.3, height: 0.3)
        await model.selectObject(in: tighter)
        #expect(engine.lastRequest?.box == tighter && engine.lastRequest?.prompts == [click])
        #expect(model.history.last?.name == "Box Around Object")
        #expect(model.recipe.masks.count == 1 && model.recipe.masks[0].components.count == 1)
    }

    @Test func `a stroke selects with points spread along it, and with Option leaves them out`() async throws {
        let (model, engine, cleanup) = try await openEditor()
        defer { cleanup() }
        model.objectSelection = .brush
        let stroke = (0 ... 40).map { ImagePoint(x: 0.2 + Double($0) * 0.01, y: 0.5) }
        await model.selectObject(along: stroke)
        let prompts = try #require(engine.lastRequest?.prompts)
        #expect(prompts.count == 8)
        #expect(abs(prompts[0].x - 0.225) < 1e-9 && abs(prompts[7].x - 0.575) < 1e-9)
        #expect(model.recipe.masks.count == 1)

        await model.selectObject(along: [ImagePoint(x: 0.3, y: 0.5), ImagePoint(x: 0.3, y: 0.6)], excluding: true)
        #expect(engine.lastRequest?.excluded.count == 2 && engine.lastRequest?.prompts.count == 8)
        #expect(model.history.last?.name == "Remove from Object")
    }

    @Test func `points along a stroke are spread by its length`() {
        let corner = [ImagePoint(x: 0, y: 0), ImagePoint(x: 0.3, y: 0), ImagePoint(x: 0.3, y: 0.1)]
        let points = EditorModel.prompts(along: corner, count: 8)
        #expect(points.count == 3, "no more points than the stroke has")
        let expected = [ImagePoint(x: 0.4 / 6, y: 0), ImagePoint(x: 0.2, y: 0), ImagePoint(x: 0.3, y: 0.1 / 3)]
        for (point, want) in zip(points, expected) {
            #expect(abs(point.x - want.x) < 1e-9 && abs(point.y - want.y) < 1e-9, "\(point) for \(want)")
        }
        #expect(EditorModel.prompts(along: [ImagePoint(x: 0.5, y: 0.5)]) == [ImagePoint(x: 0.5, y: 0.5)])
        #expect(EditorModel.prompts(along: []).isEmpty)
    }
}
