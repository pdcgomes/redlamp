import Foundation
import RedlampLibrary
import Synchronization

/// A large list's rows (`LibrarySourceList`, `LibraryFolderList.Large`), read as the grid and the filmstrip ask for
/// them (`rows(of:)`), since reading a million takes most of a second; and the photos the main thread holds rows of,
/// or has asked for, which each change brings again when it changes them (`read(into:changed:first:wanted:)`).
final class LargeListRows: Sendable {
    /// The rows of a large list's first photos its first change brings.
    let firstRead: Int
    private let index: LibraryIndex
    private let state = Mutex(State())

    private struct State {
        var held = Set<Int64>()
        /// The folders' paths the rows asked for were read with.
        var folders: [Int64: String] = [:]
    }

    init(index: LibraryIndex, firstRead: Int) {
        self.index = index
        self.firstRead = firstRead
    }

    /// The main thread holds the rows of the photos `ids`, or has asked for them: each change brings them again
    /// when it changes them.
    func hold(_ ids: some Sequence<Int64>) {
        state.withLock { $0.held.formUnion(ids) }
    }

    /// The main thread no longer holds the rows of the photos `ids`; `all` lets go of every one.
    func release(_ ids: some Sequence<Int64>, all: Bool = false) {
        state.withLock { state in
            if all {
                state.held = []
            } else {
                state.held.subtract(ids)
            }
        }
    }

    /// The rows of the photos `ids`, as the grid shows them, with their content keys and paths; photos the index no
    /// longer has are left out.
    func rows(of ids: [Int64]) async throws -> LibrarySourceList.Rows {
        let known = state.withLock { $0.folders }
        let read = try await LibrarySourceList.Mapping.read(ids, folders: known, index: index)
        if !read.folders.isEmpty {
            state.withLock { $0.folders.merge(read.folders) { _, new in new } }
        }
        var rows = LibrarySourceList.Rows()
        rows.take(read.parts)
        return rows
    }

    /// Reads into a large list's `change` the rows it brings: those of its first screens and of the photos at the URLs
    /// `wanted` with the `first` change, and those of the photos the main thread holds that `changed` names (all of
    /// them when it's nil, as after the list was made afresh), the rows kept from before the list was large among
    /// them.
    func read(
        into change: inout LibrarySourceList.Change, changed: Set<Int64>?, first: Bool, wanted: [URL],
    ) async throws {
        var held = state.withLock { $0.held }
        if let kept = change.read {
            held.formUnion(kept.keys)
        }
        var reading = changed.map { held.intersection($0) } ?? held
        if first {
            reading.formUnion(change.list.ids.prefix(firstRead))
            if !wanted.isEmpty {
                await reading.formUnion(LibraryService.indexIDs(of: wanted, in: index).values)
            }
        }
        reading = reading.filter(change.list.contains)
        guard !reading.isEmpty else { return }
        let rows = try await rows(of: Array(reading))
        change.read?.merge(rows.items) { _, new in new }
        for id in reading where rows.items[id] != nil {
            change.keys[id] = rows.keys[id]
        }
        change.paths.merge(rows.paths)
    }
}
