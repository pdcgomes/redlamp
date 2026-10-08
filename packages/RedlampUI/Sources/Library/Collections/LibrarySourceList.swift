import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

/// A Library entry's or a collection's photos, for the grid and the filmstrip (LIB-23): the source's photo
/// list, in capture order, as `LibraryItem`s at their own folders, kept current by `LibraryLive`. Each update
/// is mapped off the main thread, reading only the rows of the photos new to the list or changed; an update
/// is taken once the one before it has reached the main thread, so what changes meanwhile comes as one.
///
/// A photo's badges are its `.redlamp` sidecar's, as the folders' lists show them.
final class LibrarySourceList: Sendable {
    /// The photos in the list's order, and how they differ from those handed over before.
    struct Change: Sendable {
        var items: [LibraryItem]
        var positions: [URL: Int]
        /// Each photo's place in the photos handed over before; -1 for a photo new to them.
        var previous: [Int32]
        /// How many photos were handed over before; -1 for the first change.
        var previousCount: Int
        /// The rows removed, inserted and changed, or a reset when the photos that stayed moved.
        var diff: LibraryDiff
        /// The content keys of the photos that have one, for their thumbnails from the store.
        var keys: [URL: ContentKey]
        /// The index's ID of each photo, by its URL.
        var ids: [URL: Int64]
    }

    let source: PhotoSource
    private let state = Mutex(State())

    private struct State {
        var task: Task<Void, Never>?
        var updates: PhotoListUpdates?
        var closed = false
    }

    /// Changes this small that keep the photos' order are handed over row by row; larger ones reset, which
    /// the filmstrip and the grid take faster than as many rows.
    static let largestDiff = 32

    /// The list opens once LibraryLive has applied the changes it has gathered. With `only`, it holds just
    /// those photos of the source's.
    init(
        core: LibraryCore, source: PhotoSource, only: Set<Int64>? = nil,
        deliver: @escaping @MainActor @Sendable (Change) -> Void,
    ) {
        self.source = source
        let (live, index) = (core.live, core.index)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await live.settle()
            let updates = live.open(source, sort: QuerySort(.captured))
            guard let self, state.withLock({ state in
                state.updates = updates
                return !state.closed
            }) else { return updates.close() }
            var mapping = Mapping(only: only)
            for await update in updates {
                guard let change = try? await mapping.change(for: update, index: index) else { continue }
                await deliver(change)
            }
        }
        state.withLock { $0.task = task }
    }

    /// Stops following the list.
    func close() {
        let (task, updates) = state.withLock { state in
            state.closed = true
            return (state.task, state.updates)
        }
        updates?.close()
        task?.cancel()
    }

    /// What maps a list's updates to changes: the photos handed over last, by ID, and their folders' paths.
    struct Mapping: Sendable {
        let only: Set<Int64>?
        private var items: [Int64: LibraryItem] = [:]
        private var keys: [Int64: ContentKey] = [:]
        private var folders: [Int64: String] = [:]
        /// The IDs handed over last, in order, and each one's place among them; nil before the first.
        private var handed: (ids: [Int64], places: [Int64: Int32])?

        init(only: Set<Int64>?) {
            self.only = only
        }

        /// The change `update` makes to the photos handed over, reading the rows of those new or changed.
        mutating func change(for update: PhotoListUpdate, index: LibraryIndex) async throws -> Change {
            let list = update.list
            var ids = Array(list.ids)
            if let only {
                ids.removeAll { !only.contains($0) }
            }
            var changed = Set<Int64>()
            if !update.diff.reset {
                changed.formUnion(update.diff.inserted.map { list[$0] })
                changed.formUnion(update.diff.updated.map { list[$0] })
                changed.formUnion(update.diff.moved.map { list[$0.to] })
            }
            let reading = ids.filter { items[$0] == nil || changed.contains($0) }
            let known = folders
            let read = try await index.read { reader -> ([PhotoRecord], [Int64: String]) in
                var rows: [PhotoRecord] = []
                rows.reserveCapacity(reading.count)
                var folders: [Int64: String] = [:]
                for id in reading {
                    guard let row = try reader.photo(id: id) else { continue }
                    rows.append(row)
                    if known[row.folder] == nil, folders[row.folder] == nil {
                        folders[row.folder] = try reader.folder(id: row.folder)?.path
                    }
                }
                return (rows, folders)
            }
            folders.merge(read.1) { _, new in new }
            var fresh: [Int64: LibraryItem] = [:]
            for row in read.0 {
                guard let folder = folders[row.folder] else { continue }
                let url = URL(fileURLWithPath: (folder == "/" ? "" : folder) + "/" + row.name, isDirectory: false)
                fresh[row.id] = LibraryFolderList.Mapping.item(row, url: url)
                keys[row.id] = row.contentKey.flatMap(ContentKey.init(data:))
            }
            let kept = Set(ids)
            for id in items.keys where !kept.contains(id) {
                items[id] = nil
                keys[id] = nil
            }
            return order(ids, fresh: fresh)
        }

        /// The photos `ids` names, in its order, `fresh` holding the rows just read, against those handed over.
        private mutating func order(_ ids: [Int64], fresh: [Int64: LibraryItem]) -> Change {
            let first = handed == nil
            let before = handed ?? ([], [:])
            var change = Change(
                items: [], positions: [:], previous: [], previousCount: first ? -1 : before.ids.count,
                diff: LibraryDiff(), keys: [:], ids: [:],
            )
            change.items.reserveCapacity(ids.count)
            change.positions.reserveCapacity(ids.count)
            change.previous.reserveCapacity(ids.count)
            var listed: [Int64] = []
            listed.reserveCapacity(ids.count)
            var places: [Int64: Int32] = [:]
            places.reserveCapacity(ids.count)
            var updated = IndexSet()
            var carried = IndexSet()
            var inOrder = true
            var lastCarried: Int32 = -1
            for id in ids {
                let old = items[id]
                guard let item = fresh[id] ?? old else { continue }
                // A URL listed twice keeps its first place.
                guard change.positions[item.url] == nil else { continue }
                let index = change.items.count
                let place = first ? -1 : before.places[id] ?? -1
                if place >= 0 {
                    carried.insert(Int(place))
                    inOrder = inOrder && place > lastCarried
                    lastCarried = place
                    if old != item {
                        updated.insert(index)
                    }
                }
                items[id] = item
                change.items.append(item)
                change.positions[item.url] = index
                change.previous.append(place)
                change.ids[item.url] = id
                if let key = keys[id] {
                    change.keys[item.url] = key
                }
                listed.append(id)
                places[id] = Int32(index)
            }
            let removed = IndexSet(integersIn: 0 ..< before.ids.count).subtracting(carried)
            let inserted = IndexSet(change.previous.indices.filter { change.previous[$0] < 0 })
            change.diff = !first && inOrder && removed.count + inserted.count <= LibrarySourceList.largestDiff
                ? LibraryDiff(removed: removed, inserted: inserted, updated: updated) : LibraryDiff(reset: true)
            handed = (listed, places)
            return change
        }
    }
}
