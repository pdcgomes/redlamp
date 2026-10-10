import Foundation
import RedlampDocument
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

    /// The URLs of the photos `ids`, from their folders and names alone, for an action on photos whose rows aren't
    /// read (`SelectedPhotos`); photos the index no longer has are left out. Many photos close together in ID are
    /// read in one pass over their range, in parts on three of the index's readers, as their rows are.
    func urls(of ids: [Int64]) async throws -> [Int64: URL] {
        try await read(ids) { _, url in url }
    }

    /// What culling reads of a photo whose row isn't read: its URL and what its badges show of culling's fields.
    struct Badges: Sendable {
        let url: URL
        let values: CullingValues
    }

    /// The URLs of the photos `ids` and what their rows' badges show of culling's fields
    /// (`LibraryFolderList.Mapping.metadata`), for culling photos whose rows aren't read, without reading or keeping
    /// their rows; photos the index no longer has are left out. Read as `urls(of:)` reads theirs.
    func badges(of ids: [Int64]) async throws -> [Int64: Badges] {
        try await read(ids, columns: "sidecar_modified, rating, flag, label, custom_label, marked, other_fields") {
            row, url in
            Badges(url: url, values: CullingValues(LibraryFolderList.Mapping.metadata(
                rating: row.int(at: 4), flag: PhotoRecord.flag(code: row.int(at: 5)),
                label: PhotoRecord.label(code: row.int(at: 6)), customLabel: row.string(at: 7),
                marked: row.bool(at: 8), otherFields: PhotoRecord.fields(code: row.int(at: 9)),
                hasSidecar: row.optionalDouble(at: 3) != nil,
            )))
        }
    }

    /// Each of the photos `ids` that the index has, as `make` makes it of its row, read with `id, folder, name` and
    /// `columns` after them, and its URL. Many photos close together in ID are read in one pass over their range, in
    /// parts on three of the index's readers, as their rows are.
    private func read<Value: Sendable>(
        _ ids: [Int64], columns: String = "", _ make: @escaping @Sendable (SQLiteStatement, URL) -> Value,
    ) async throws -> [Int64: Value] {
        typealias Mapping = LibrarySourceList.Mapping
        guard !ids.isEmpty else { return [:] }
        let selected = columns.isEmpty ? "id, folder, name" : "id, folder, name, " + columns
        guard ids.count >= Mapping.passFrom, let low = ids.min(), let high = ids.max(),
              high - low < Int64(ids.count) * Mapping.spread
        else {
            let known = state.withLock { $0.folders }
            let (values, folders) = try await index.read { reader in
                let statement = try reader.database.cached("SELECT \(selected) FROM photos WHERE id = ?")
                var values: [Int64: Value] = [:]
                var folders: [Int64: String] = [:]
                for id in ids {
                    try statement.bind(id, at: 1)
                    try statement.forEachRow { row in
                        let folder = row.int64(at: 1)
                        if known[folder] == nil, folders[folder] == nil {
                            folders[folder] = try reader.folder(id: folder)?.path
                        }
                        if let path = known[folder] ?? folders[folder] {
                            values[id] = make(row, Self.url(path, row.string(at: 2) ?? ""))
                        }
                    }
                }
                return (values, folders)
            }
            if !folders.isEmpty {
                state.withLock { $0.folders.merge(folders) { _, new in new } }
            }
            return values
        }
        let folders = try await index.read { reader in
            var paths: [Int64: String] = [:]
            try reader.database.cached("SELECT id, path FROM folders").forEachRow { row in
                paths[row.int64(at: 0)] = row.string(at: 1)
            }
            return paths
        }
        var wanted = [UInt64](repeating: 0, count: Int((high - low) >> 6) + 1)
        for id in ids {
            wanted[Int(id - low) >> 6] |= 1 << UInt64((id - low) & 63)
        }
        let (chosen, size, index) = (wanted, Int64(1) << 15, index)
        @Sendable func reading(from start: Int64) async throws -> [(Int64, Value)] {
            try await index.read { reader in
                let statement = try reader.database.cached("SELECT \(selected) FROM photos WHERE id BETWEEN ? AND ?")
                try statement.bind(start, at: 1)
                try statement.bind(min(start + size - 1, high), at: 2)
                var found: [(Int64, Value)] = []
                try statement.forEachRow { row in
                    let id = row.int64(at: 0)
                    let bit = id - low
                    guard chosen[Int(bit >> 6)] & 1 << UInt64(bit & 63) != 0, let path = folders[row.int64(at: 1)]
                    else { return }
                    found.append((id, make(row, Self.url(path, row.string(at: 2) ?? ""))))
                }
                return found
            }
        }
        var starts = stride(from: low, through: high, by: Int(size)).makeIterator()
        return try await withThrowingTaskGroup(of: [(Int64, Value)].self) { group in
            for _ in 0 ..< Mapping.partsAtOnce {
                if let start = starts.next() {
                    group.addTask { try await reading(from: start) }
                }
            }
            var values: [Int64: Value] = [:]
            values.reserveCapacity(ids.count)
            while let found = try await group.next() {
                for (id, value) in found {
                    values[id] = value
                }
                if let start = starts.next() {
                    group.addTask { try await reading(from: start) }
                }
            }
            return values
        }
    }

    /// The photo named `name` in the folder at `folder`, as its row's URL is made.
    private static func url(_ folder: String, _ name: String) -> URL {
        URL(fileURLWithPath: (folder == "/" ? "" : folder) + "/" + name, isDirectory: false)
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
