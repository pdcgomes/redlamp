import AppKit
import Foundation
import RedlampDesign
import RedlampEngineAPI
import Testing
@_spi(Harness) @testable import RedlampUI

/// The Masks panel in AppKit keeps its rows while masks change, puts the pickers and messages
/// where the design has them, keeps its column measured, and ends a row's preview with the row.
@MainActor
struct MasksPanelViewTests {
    /// An editor with a photo open, in a temporary folder its sidecar can be written to.
    private func openEditor() async throws -> (EditorModel, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = EditorModel(engine: StubEngine())
        model.select(folder.appending(path: "IMG_0001.ARW"))
        for _ in 0 ..< 200 where model.info == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.info != nil)
        model.activeTool = .masking
        return (model, { try? FileManager.default.removeItem(at: folder) })
    }

    private func window(_ content: NSView, height: CGFloat) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 316, height: height), styleMask: [.titled],
            backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderFront(nil)
        return window
    }

    /// Lets the panel's tracker, and SwiftUI inside its rows, catch up.
    private func settle(_ window: NSWindow) async throws {
        for _ in 0 ..< 12 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func draw(_ x: Double, in model: EditorModel, window: NSWindow) async throws {
        model.startDrawing(.radial)
        model.beginDrawing(.radial(RadialMask(center: ImagePoint(x: x, y: 0.5), radiusX: 0.1, radiusY: 0.1)))
        model.finishDrawing()
        try await settle(window)
    }

    @Test func `the Masks panel keeps its rows as masks are drawn and selected`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let panel = MasksPanelView(model: model)
        let window = window(panel, height: 900)
        defer { window.orderOut(nil) }
        try await settle(window)
        #expect(panel.arrangedViews.count == 2, "with no masks, the header and the picker")
        let header = try #require(panel.arrangedViews.first)
        let picker = panel.arrangedViews[1]

        try await draw(0.3, in: model, window: window)
        let first = try #require(model.selectedMaskID)
        let rows = panel.arrangedViews
        #expect(rows.count == 4, "the header, the list, the divider and the mask's settings")
        #expect(rows.first === header, "the header outlives the first mask")
        #expect(!rows.contains { $0 === picker }, "the list takes the picker's place")
        let firstEditor = try #require(rows.last)

        try await draw(0.7, in: model, window: window)
        #expect(panel.arrangedViews.prefix(3).elementsEqual(rows.prefix(3), by: ===), "header, list and divider")
        #expect(panel.arrangedViews.last !== firstEditor, "the new mask gets its own settings")

        model.selectMask(first)
        try await settle(window)
        #expect(panel.arrangedViews.last === firstEditor, "going back to a mask reuses its settings")

        let second = try #require(model.maskOutlines.last?.id)
        model.selectMask(second)
        try await settle(window)
        let secondEditor = try #require(panel.arrangedViews.last)
        model.toggleMaskVisibility(second)
        try await settle(window)
        #expect(panel.arrangedViews.last === secondEditor, "hiding the mask keeps its settings")
        model.setMaskInverted(second, true)
        try await settle(window)
        #expect(panel.arrangedViews.last === secondEditor, "inverting the whole mask keeps them")

        model.renameMask(second, to: "Renamed")
        try await settle(window)
        let renamedEditor = try #require(panel.arrangedViews.last)
        #expect(renamedEditor !== secondEditor, "renaming the mask rebuilds its settings")

        let component = try #require(model.selectedOutline?.components.first?.id)
        model.setComponentInverted(component, in: second, true)
        try await settle(window)
        let invertedEditor = try #require(panel.arrangedViews.last)
        #expect(invertedEditor !== renamedEditor, "inverting a component rebuilds them")

        model.deleteMask(second)
        try await settle(window)
        model.undo()
        try await settle(window)
        model.selectMask(second)
        try await settle(window)
        #expect(panel.arrangedViews.last !== invertedEditor, "a deleted mask's settings are rebuilt after undo")

        model.deleteAllMasks()
        try await settle(window)
        #expect(panel.arrangedViews.elementsEqual([header, picker], by: ===), "the picker comes back")
    }

    @Test func `choosing an effect moves the mask's sliders and keeps its settings`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let panel = MasksPanelView(model: model)
        let window = window(panel, height: 900)
        defer { window.orderOut(nil) }
        try await draw(0.5, in: model, window: window)
        let mask = try #require(model.selectedMaskID)
        let settings = try #require(panel.arrangedViews.last)
        let dodge = try #require(MaskEffect.builtIn.first { $0.name == "Dodge" })

        model.applyMaskEffect(dodge, to: mask)
        try await settle(window)
        #expect(model.sliderValue(.localExposure) == 0.35)
        #expect(panel.arrangedViews.last === settings, "an effect changes only the sliders' values")
        model.undo()
        try await settle(window)
        #expect(model.sliderValue(.localExposure) == 0)
        #expect(panel.arrangedViews.last === settings)
    }

    @Test func `the drawing hint, messages and the pickers go where the design has them`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let panel = MasksPanelView(model: model)
        let window = window(panel, height: 900)
        defer { window.orderOut(nil) }
        try await draw(0.4, in: model, window: window)
        let rows = panel.arrangedViews
        let mask = try #require(model.selectedMaskID)

        model.startDrawing(.brush, addingTo: mask)
        try await settle(window)
        #expect(panel.arrangedViews.count == rows.count + 1)
        #expect(panel.arrangedViews.first === rows[0] && panel.arrangedViews[2] === rows[1], "under the header")
        model.cancelDrawing()
        try await settle(window)
        #expect(panel.arrangedViews.count == rows.count)
        #expect(panel.arrangedViews.prefix(3).elementsEqual(rows.prefix(3), by: ===), "the brush's settings go")

        model.maskMessage = "Sky masks need a photo with sky in it."
        try await settle(window)
        #expect(panel.arrangedViews.count == rows.count + 1)
        #expect(panel.arrangedViews[2] === rows[1], "the message is at the top of the list")
        model.maskMessage = nil
        try await settle(window)

        let settings = panel.arrangedViews
        model.openPeoplePicker(.new)
        try await settle(window)
        #expect(panel.arrangedViews.count == 2, "the People picker takes the list's place")
        #expect(panel.arrangedViews.first === rows[0])
        model.closePeoplePicker()
        try await settle(window)
        #expect(panel.arrangedViews.elementsEqual(settings, by: ===), "and gives it back, the mask's settings kept")

        model.openLandscapePicker(.component(.add, target: mask))
        try await settle(window)
        #expect(panel.arrangedViews.count == 2, "the Landscape picker takes the list's place")
        #expect(panel.arrangedViews.first === rows[0])
        model.closeLandscapePicker()
        try await settle(window)
        #expect(panel.arrangedViews.elementsEqual(settings, by: ===), "and gives it back")
    }

    @Test func `the Masks panel's column is re-measured when a mask comes back`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let scroll = PanelColumnScrollView(views: [MasksPanelView(model: model)])
        let window = window(scroll, height: 600)
        defer { window.orderOut(nil) }
        func measured() -> Bool {
            let document = scroll.document
            return document.frame.height == document.height(forWidth: document.frame.width)
        }
        try await draw(0.3, in: model, window: window)
        let kept = try #require(model.selectedMaskID)
        try await draw(0.7, in: model, window: window)
        let other = try #require(model.selectedMaskID)
        model.selectMask(kept)
        try await settle(window)
        #expect(measured())

        model.deleteMask(other)
        try await settle(window)
        #expect(model.selectedMaskID == kept)
        #expect(measured(), "the list is a row shorter")
        let shorter = scroll.document.frame.height
        model.undo()
        try await settle(window)
        #expect(model.maskOutlines.count == 2)
        #expect(measured(), "the list is a row longer again")
        #expect(scroll.document.frame.height > shorter)
    }

    /// #364 in the AppKit panel: a component's row goes with the settings it was in, and its
    /// preview with it. SwiftUI reads hovers from the real pointer, so each hover is set as the
    /// row reports it.
    @Test func `a mask's or a component's preview ends with its row`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let panel = MasksPanelView(model: model)
        let window = window(panel, height: 900)
        defer { window.orderOut(nil) }
        try await draw(0.3, in: model, window: window)
        try await draw(0.7, in: model, window: window)
        let (left, right) = (model.masks[0].id, model.masks[1].id)

        model.hoveredMaskID = left
        model.deleteMask(left)
        try await settle(window)
        #expect(model.hoveredMaskID == nil, "the deleted mask's row went, and its preview with it")
        model.undo()
        try await settle(window)
        #expect(model.maskOverlayShown == right, "back again, the mask isn't under the pointer")

        model.selectMask(right)
        model.startDrawing(.linear, operation: .subtract, addingTo: right)
        model.beginDrawing(.linear(LinearMask(start: ImagePoint(x: 0.7, y: 0.2), end: ImagePoint(x: 0.7, y: 0.4))))
        model.finishDrawing()
        let component = try #require(model.recipe.mask(right)?.components.last?.id)
        try await settle(window)
        model.hoveredComponentID = component
        model.deleteComponent(component, in: right)
        try await settle(window)
        #expect(model.hoveredComponentID == nil, "the deleted component's row went, and its preview with it")
        model.undo()
        try await settle(window)
        #expect(model.componentPreview(in: model.recipe) == nil)
    }
}
