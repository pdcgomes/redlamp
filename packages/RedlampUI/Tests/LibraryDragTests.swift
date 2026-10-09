import AppKit
import Foundation
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// Library's drags (LIB-21, LIB-23, LIB-26), through the grid's own mouse and the drop targets' dragging
/// destinations: photos dragged onto a folder move there as one batch with Undo, onto a collection go in it,
/// and a keyword dragged onto photos tags them; drops that can't happen are refused as the drag passes over.
@MainActor
@Suite(.serialized)
struct LibraryDragTests {
    // MARK: - Onto a folder (LIB-26)

    @Test func `photos dragged onto a folder move there as one batch, and Undo and Redo take them back and move them again`(
    ) async throws {
        let sandbox = DragSandbox()
        defer { sandbox.close() }
        try await sandbox.open(photos: ["A.JPG", "B.JPG", "C.JPG", "D.JPG"], folders: ["Picked"])
        let model = try #require(sandbox.model)
        try SidecarStore().save(
            Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 3)), for: sandbox.photo("A.JPG"),
        )
        try sandbox.click("A.JPG")
        try sandbox.click("C.JPG", modifiers: .command)
        #expect(model.selectedPhotos.map(\.lastPathComponent) == ["A.JPG", "C.JPG"])

        let picked = try sandbox.middle(of: "folders." + sandbox.folder("Picked").path)
        try sandbox.press("A.JPG")
        #expect(model.selectedPhotos.count == 2, "a press on a selected photo keeps the selection for its drag")
        try sandbox.drag(from: sandbox.cell("A.JPG"), to: picked, release: false)
        let list = try #require(sandbox.first(FolderOutlineView.self))
        let rootsShown = list.rootsShown
        let row = try #require(list.photoDropRow, "the folder under the drag is outlined")
        #expect((list.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView)?.isDropTarget == true)
        try sandbox.release(at: picked)
        #expect(list.photoDropRow == nil)
        try await sandbox.filesMade(count: 1)

        #expect(sandbox.files(in: "Picked") == ["A.JPG", "A.JPG.redlamp", "C.JPG"])
        #expect(sandbox.files() == ["B.JPG", "D.JPG", "Picked"])
        #expect(sandbox.shownNames() == ["B.JPG", "D.JPG"])
        #expect(model.fileUndoCount == 1, "one batch")
        #expect(list.rootsShown == rootsShown, "Folders keeps its rows as the photos move")

        #expect(model.canPerform(.undo) && model.perform(.undo))
        await model.filesMade()
        #expect(sandbox.files() == ["A.JPG", "A.JPG.redlamp", "B.JPG", "C.JPG", "D.JPG", "Picked"])
        #expect(sandbox.files(in: "Picked").isEmpty)
        #expect(Set(model.selectedPhotos.map(\.lastPathComponent)) == ["A.JPG", "C.JPG"], "they come back selected")

        let stepIDs = model.fileSteps.redo.last?.photos.map(\.id) ?? []
        #expect(model.canPerform(.redo) && model.perform(.redo))
        await model.filesMade()
        if sandbox.files(in: "Picked") != ["A.JPG", "A.JPG.redlamp", "C.JPG"], let core = sandbox.service?.core {
            let urls = ["A.JPG", "C.JPG"].map { sandbox.photo($0) }
            let found = await LibraryService.indexIDs(of: urls, in: core.index)
            Issue.record("""
            Redo left Picked with \(sandbox.files(in: "Picked")); the step's photos \(stepIDs), the index's now \
            \(urls.map { found[$0] }); errors \(model.activity.events.filter { $0.kind == .error }.map(\.text))
            """)
        }
        #expect(model.perform(.undo))
        await model.filesMade()
        #expect(sandbox.files(in: "Picked").isEmpty)
    }

    @Test func `⌘Z takes a drop's move back the moment its batch is done, in the turn the actions come back`(
    ) async throws {
        let sandbox = DragSandbox()
        defer { sandbox.close() }
        try await sandbox.open(photos: ["A.JPG", "B.JPG"], folders: ["Picked"])
        let model = try #require(sandbox.model)
        try sandbox.click("A.JPG")
        try sandbox.press("A.JPG")
        try sandbox.drag(
            from: sandbox.cell("A.JPG"),
            to: sandbox.middle(of: "folders." + sandbox.folder("Picked").path),
        )
        // Turn by turn on the main actor, as a key could come between any two of them.
        let deadline = ContinuousClock.now + .seconds(15)
        while model.fileSteps.undo.last?.batch == nil, ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(model.fileSteps.undo.last?.batch != nil, "the move's batch is done")
        #expect(model.canPerform(.undo) && model.perform(.undo), "⌘Z is there in the turn the move is done")
        await model.filesMade()
        #expect(sandbox.files() == ["A.JPG", "B.JPG", "Picked"] && sandbox.files(in: "Picked").isEmpty)
    }

    @Test func `⌘Z and ⇧⌘Z while a drop's move runs wait for it, then take it back and make it again`(
    ) async throws {
        let sandbox = DragSandbox()
        defer { sandbox.close() }
        try await sandbox.open(photos: ["A.JPG", "B.JPG"], folders: ["Picked"])
        let model = try #require(sandbox.model)
        let held = Gate()
        held.hold()
        model.fileSteps.enqueue { await held.pass() }
        try sandbox.click("A.JPG")
        try sandbox.press("A.JPG")
        try sandbox.drag(
            from: sandbox.cell("A.JPG"),
            to: sandbox.middle(of: "folders." + sandbox.folder("Picked").path),
        )
        try await sandbox.eventually { model.fileUndoCount == 1 }
        try #require(model.moveProgress.title != nil && model.fileSteps.undo.last?.batch == nil, "the move runs")
        #expect(!model.canPerform(.flagPick) && !model.perform(.flagPick), "other actions stay off")

        #expect(model.canPerform(.undo) && model.perform(.undo))
        #expect(model.canPerform(.redo) && model.perform(.redo))
        #expect(model.canPerform(.undo) && model.perform(.undo))
        #expect(sandbox.files(in: "Picked").isEmpty, "nothing has moved yet")
        held.release()
        await model.filesMade()
        #expect(model.moveProgress.title == nil && !model.isModalDialogOpen)
        #expect(sandbox.files() == ["A.JPG", "B.JPG", "Picked"] && sandbox.files(in: "Picked").isEmpty)
        #expect(sandbox.shownNames() == ["A.JPG", "B.JPG"])
        #expect(model.fileUndoCount == 0 && model.fileRedoCount == 1, "the move, taken back, made again, taken back")
    }

    @Test func `a photo that isn't selected is dragged alone, and a click on a selected photo selects it alone`(
    ) async throws {
        let sandbox = DragSandbox()
        defer { sandbox.close() }
        try await sandbox.open(photos: ["A.JPG", "B.JPG", "C.JPG"], folders: ["Picked"])
        let model = try #require(sandbox.model)
        try sandbox.click("A.JPG")
        try sandbox.click("B.JPG", modifiers: .command)
        try sandbox.click("A.JPG")
        #expect(model.selectedPhotos.map(\.lastPathComponent) == ["A.JPG"], "a click without a drag")

        try sandbox.click("B.JPG", modifiers: .command)
        try sandbox.press("C.JPG")
        try sandbox.drag(
            from: sandbox.cell("C.JPG"),
            to: sandbox.middle(of: "folders." + sandbox.folder("Picked").path),
        )
        try await sandbox.filesMade(count: 1)
        #expect(sandbox.files(in: "Picked") == ["C.JPG"])
        #expect(sandbox.shownNames() == ["A.JPG", "B.JPG"])
    }

    @Test func `drops that can't happen are refused as the drag passes over, and nothing moves`() async throws {
        let sandbox = DragSandbox()
        defer { sandbox.close() }
        try await sandbox.open(photos: ["A.JPG", "B.JPG"], folders: ["Picked"])
        let model = try #require(sandbox.model)
        let list = try #require(sandbox.first(FolderOutlineView.self))
        let before = sandbox.files()

        // Onto the folder they're in.
        try sandbox.press("A.JPG")
        let own = try sandbox.middle(of: "folders." + sandbox.root.path)
        try sandbox.drag(from: sandbox.cell("A.JPG"), to: own, release: false)
        #expect(list.photoDropRow == nil, "the folder the photo is in doesn't take it")
        try sandbox.release(at: own)

        // Onto Recently Trashed.
        try sandbox.press("B.JPG")
        let trash = try sandbox.middle(of: "folders.recently-trashed")
        try sandbox.drag(from: sandbox.cell("B.JPG"), to: trash, release: false)
        #expect(list.photoDropRow == nil, "Recently Trashed doesn't take photos")
        try sandbox.release(at: trash)

        // A folder outside the library, which Folders never lists, and photos from Recently Trashed.
        let outside = sandbox.base.appending(path: "Elsewhere", directoryHint: .isDirectory)
        let dragged = DraggedPhotos(photo: sandbox.photo("A.JPG"), fromLibrary: true)
        #expect(model.photoDrop(dragged, onFolder: outside, isMissing: false, operations: [.move]) == nil)
        #expect(model
            .photoDrop(dragged, onFolder: sandbox.folder("Picked"), isMissing: true, operations: [.move]) == nil)
        let trashed = DraggedPhotos(photo: sandbox.photo("A.JPG"), fromLibrary: false)
        #expect(model
            .photoDrop(trashed, onFolder: sandbox.folder("Picked"), isMissing: false, operations: [.move]) == nil)
        #expect(model.photoDrop(dragged, onFolder: sandbox.folder("Picked"), isMissing: false, operations: [.move])?
            .operation == .move)

        try await Task.sleep(for: .milliseconds(100))
        await model.filesMade()
        #expect(sandbox.files() == before && sandbox.files(in: "Picked").isEmpty)
        #expect(model.fileUndoCount == 0)
    }

    @Test func `with ⌥ held a drop onto a folder says photos aren't copied, and moves nothing`() async throws {
        let sandbox = DragSandbox()
        defer { sandbox.close() }
        try await sandbox.open(photos: ["A.JPG", "B.JPG"], folders: ["Picked"])
        let model = try #require(sandbox.model)
        let list = try #require(sandbox.first(FolderOutlineView.self))
        try sandbox.press("A.JPG")
        let picked = try sandbox.middle(of: "folders." + sandbox.folder("Picked").path)
        try sandbox.drag(from: sandbox.cell("A.JPG"), to: picked, modifiers: .option, release: false)
        #expect(list.photoDropRow != nil)
        try sandbox.release(at: picked, modifiers: .option)
        try await sandbox.eventually { model.activity.events.contains { $0.text == EditorModel.notCopied } }
        #expect(model.activity.events.contains { $0.text == EditorModel.notCopied }, "the drop says so")
        await model.filesMade()
        #expect(sandbox.files(in: "Picked").isEmpty && sandbox.shownNames() == ["A.JPG", "B.JPG"])
        #expect(model.fileUndoCount == 0)
    }

    // MARK: - Onto a collection (LIB-23)

    @Test func `photos dragged onto a collection go in it as one change, with Undo and Redo, and a smart collection or a set refuses them`(
    ) async throws {
        let sandbox = DragSandbox()
        defer { sandbox.close() }
        try await sandbox.open(photos: ["A.JPG", "B.JPG", "C.JPG"])
        let model = try #require(sandbox.model)
        let sources = model.librarySources
        let selects = try #require(CollectionPath("Selects"))
        let picks = try #require(CollectionPath("Picks"))
        let clients = try #require(CollectionPath("Clients"))
        try await sandbox.made { $0.isCounted }
        #expect(sources.create(.collection, named: "Selects"))
        #expect(sources.create(.set, named: "Clients"))
        #expect(sources.saveSmart("flag:pick", named: "Picks", inside: nil))
        try await sandbox.made { $0.collections.count == 3 }
        let rows = [selects, picks, clients].map { SourceRow.identifier(of: .collection($0)) }
        try await sandbox.eventually { rows.allSatisfy { sandbox.view($0) != nil } }
        sandbox.layOut()
        try sandbox.click("A.JPG")
        try sandbox.click("B.JPG", modifiers: .command)
        let list = try #require(sandbox.first(CollectionOutlineView.self))
        let changes = model.libraryPanels.undoCount

        for (refused, row) in zip([picks, clients], rows.dropFirst()) {
            try sandbox.press("A.JPG")
            let location = try sandbox.middle(of: row)
            try sandbox.drag(from: sandbox.cell("A.JPG"), to: location, release: false)
            #expect(list.photoDropRow == nil, "\(refused.text) refuses photos")
            try sandbox.release(at: location)
        }
        try sandbox.press("A.JPG")
        let location = try sandbox.middle(of: rows[0])
        try sandbox.drag(from: sandbox.cell("A.JPG"), to: location, release: false)
        #expect(list.photoDropRow != nil, "a collection takes them")
        try sandbox.release(at: location)
        try await sandbox.eventually { model.libraryPanels.undoCount > changes }
        #expect(model.libraryPanels.undoCount == changes + 1, "one change")
        try await sandbox.made { $0.count(of: .collection(selects)) == 2 }
        #expect(sources.count(of: .collection(selects)) == 2)
        let core = try #require(sandbox.service.core)
        let id = try #require(await LibraryService.indexIDs(of: [sandbox.photo("B.JPG")], in: core.index).values.first)
        #expect(try await core.index.read { try $0.collections(ofPhoto: id) } == [selects], "its sidecar names it")

        #expect(model.perform(.undo))
        try await sandbox.made { $0.count(of: .collection(selects)) == 0 }
        #expect(sources.count(of: .collection(selects)) == 0)
        #expect(model.perform(.redo))
        try await sandbox.made { $0.count(of: .collection(selects)) == 2 }
        #expect(sources.count(of: .collection(selects)) == 2)
        #expect(sources.count(of: .collection(picks)) == 0)
    }

    // MARK: - A keyword onto photos (LIB-21)

    @Test func `a keyword dragged onto a photo tags it alone, or the selection when it's in it, each one change with Undo and Redo`(
    ) async throws {
        let sandbox = DragSandbox()
        defer { sandbox.close() }
        try await sandbox.open(photos: ["A.JPG", "B.JPG", "C.JPG"])
        let model = try #require(sandbox.model)
        let panels = model.libraryPanels
        try await sandbox.eventually { panels.keywordList != nil }
        #expect(panels.create("Lisbon"))
        try await sandbox.panelsWritten()
        try await sandbox.eventually { sandbox.view("keywordList.name.Lisbon") != nil }
        sandbox.layOut()
        let label = try #require(sandbox.view("keywordList.name.Lisbon") as? KeywordDragLabel)
        try sandbox.click("A.JPG")
        try sandbox.click("B.JPG", modifiers: .command)
        try await sandbox.eventually { panels.selection.ids.count == 2 }

        let changes = panels.undoCount
        try sandbox.drag(label, to: sandbox.cell("C.JPG"), release: false)
        let outlined = sandbox.grid.cells.values.filter(\.isDropTarget).compactMap { $0.item?.name }
        #expect(outlined == ["C.JPG"], "the photo under the drag, not selected, alone")
        try label.mouseUp(with: sandbox.mouse(.leftMouseUp, at: sandbox.cell("C.JPG")))
        #expect(sandbox.grid.cells.values.allSatisfy { !$0.isDropTarget })
        try await sandbox.eventually { panels.undoCount > changes }
        try await sandbox.panelsWritten()
        #expect(panels.undoCount == changes + 1, "one change")
        #expect(sandbox.keywords("C.JPG") == ["Lisbon"])
        #expect(sandbox.keywords("A.JPG").isEmpty && sandbox.keywords("B.JPG").isEmpty)
        #expect(model.perform(.undo))
        try await sandbox.panelsWritten()
        #expect(sandbox.keywords("C.JPG").isEmpty)
        #expect(model.perform(.redo))
        try await sandbox.panelsWritten()
        #expect(sandbox.keywords("C.JPG") == ["Lisbon"])

        // The list shows its rows again as the keyword's count changes.
        sandbox.layOut()
        let shown = try #require(sandbox.view("keywordList.name.Lisbon") as? KeywordDragLabel)
        try sandbox.drag(shown, to: sandbox.cell("B.JPG"), release: false)
        let selected = Set(sandbox.grid.cells.values.filter(\.isDropTarget).compactMap { $0.item?.name })
        #expect(selected == ["A.JPG", "B.JPG"], "a selected photo under the drag: the selection")
        try shown.mouseUp(with: sandbox.mouse(.leftMouseUp, at: sandbox.cell("B.JPG")))
        try await sandbox.eventually { panels.undoCount > changes + 1 }
        try await sandbox.panelsWritten()
        #expect(sandbox.keywords("A.JPG") == ["Lisbon"] && sandbox.keywords("B.JPG") == ["Lisbon"])
        #expect(try panels.selection.hasEverywhere(#require(KeywordPath("Lisbon"))) == true)
        #expect(model.perform(.undo))
        try await sandbox.panelsWritten()
        #expect(sandbox.keywords("A.JPG").isEmpty && sandbox.keywords("B.JPG").isEmpty)
        #expect(sandbox.keywords("C.JPG") == ["Lisbon"])
    }

    @Test func `a click on a keyword's name selects its row, and a keyword dropped between cells tags nothing`(
    ) async throws {
        let sandbox = DragSandbox()
        defer { sandbox.close() }
        try await sandbox.open(photos: ["A.JPG", "B.JPG"])
        let panels = sandbox.model.libraryPanels
        try await sandbox.eventually { panels.keywordList != nil }
        #expect(panels.create("Lisbon, Porto"))
        try await sandbox.panelsWritten()
        try await sandbox.eventually { sandbox.view("keywordList.name.Porto") != nil }
        sandbox.layOut()
        let label = try #require(sandbox.view("keywordList.name.Porto") as? KeywordDragLabel)
        let outline = try #require(sandbox.first(KeywordOutlineView.self))
        let frame = label.convert(label.bounds, to: nil)
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        #expect(
            try outline.hitTest(#require(outline.superview?.convert(middle, from: nil))) === label,
            "the name takes the press",
        )
        try label.mouseDown(with: sandbox.mouse(.leftMouseDown, at: middle))
        try label.mouseUp(with: sandbox.mouse(.leftMouseUp, at: middle))
        #expect(outline.selectedRow == outline.row(for: label), "a click on the name selects its row")

        let changes = panels.undoCount
        let first = sandbox.grid.gridLayout.frame(forItem: 0)
        let between = sandbox.grid.content.convert(CGPoint(x: first.minX - 2, y: first.minY - 2), to: nil)
        try sandbox.drag(label, to: between)
        try await Task.sleep(for: .milliseconds(200))
        await panels.written()
        #expect(panels.undoCount == changes && sandbox.keywords("A.JPG").isEmpty && sandbox.keywords("B.JPG").isEmpty)
    }
}
