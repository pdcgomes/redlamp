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
        let row = try #require(list.photoDropRow, "the folder under the drag is outlined")
        #expect((list.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView)?.isDropTarget == true)
        try sandbox.release(at: picked)
        #expect(list.photoDropRow == nil)
        try await sandbox.filesMade(count: 1)

        #expect(sandbox.files(in: "Picked") == ["A.JPG", "A.JPG.redlamp", "C.JPG"])
        #expect(sandbox.files() == ["B.JPG", "D.JPG", "Picked"])
        #expect(sandbox.shownNames() == ["B.JPG", "D.JPG"])
        #expect(model.fileUndoCount == 1, "one batch")

        #expect(model.canPerform(.undo) && model.perform(.undo))
        await model.filesMade()
        #expect(sandbox.files() == ["A.JPG", "A.JPG.redlamp", "B.JPG", "C.JPG", "D.JPG", "Picked"])
        #expect(sandbox.files(in: "Picked").isEmpty)
        #expect(Set(model.selectedPhotos.map(\.lastPathComponent)) == ["A.JPG", "C.JPG"], "they come back selected")

        #expect(model.canPerform(.redo) && model.perform(.redo))
        await model.filesMade()
        #expect(sandbox.files(in: "Picked") == ["A.JPG", "A.JPG.redlamp", "C.JPG"])
        #expect(model.perform(.undo))
        await model.filesMade()
        #expect(sandbox.files(in: "Picked").isEmpty)
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
}
