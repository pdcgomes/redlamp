import AppKit
import Foundation
import RedlampDesign
import RedlampEngineAPI
import Testing
@_spi(Harness) @testable import RedlampUI

/// Reset Tone Curve resets the point curve as well as the parametric curve (#341).
@MainActor
struct ToneCurveResetTests {
    private static let curve = [
        CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.2), CurvePoint(x: 0.75, y: 0.82), CurvePoint(x: 1, y: 1),
    ]

    /// A photo whose edit has a point curve and Lights raised, and the Tone Curve panel as the
    /// inspector builds it.
    private func openEditor() async throws -> (EditorModel, PanelSectionView, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = EditorModel(engine: StubEngine())
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.info != nil)
        model.setPointCurve(Self.curve)
        model.setValue(.curveLights, 20)
        return (model, ToneCurvePanelView.make(model: model), { try? FileManager.default.removeItem(at: folder) })
    }

    @Test func `Reset Tone Curve in the header's menu resets the point curve too, in one step`() async throws {
        let (model, panel, cleanup) = try await openEditor()
        defer { cleanup() }
        let steps = model.history.count
        let menu = try #require(panel.headerMenu?())
        let reset = try #require(menu.items.firstIndex { $0.title == "Reset Tone Curve" })
        menu.performActionForItem(at: reset)
        #expect(model.pointCurve == EditRecipe.linearPointCurve)
        #expect(!model.isEdited(.curveLights))
        #expect(model.history.count == steps + 1 && model.history.last?.name == "Reset Tone Curve")
        model.undo()
        #expect(model.pointCurve == Self.curve && model.value(.curveLights) == 20)
    }

    @Test func `double-clicking the header resets the point curve too`() async throws {
        let (model, panel, cleanup) = try await openEditor()
        defer { cleanup() }
        let header = try #require(panel.subviews.first { $0.accessibilityIdentifier() == "panel.toneCurve.header" })
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 2, pressure: 1,
        ))
        header.mouseDown(with: click)
        #expect(model.pointCurve == EditRecipe.linearPointCurve)
        #expect(!model.isEdited(.curveLights))
    }

    @Test func `a point curve alone marks the panel edited`() {
        let model = EditorModel(engine: StubEngine())
        #expect(!model.isEdited(.toneCurve))
        model.setPointCurve(Self.curve)
        #expect(model.isEdited(.toneCurve))
        #expect(!model.isEdited(.basic))
    }
}
