import AppKit
import Foundation
import RedlampDocument
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

    @Test func `culling a large source's whole selection reads its rows first, and Undo takes it back`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let diffs = DiffLog()
        let (model, _, window) = try await open(sandbox, count: 40, diffs: diffs)
        defer { window.contentView = nil }
        let library = model.library
        let engine = try #require(sandbox.service?.engine)
        func rated(_ stars: Int) async throws -> Int {
            try await engine.list(.allPhotographs, matching: LibraryQuery(parsing: "rating:\(stars)")).count
        }
        model.selectAllPhotos()
        #expect(model.selectedCount == 40 && !model.hasReadSelection)
        #expect(model.perform(.rating3))
        try await sandbox.eventually(seconds: 20) { library.items.rowsRead.count == 40 }
        #expect(library.items.rowsRead.values.allSatisfy { $0.metadata.rating == 3 }, "every photo shows three stars")
        for _ in 0 ..< 400 where try await rated(3) != 40 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await rated(3) == 40, "the library has three stars on every photo")

        #expect(model.perform(.undo))
        for _ in 0 ..< 400 where try await rated(3) != 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await rated(3) == 0, "Undo took them all back")
        try await sandbox.eventually { library.items.rowsRead.values.allSatisfy { $0.metadata.rating == 0 } }
        #expect(library.items.rowsRead.values.allSatisfy { $0.metadata.rating == 0 }, "and the rows show it")
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
