import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// Photo › Move to Folder… (LIB-26): the photos selected moved with their raw or JPEG pairs, sidecars and other
/// apps' `.xmp`, leaving the folder shown with the photo after them active; Undo bringing them back selected as
/// they were, Redo moving them again, and the index following without reading a photo again.
@MainActor
struct MoveToFolderTests {
    private func files(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    @Test func `the selection moves with its pairs and sidecars, the photo after it becoming active, and Undo brings it back`(
    ) async throws {
        let folder = RenameTests.RenameFolder()
        defer { folder.cleanUp() }
        try await folder.open(folders: ["Picked"])
        try folder.stopChangeTracking()
        let model = try #require(folder.model)
        let picked = folder.root.appending(path: "Picked", directoryHint: .isDirectory)
        model.select(folder.url("IMG_0001.JPG"))
        model.click(folder.url("IMG_0003.JPG"), toggling: true)
        let before = files(in: folder.root)

        #expect(await model.moveSelection(to: picked) == nil)
        await model.filesMade()
        #expect(files(in: picked) == [
            "IMG_0001.DNG",
            "IMG_0001.JPG",
            "IMG_0001.JPG.redlamp",
            "IMG_0001.xmp",
            "IMG_0003.JPG",
        ])
        #expect(files(in: folder.root) == ["IMG_0002.JPG", "IMG_0004.JPG", "Picked"])
        #expect(folder.shownNames() == ["IMG_0002.JPG", "IMG_0004.JPG"])
        #expect(model.selection == folder.url("IMG_0004.JPG") && model.selectedPhotos == [folder.url("IMG_0004.JPG")])
        #expect(folder.diffs.allSatisfy { !$0.reset }, "nothing is listed afresh")
        #expect(model.fileUndoCount == 1)

        #expect(model.canPerform(.undo) && model.perform(.undo))
        await model.filesMade()
        #expect(files(in: folder.root) == before)
        #expect(files(in: picked).isEmpty)
        #expect(folder.shownNames() == RenameTests.RenameFolder.photos.map(\.name))
        #expect(Set(model.selectedPhotos) == [folder.url("IMG_0001.JPG"), folder.url("IMG_0003.JPG")])
        #expect(model.selection == folder.url("IMG_0003.JPG"), "the photos come back selected as they were")

        #expect(model.canPerform(.redo) && model.perform(.redo))
        await model.filesMade()
        #expect(files(in: picked).count == 5 && folder.shownNames() == ["IMG_0002.JPG", "IMG_0004.JPG"])
        #expect(try await folder.indexAgain() == 0, "the index follows without reading a photo again")
        #expect(model.perform(.undo))
        await model.filesMade()
        #expect(files(in: folder.root) == before)
    }

    @Test func `a folder outside the library is refused, and nothing moves`() async throws {
        let folder = RenameTests.RenameFolder()
        defer { folder.cleanUp() }
        try await folder.open()
        let model = try #require(folder.model)
        let outside = folder.base.appending(path: "Elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        #expect(!MoveFolderPanel.isInLibrary(outside, roots: [folder.root]))
        #expect(MoveFolderPanel.isInLibrary(folder.root.appending(path: "Any"), roots: [folder.root]))
        model.select(folder.url("IMG_0002.JPG"))
        let before = files(in: folder.root)
        #expect(await model.moveSelection(to: outside) == "Elsewhere isn't in the library's folders")
        await model.filesMade()
        #expect(files(in: folder.root) == before && files(in: outside).isEmpty)
        #expect(folder.shownNames() == RenameTests.RenameFolder.photos.map(\.name))
        #expect(model.fileUndoCount == 0)
    }
}
