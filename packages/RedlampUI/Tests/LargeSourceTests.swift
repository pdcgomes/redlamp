import AppKit
import Foundation
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// A large source's rows read as its cells appear (LIB-10, LIB-14): All Photographs shown with only its first photos'
/// rows read with its first change and the others as the grid asks for them, and what acts on photos out of sight
/// reading theirs first. The sources are made large with a low threshold (`FolderLibrary.largestRead`).
@MainActor
@Suite(.serialized)
struct LargeSourceTests {
    /// `count` photos in one folder, and All Photographs shown as a large source whose first change brings the rows of
    /// its first two photos, in a grid two columns wide and about two rows tall, with every change to the photos
    /// noted in `diffs`.
    private func open(_ sandbox: SourcesSandbox, count: Int, diffs: DiffLog) async throws
        -> (EditorModel, LibraryGridView, NSWindow) {
        try sandbox.photos((0 ..< count).map { String(format: "Shoot/P%03d.JPG", $0) })
        let model = try await sandbox.open()
        model.library.largestRead = 4
        model.library.firstRead = 2
        diffs.observe(model.library)
        model.showLibrary(.grid)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 300), styleMask: [.borderless], backing: .buffered,
            defer: false,
        )
        let grid = LibraryGridView(model: model)
        grid.frame = window.contentLayoutRect
        window.contentView = grid
        grid.layoutSubtreeIfNeeded()
        #expect(model.librarySources.show(.allPhotographs))
        try await sandbox.eventually(seconds: 20) { !model.librarySources.isListing && model.items.count == count }
        try #require(model.items.count == count, "All Photographs shown")
        try #require(model.items.readsOnRequest, "its rows read as they're asked for")
        return (model, grid, window)
    }

    /// The changes a library published.
    @MainActor
    final class DiffLog {
        private(set) var diffs: [LibraryDiff] = []
        private var observation: LibraryObservation?

        func observe(_ library: FolderLibrary) {
            observation = library.observe { [weak self] in self?.diffs.append($0) }
        }
    }

    @Test func `a large source's rows are read as its cells appear, its first photos' with its first change`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let diffs = DiffLog()
        let (model, grid, window) = try await open(sandbox, count: 40, diffs: diffs)
        defer { window.contentView = nil }
        let library = model.library
        #expect(library.items.row(0) != nil && library.items.row(1) != nil, "the first photos' rows came with the list")
        #expect(model.selection != nil && model.selection == library.items.row(0)?.url, "the first photo active")
        try await sandbox.eventually { !grid.cells.isEmpty && grid.cells.values.allSatisfy { $0.item != nil } }
        #expect(!grid.cells.isEmpty && grid.cells.values.allSatisfy { $0.item != nil }, "every cell shows its photo")
        #expect(diffs.diffs.contains { $0.onlyReads }, "the cells' rows came as rows read")
        #expect(library.items.rowsRead.count < 40, "the rows out of sight aren't read")

        // The last photo, which no cell has asked for, active as End makes it.
        #expect(library.items.row(39) == nil)
        let last = library.photoIDs[39]
        model.selectRow(39)
        try await sandbox.eventually { model.selection.flatMap(library.photoID(of:)) == last }
        let active = try #require(model.selection)
        #expect(library.photoID(of: active) == last && library.index(of: active) == 39)
        #expect(library.items.row(39)?.url == active)
    }

    @Test func `culling a large source's whole selection takes its IDs, its rows unread, and Undo takes it back`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let diffs = DiffLog()
        let (model, grid, window) = try await open(sandbox, count: 40, diffs: diffs)
        defer { window.contentView = nil }
        let library = model.library
        let engine = try #require(sandbox.service?.engine)
        // The grid's cells have their rows, which they read themselves.
        try await sandbox.eventually { !grid.cells.isEmpty && grid.cells.values.allSatisfy { $0.item != nil } }
        func found(_ query: String) async throws -> Int {
            try await engine.list(.allPhotographs, matching: LibraryQuery(parsing: query)).count
        }
        func eventually(_ query: String, _ count: Int) async throws {
            for _ in 0 ..< 400 where try await found(query) != count {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(try await found(query) == count, "\(query)")
        }
        model.selectAllPhotos()
        let read = library.items.rowsRead.count
        #expect(model.selectedCount == 40 && !model.hasReadSelection)
        #expect(model.perform(.rating3))
        try await sandbox.eventually { model.cullingUndoCount == 1 }
        #expect(model.cullingUndo.last?.photos.count == 40, "the change reaches every photo")
        #expect(library.items.rowsRead.count == read, "no row was read for it")
        #expect(library.items.rowsRead.values.allSatisfy { $0.metadata.rating == 3 }, "the rows read show three stars")
        try await eventually("rating:3", 40)

        // Each photo's own rating stepped; Pick twice, the second on the first's photos as culling shows them, before
        // the library holds them, so it takes the flag off again.
        #expect(model.perform(.increaseRating))
        #expect(model.perform(.flagPick))
        #expect(model.perform(.flagPick))
        try await sandbox.eventually { model.cullingUndoCount == 4 }
        #expect(model.cullingUndo.map(\.photos.count) == [40, 40, 40, 40])
        try await eventually("rating:4", 40)
        try await eventually("flag:pick", 0)
        await model.cullingTail?.value
        #expect(library.items.rowsRead.count == read, "no row was read for them")
        await library.read(library.photoIDs)
        #expect(library.items.rowsRead.values.allSatisfy { $0.metadata.rating == 4 && $0.metadata.flag == nil })

        for _ in 0 ..< 4 {
            #expect(model.perform(.undo))
        }
        try await eventually("rating:0", 40)
        try await eventually("flag:pick", 0)
        try await sandbox.eventually { library.items.rowsRead.values.allSatisfy { $0.metadata.rating == 0 } }
        #expect(library.items.rowsRead.values.allSatisfy { $0.metadata.rating == 0 }, "Undo took them all back")
        await model.cullingTail?.value
    }

    @Test func `a drag of a large source's selection carries every photo selected, in order`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let diffs = DiffLog()
        let (model, _, window) = try await open(sandbox, count: 40, diffs: diffs)
        defer { window.contentView = nil }
        let library = model.library
        model.selectAllPhotos()
        #expect(!model.hasReadSelection)
        let dragged = DraggedPhotos(
            selection: model.photoSelection, items: library.items, ids: library.photoIDs, source: library.rowSource,
            fromLibrary: true,
        )
        let urls = await dragged.urls()
        await library.read(library.photoIDs)
        let read = library.items.rowsRead
        #expect(read.count == 40)
        #expect(urls == library.photoIDs.compactMap { read[$0]?.url }, "in the grid's order")
    }

    /// Every photo of the shoot, by its URL.
    private func photos(_ sandbox: SourcesSandbox, count: Int) -> [URL] {
        (0 ..< count).map { sandbox.photo(String(format: "Shoot/P%03d.JPG", $0)) }
    }

    @Test func `Sync on a large source's whole selection starts at once, its rows unread, and reaches every photo but the open one`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let diffs = DiffLog()
        let (model, _, window) = try await open(sandbox, count: 40, diffs: diffs)
        defer { window.contentView = nil }
        let library = model.library
        let open = try #require(model.selection)
        // Sync is Develop's: the photo it syncs from is open there.
        model.showModule(.develop)
        try await sandbox.eventually { model.info?.url == open && !model.isLoading }
        try #require(model.info?.url == open, "the active photo open in Develop")
        model.setValue(.exposure, 1)
        model.copySelection = .default
        model.selectAllPhotos()
        let read = library.items.rowsRead.count
        #expect(!model.hasReadSelection)
        model.syncSettings()
        #expect(model.settingsSync.progress?.total == 39, "it starts at once, on every photo but the open one")
        await model.settingsSync.idle()
        #expect(library.items.rowsRead.count == read, "no row was read for it")
        let store = model.settingsSync.store
        for photo in photos(sandbox, count: 40) where photo != open {
            #expect(store.load(for: photo)?.recipe[.exposure] == 1, "\(photo.lastPathComponent) synced")
        }
        #expect(model.settingsSync.canUndo)
        model.undoSync()
        await model.settingsSync.idle()
        for photo in photos(sandbox, count: 40) where photo != open {
            #expect(
                (store.load(for: photo)?.recipe ?? EditRecipe())[.exposure] == 0,
                "\(photo.lastPathComponent) put back",
            )
        }
    }

    @Test func `Show in Finder shows a large source's whole selection, in order, its rows unread`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let diffs = DiffLog()
        let (model, grid, window) = try await open(sandbox, count: 40, diffs: diffs)
        defer { window.contentView = nil }
        let library = model.library
        // The grid's cells have their rows, which they read themselves.
        try await sandbox.eventually { !grid.cells.isEmpty && grid.cells.values.allSatisfy { $0.item != nil } }
        final class Revealed {
            var photos: [URL] = []
        }
        let revealed = Revealed()
        model.libraryViews.revealInFinder = { revealed.photos += $0 }
        model.selectAllPhotos()
        let read = library.items.rowsRead.count
        model.showInFinder()
        try await sandbox.eventually { !revealed.photos.isEmpty }
        #expect(library.items.rowsRead.count == read, "no row was read for it")
        await library.read(library.photoIDs)
        let rows = library.items.rowsRead
        #expect(revealed.photos == library.photoIDs.compactMap { rows[$0]?.url }, "every photo, in the grid's order")
    }

    @Test func `a keyword added to a large source's whole selection or dropped on it reaches every photo, its rows unread`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let diffs = DiffLog()
        let (model, grid, window) = try await open(sandbox, count: 40, diffs: diffs)
        defer { window.contentView = nil }
        let (library, panels) = (model.library, model.libraryPanels)
        let engine = try #require(sandbox.service?.engine)
        panels.follow()
        model.selectAllPhotos()
        try await sandbox.eventually { panels.selection.ids.count == 40 }
        let read = library.items.rowsRead.count
        func tagged(_ keyword: String) async throws -> Int {
            try await engine.list(.allPhotographs, matching: LibraryQuery(parsing: "keyword:\"\(keyword)\"")).count
        }
        // The Keywording panel's field, a change on the selection.
        #expect(try panels.add([#require(KeywordPath("Trips/2007"))]))
        await panels.written()
        try await SourcesSandbox.eventually { try await tagged("Trips/2007") == 40 }
        #expect(try await tagged("Trips/2007") == 40, "on every photo selected")
        // Dropped on the selection, every photo's ID taken as the list has them, without a pass over them.
        let list = library.photoList
        #expect(model.selectedIDs == Array(list.ids))
        #expect(
            model.selectedIDs.withUnsafeBufferPointer(\.baseAddress) == list.ids.withUnsafeBufferPointer(\.baseAddress),
            "the list's own IDs",
        )
        let steps = panels.undoSteps.count
        try grid.drop(#require(KeywordPath("Places/Lisbon")), on: .selection)
        #expect(panels.undoSteps.count == steps + 1, "made at once")
        await panels.written()
        try await SourcesSandbox.eventually { try await tagged("Places/Lisbon") == 40 }
        #expect(try await tagged("Places/Lisbon") == 40, "on every photo selected")
        #expect(library.items.rowsRead.count == read, "no row was read for them")

        // Some of them: their IDs in the list's order.
        var some = PhotoSelection()
        some.select(list[30], in: list)
        some.toggle(list[3], in: list)
        model.photoSelection = some
        #expect(model.selectedIDs == [list[3], list[30]])
    }

    @Test func `stacking a large source's whole selection stacks every photo, its rows unread`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let diffs = DiffLog()
        let (model, _, window) = try await open(sandbox, count: 40, diffs: diffs)
        defer { window.contentView = nil }
        let library = model.library
        let active = try #require(model.selection.flatMap(library.photoID(of:)))
        model.selectAllPhotos()
        let read = library.items.rowsRead.count
        #expect(model.perform(.stackPhotos))
        #expect(model.libraryPanels.undoSteps.last?.changes.contains(where: \.isStacks) == true, "made at once")
        #expect(library.items.rowsRead.count == read, "no row was read for it")
        await model.libraryPanels.written()
        func stacked() -> Int {
            guard let stacks = model.gridStacks.list?.stacks, let stack = stacks.stack(containing: active) else {
                return 0
            }
            return stacks.allPhotos(of: stack).count
        }
        try await sandbox.eventually { stacked() == 40 }
        #expect(stacked() == 40, "one stack of every photo")
        #expect(model.gridStacks.list?.stacks.stack(containing: active)?.top == active, "the active photo on top")
    }

    @Test func `a large source's list hands over a change row by row when it keeps the order and changes few`() {
        func list(_ ids: [Int64]) -> PhotoList {
            PhotoList(source: .allPhotographs, ids: ContiguousArray(ids))
        }
        let diff = LibrarySourceList.Mapping.diff(from: list([1, 2, 3, 4, 5]), to: list([1, 2, 4, 5, 6]), changed: [2])
        #expect(diff == LibraryDiff(removed: [2], inserted: [4], updated: [1]))
        #expect(LibrarySourceList.Mapping.diff(from: list([1, 2, 3]), to: list([2, 1, 3]), changed: []) == nil)
        #expect(
            LibrarySourceList.Mapping.diff(from: list(Array(0 ..< 100)), to: list(Array(50 ..< 100)), changed: [])
                == nil,
            "fifty removed are more than a change row by row",
        )
    }
}
