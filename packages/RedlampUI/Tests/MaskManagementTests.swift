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

    @Test func `the Color swatch tints the selected mask, as one step`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let mask = try radialMask(model, at: 0.5)
        let scoped = ParameterID.swatchParameters.allSatisfy(\.isMaskScoped)
        #expect(scoped)
        model.beginEdit()
        model.setSliderValue(.localColorHue, 220)
        model.setSliderValue(.localColorSaturation, 40)
        model.endEdit(.mask(nil), "Radial 1 Color")
        #expect(model.recipe.mask(mask)?[.localColorHue] == 220 && model.recipe
            .mask(mask)?[.localColorSaturation] == 40)
        #expect(model.sliderValue(.localColorSaturation) == 40 && model.history.last?.name == "Radial 1 Color")
    }

    @Test func `a mask's Curves are set channel by channel, and reset together`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let mask = try radialMask(model, at: 0.5)
        let name = try #require(model.recipe.mask(mask)?.name)
        let lifted = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.65), CurvePoint(x: 1, y: 1)]
        model.setMaskCurve(.green, lifted)
        #expect(model.recipe.mask(mask)?.curves?.green == lifted && model.maskCurve(.green) == lifted)
        #expect(model.maskCurve(.rgb) == EditRecipe.linearPointCurve && model.history.last?.name == "\(name) Curve")
        model.setMaskCurve(.green, EditRecipe.linearPointCurve)
        #expect(model.recipe.mask(mask)?.curves == nil, "straight again: no Curves")

        model.setMaskCurve(.rgb, lifted)
        model.setMaskCurve(.blue, lifted)
        model.resetMaskCurves()
        #expect(model.recipe.mask(mask)?.curves == nil && model.history.last?.name == "Reset \(name) Curves")
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
