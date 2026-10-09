import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// A large folder shown from the library (LIB-10): its photos' IDs in Folders' order, with the rows of its first photos
/// and of those its view comes back to, the others read as its cells ask for them, as a large source's are
/// (`LibraryFolderList.Large`). The folder is made large with a low threshold (`FolderLibrary.largestRead`).
@MainActor
@Suite(.serialized)
struct LargeFolderTests {
    /// The sandbox's photos in Folders' order: the root's own by name in Finder's order, then each subfolder's, the
    /// subfolders in Finder's order.
    static let photos = ["A.JPG", "IMG_2.JPG", "IMG_10.JPG", "Day 1/X.JPG", "Day 2/Z.JPG", "Day 10/Y.JPG"]

    /// The sandbox's root, with its subfolders, shown from the library as a large folder whose first change brings the
    /// rows of its first two photos.
    private func open(_ sandbox: SourcesSandbox) async throws -> EditorModel {
        try sandbox.photos(Self.photos)
        let model = try await sandbox.open()
        model.library.largestRead = 4
        model.library.firstRead = 2
        model.showFolder(sandbox.root)
        try await sandbox.eventually { model.library.isShownFromLibrary && model.items.count == Self.photos.count }
        try #require(model.items.count == Self.photos.count && model.items.readsOnRequest, "shown as a large folder")
        return model
    }

    /// The paths below the root of the photos shown, in order, once every row is read.
    private func shown(_ model: EditorModel, _ sandbox: SourcesSandbox) async -> [String] {
        await model.library.read(model.library.photoIDs)
        let root = sandbox.root.path + "/"
        return (0 ..< model.items.count).compactMap { model.items.row($0)?.url.path }
            .map { $0.hasPrefix(root) ? String($0.dropFirst(root.count)) : $0 }
    }

    @Test func `a large folder shows its photos by the index's IDs in Folders' order, their rows read as asked for`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let model = try await open(sandbox)
        let library = model.library
        #expect(library.showsIndexIDs)
        #expect(library.items.row(0) != nil && library.items.row(1) != nil, "the first photos' rows came with the list")
        #expect(library.items.rowsRead.count < Self.photos.count, "and not every photo's")
        #expect(model.selection != nil && model.selection == library.items.row(0)?.url, "the first photo active")
        #expect(await shown(model, sandbox) == Self.photos)
        let urls = Self.photos.map { sandbox.photo($0) }
        let found = try await LibraryService.indexIDs(of: urls, in: #require(sandbox.service?.core?.index))
        #expect(Array(library.photoIDs) == urls.map { found[$0] ?? -1 }, "each photo's ID is the index's")
    }

    @Test func `a folder lists its photos in the same order whether it's large or not`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let model = try await open(sandbox)
        let large = await shown(model, sandbox)
        model.library.largestRead = .max
        model.showFolder(sandbox.folder("Day 1"))
        try await sandbox.eventually { model.folder == sandbox.folder("Day 1") && model.items.count == 1 }
        model.showFolder(sandbox.root)
        try await sandbox.eventually {
            model.library.isShownFromLibrary && model.items.count == Self.photos.count && !model.items.readsOnRequest
        }
        #expect(!model.items.readsOnRequest, "every row read")
        #expect(await shown(model, sandbox) == large)
    }

    @Test func `a photo added in a new subfolder of a large folder takes its folder's place`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let model = try await open(sandbox)
        try sandbox.photos(["Day 3/W.JPG"], from: Self.photos.count)
        // Read again as change tracking reads a folder whose files changed.
        let core = try #require(sandbox.service?.core)
        for await event in core.indexer.update([FolderChange(sandbox.root, recursive: true)]) {
            core.live.receive(.indexer(event))
        }
        try await sandbox.eventually { model.items.count == Self.photos.count + 1 }
        #expect(model.items.readsOnRequest)
        #expect(await shown(model, sandbox) == [
            "A.JPG", "IMG_2.JPG", "IMG_10.JPG", "Day 1/X.JPG", "Day 2/Z.JPG", "Day 3/W.JPG", "Day 10/Y.JPG",
        ])
    }

    @Test func `a large folder filtered shows the photos its filter finds, in Folders' order`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let model = try await open(sandbox)
        let filters = try #require(model.libraryFilters)
        filters.setText("IMG_")
        try await sandbox.eventually { model.items.count == 2 }
        #expect(model.items.readsOnRequest && model.library.isFiltered)
        #expect(await shown(model, sandbox) == ["IMG_2.JPG", "IMG_10.JPG"])
        filters.setText("")
        try await sandbox.eventually { model.items.count == Self.photos.count }
        #expect(await shown(model, sandbox) == Self.photos)
    }

    @Test func `the photo last shown in a large folder is active again when the folder is shown again`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let model = try await open(sandbox)
        let photo = sandbox.photo("Day 10/Y.JPG")
        await model.library.read(model.library.photoIDs)
        model.select(photo)
        try await sandbox.eventually { model.selection == photo }
        model.showFolder(sandbox.folder("Day 1"))
        try await sandbox.eventually { model.folder == sandbox.folder("Day 1") && model.items.count == 1 }
        model.showFolder(sandbox.root)
        try await sandbox.eventually { model.folder == sandbox.root && model.items.count == Self.photos.count }
        try await sandbox.eventually { model.selection == photo }
        #expect(model.selection == photo, "its row came with the folder's first change")
        #expect(model.items.rowsRead.count < Self.photos.count, "among a few")
    }
}
