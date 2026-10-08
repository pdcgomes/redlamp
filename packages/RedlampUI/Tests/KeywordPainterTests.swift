import AppKit
import Foundation
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// The painter (LIB-21): a stroke in the grid puts the keywords typed in its field, or the active keyword set's, on
/// every photo it reaches as one change with Undo, ⌥ taking them off, the selection staying; Esc, its key and its
/// buttons in the toolbar and the Keywording panel take it out and put it away.
@MainActor
@Suite(.serialized)
struct KeywordPainterTests {
    private func open(_ photos: [String]) async throws -> DragSandbox {
        let sandbox = DragSandbox()
        try await sandbox.open(photos: photos)
        try await sandbox.eventually { sandbox.model.libraryPanels.keywordList != nil }
        return sandbox
    }

    @Test func `a stroke puts the keyword set's keywords on each photo it reaches as one change, the selection staying, with Undo and Redo`(
    ) async throws {
        let sandbox = try await open(["A.JPG", "B.JPG", "C.JPG", "D.JPG"])
        defer { sandbox.close() }
        let model = try #require(sandbox.model)
        let panels = model.libraryPanels
        panels.chooseKeywordSet("Wedding Photography")
        try await sandbox.panelsWritten()
        let wedding = try #require(panels.keywordSets.first { $0.name == "Wedding Photography" })
        #expect(panels.activeSet == wedding)
        let set = wedding.keywords.compactMap(\.self).map(\.text).sorted()
        try sandbox.click("A.JPG")
        let changes = panels.undoCount

        #expect(model.canPerform(.keywordPainter) && model.perform(.keywordPainter))
        #expect(model.keywordPainter.isOn)
        try sandbox.press("B.JPG")
        try sandbox.drag(from: sandbox.cell("B.JPG"), to: sandbox.cell("C.JPG"), release: false)
        let outlined = Set(sandbox.grid.cells.values.filter(\.isDropTarget).compactMap { $0.item?.name })
        #expect(outlined == ["B.JPG", "C.JPG"], "the photos painted are outlined as the stroke goes")
        try sandbox.release(at: sandbox.cell("C.JPG"))
        #expect(sandbox.grid.cells.values.allSatisfy { !$0.isDropTarget })
        try await sandbox.eventually { panels.undoCount > changes }
        try await sandbox.panelsWritten()
        #expect(panels.undoCount == changes + 1, "one change for the stroke")
        #expect(sandbox.keywords("B.JPG") == set && sandbox.keywords("C.JPG") == set)
        #expect(sandbox.keywords("A.JPG").isEmpty && sandbox.keywords("D.JPG").isEmpty)
        #expect(model.selectedPhotos.map(\.lastPathComponent) == ["A.JPG"], "painting leaves the selection")

        #expect(model.perform(.undo))
        try await sandbox.panelsWritten()
        #expect(sandbox.keywords("B.JPG").isEmpty && sandbox.keywords("C.JPG").isEmpty)
        #expect(model.perform(.redo))
        try await sandbox.panelsWritten()
        #expect(sandbox.keywords("B.JPG") == set && sandbox.keywords("C.JPG") == set)
    }

    @Test func `the keywords typed in its field are painted, and with ⌥ a click takes them off`() async throws {
        let sandbox = try await open(["A.JPG", "B.JPG", "C.JPG"])
        defer { sandbox.close() }
        let model = try #require(sandbox.model)
        let panels = model.libraryPanels
        let painter = model.keywordPainter
        #expect(painter.setOn(true))
        painter.text = "Lisbon, Trips > 2026"
        #expect(painter.keywords.map(\.text) == ["Lisbon", "Trips/2026"])
        try sandbox.press("A.JPG")
        try sandbox.drag(from: sandbox.cell("A.JPG"), to: sandbox.cell("B.JPG"))
        try await sandbox.eventually { sandbox.keywords("B.JPG").count == 2 }
        try await sandbox.panelsWritten()
        #expect(sandbox.keywords("A.JPG") == ["Lisbon", "Trips/2026"] && sandbox.keywords("B.JPG") == [
            "Lisbon",
            "Trips/2026",
        ])

        let changes = panels.undoCount
        try sandbox.click("A.JPG", modifiers: .option)
        try await sandbox.eventually { panels.undoCount > changes }
        try await sandbox.panelsWritten()
        #expect(sandbox.keywords("A.JPG").isEmpty, "⌥-click takes them off")
        #expect(sandbox.keywords("B.JPG") == ["Lisbon", "Trips/2026"])
        #expect(model.perform(.undo))
        try await sandbox.panelsWritten()
        #expect(sandbox.keywords("A.JPG") == ["Lisbon", "Trips/2026"])

        painter.text = ""
        panels.chooseKeywordSet(KeywordSet.recentName)
        try await sandbox.panelsWritten()
        if painter.keywords.isEmpty {
            let before = panels.undoCount
            try sandbox.click("C.JPG")
            try await Task.sleep(for: .milliseconds(100))
            await panels.written()
            #expect(panels.undoCount == before && sandbox.keywords("C.JPG").isEmpty, "nothing to paint paints nothing")
        }
    }

    @Test func `Esc, its key and its buttons in the toolbar and the Keywording panel take it out and put it away`(
    ) async throws {
        let sandbox = try await open(["A.JPG", "B.JPG"])
        defer { sandbox.close() }
        let model = try #require(sandbox.model)
        let painter = model.keywordPainter
        #expect(model.perform(.keywordPainter) && painter.isOn)
        #expect(model.canPerform(.cancel) && model.perform(.cancel))
        #expect(!painter.isOn, "Esc puts it away")

        let toolbar = try #require(sandbox.view("library.toolbar.painter") as? ToolbarButton)
        try toolbar.mouseDown(with: sandbox.mouse(.leftMouseDown, at: sandbox.middle(of: "library.toolbar.painter")))
        #expect(painter.isOn, "the toolbar's button takes it out")
        try await sandbox.eventually { sandbox.view("library.toolbar.paints") != nil }
        #expect(sandbox.view("library.toolbar.paints") != nil, "with its field")
        try toolbar.mouseDown(with: sandbox.mouse(.leftMouseDown, at: sandbox.middle(of: "library.toolbar.painter")))
        #expect(!painter.isOn)

        let keywording = try #require(sandbox.view("keywording.painter") as? NSButton)
        keywording.performClick(nil)
        #expect(painter.isOn, "Keywording's button takes it out")
        try await sandbox.eventually { keywording.state == .on }
        #expect(keywording.state == .on)
        #expect(model.perform(.keywordPainter) && !painter.isOn, "⌥⌘K puts it away")

        model.showModule(.develop)
        #expect(!model.canPerform(.keywordPainter), "only in Library")
        model.showModule(.library)
    }
}
