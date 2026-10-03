import AppKit
import Foundation
import RedlampDesign
import RedlampEngineAPI
import Testing
@testable import RedlampUI

/// The Masking panel keeps its rows while masks change, and its column stays measured.
@MainActor
struct MaskingPanelViewTests {
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
        return (model, { try? FileManager.default.removeItem(at: folder) })
    }

    private func window(_ content: NSView, height: CGFloat) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: height), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentView = content
        return window
    }

    /// Lets the panel's tracker catch up.
    private func settle() async throws {
        for _ in 0 ..< 10 {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func draw(_ x: Double, in model: EditorModel) async throws {
        model.startDrawing(.radial)
        model.beginDrawing(.radial(RadialMask(center: ImagePoint(x: x, y: 0.5), radiusX: 0.1, radiusY: 0.1)))
        model.finishDrawing()
        try await settle()
    }

    @Test func `the Masking panel keeps its rows as masks are drawn and selected`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let panel = MaskingPanelView(model: model)
        let window = window(panel, height: 900)
        defer { window.contentView = nil }
        try await settle()
        let header = try #require(panel.arrangedViews.first)

        try await draw(0.3, in: model)
        let first = try #require(model.selectedMaskID)
        let rows = panel.arrangedViews
        #expect(rows.first === header, "the header bar outlives the first mask")
        let firstEditor = try #require(rows.last)

        try await draw(0.7, in: model)
        #expect(panel.arrangedViews.prefix(3).elementsEqual(rows.prefix(3), by: ===), "header, list and actions")
        #expect(panel.arrangedViews.last !== firstEditor, "the new mask gets its own editor")

        model.selectMask(first)
        try await settle()
        #expect(panel.arrangedViews.prefix(3).elementsEqual(rows.prefix(3), by: ===))
        #expect(panel.arrangedViews.count == rows.count)
        #expect(panel.arrangedViews.last === firstEditor, "going back to a mask reuses its editor")

        let second = try #require(model.maskOutlines.last?.id)
        model.selectMask(second)
        try await settle()
        let secondEditor = try #require(panel.arrangedViews.last)
        model.toggleMaskVisibility(second)
        try await settle()
        #expect(panel.arrangedViews.last === secondEditor, "hiding the mask keeps its editor")
        model.toggleMaskVisibility(second)
        try await settle()
        #expect(panel.arrangedViews.last === secondEditor, "showing it again keeps its editor")

        model.renameMask(second, to: "Renamed")
        try await settle()
        let renamedEditor = try #require(panel.arrangedViews.last)
        #expect(renamedEditor !== secondEditor, "renaming the mask rebuilds its editor")

        let component = try #require(model.selectedOutline?.components.first?.id)
        model.setComponentInverted(component, in: second, true)
        try await settle()
        let invertedEditor = try #require(panel.arrangedViews.last)
        #expect(invertedEditor !== renamedEditor, "inverting a component rebuilds the editor")

        model.deleteMask(second)
        try await settle()
        model.undo()
        try await settle()
        model.selectMask(second)
        try await settle()
        #expect(panel.arrangedViews.last !== invertedEditor, "a deleted mask's editor is rebuilt after undo")

        model.selectMask(nil)
        try await settle()
        model.selectMask(first)
        try await settle()
        #expect(panel.arrangedViews.prefix(3).elementsEqual(rows.prefix(3), by: ===))
        #expect(panel.arrangedViews.last === firstEditor, "reselecting a mask reuses its editor")
    }

    @Test func `the Masking panel's column is re-measured when a mask comes back`() async throws {
        let (model, cleanup) = try await openEditor()
        defer { cleanup() }
        let scroll = PanelColumnScrollView(views: [MaskingPanelView(model: model)])
        let window = window(scroll, height: 600)
        defer { window.contentView = nil }
        func measured() -> Bool {
            let document = scroll.document
            return document.frame.height == document.height(forWidth: document.frame.width)
        }
        try await draw(0.3, in: model)
        let kept = try #require(model.selectedMaskID)
        try await draw(0.7, in: model)
        let other = try #require(model.selectedMaskID)
        model.selectMask(kept)
        try await settle()
        #expect(measured())

        model.deleteMask(other)
        try await settle()
        #expect(model.selectedMaskID == kept)
        #expect(measured(), "the list is a row shorter")
        let shorter = scroll.document.frame.height
        model.undo()
        try await settle()
        #expect(model.maskOutlines.count == 2)
        #expect(measured(), "the list is a row longer again")
        #expect(scroll.document.frame.height > shorter)
    }
}
