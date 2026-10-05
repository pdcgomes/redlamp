import Foundation
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// Reordering masks and components, and the overlay's options (MSK-21).
@MainActor
struct MaskManagementTests {
    private func openEditor(_ engine: StubEngine = StubEngine()) async throws -> (EditorModel, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = EditorModel(engine: engine)
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.info != nil)
        model.activeTool = .masking
        return (model, { try? FileManager.default.removeItem(at: folder) })
    }

    private func radialMask(_ model: EditorModel, at x: Double) throws -> UUID {
        model.startDrawing(.radial)
        model.beginDrawing(.radial(RadialMask(center: ImagePoint(x: x, y: 0.5), radiusX: 0.1, radiusY: 0.1)))
        model.finishDrawing()
        return try #require(model.selectedMaskID)
    }

    @Test func `a mask dropped on another takes its place, in one step`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let (a, b, c) = try (radialMask(model, at: 0.2), radialMask(model, at: 0.5), radialMask(model, at: 0.8))
        #expect(model.recipe.masks.map(\.id) == [a, b, c], "the panel lists them c, b, a")
        let steps = model.history.count

        model.moveMask(a, onto: c)
        #expect(model.recipe.masks.map(\.id) == [b, c, a], "a on top of the panel, where c was")
        #expect(model.history.count == steps + 1 && model.history.last?.name == "Reorder Masks")
        model.undo()
        #expect(model.recipe.masks.map(\.id) == [a, b, c])

        model.moveMask(c, onto: a)
        #expect(model.recipe.masks.map(\.id) == [c, a, b], "c at the bottom, where a was")
        model.moveMask(b, onto: b)
        #expect(model.history.count == steps + 1, "dropped on itself: nothing to do")
    }

    @Test func `a component dropped on another takes its place`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let mask = try radialMask(model, at: 0.5)
        model.startDrawing(.linear, operation: .subtract, addingTo: mask)
        model.beginDrawing(.linear(LinearMask(start: ImagePoint(x: 0.5, y: 0.2), end: ImagePoint(x: 0.5, y: 0.4))))
        model.finishDrawing()
        let components = model.recipe.masks[0].components.map(\.id)
        #expect(components.count == 2)

        model.moveComponent(components[1], in: mask, onto: components[0])
        #expect(model.recipe.masks[0].components.map(\.id) == [components[1], components[0]])
        #expect(model.recipe.masks[0].components[0].operation == .subtract, "its operation goes with it")
        #expect(model.history.last?.name == "Reorder Components")
    }

    @Test func `the overlay's opacity and Image on B&W reach the render`() async throws {
        let engine = StubEngine()
        let (model, cleanup) = try await openEditor(engine)
        defer { cleanup() }
        let mask = try radialMask(model, at: 0.5)
        #expect(model.maskOverlayShown == mask)
        #expect(engine.lastRender?.maskOverlayOpacity == MaskOverlayStyle.defaultOpacity)

        model.maskOverlayOpacity = 0.8
        #expect(engine.lastRender?.maskOverlayOpacity == 0.8)
        model.maskOverlayStyle = .imageOnBlackAndWhite
        #expect(engine.lastRender?.maskOverlayStyle == .imageOnBlackAndWhite)
        #expect(MaskOverlayStyle.menu.last == .imageOnBlackAndWhite)
        #expect(!MaskOverlayStyle.imageOnBlackAndWhite.tints && MaskOverlayStyle.colorOverlayOnBlackAndWhite.tints)
    }
}
