import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

/// A Library entry's or a collection's photos, for the grid and the filmstrip (LIB-23): the source's photo
/// list, in capture order, as `LibraryItem`s at their own folders, kept current by `LibraryLive`. Each update
/// is mapped off the main thread, reading only the rows of the photos new to the list or changed; an update
/// is taken once the one before it has reached the main thread, so what changes meanwhile comes as one.
///
/// With a filter or a sort (LIB-18) it hands over the photos the filter finds, in the sort's order, each time
/// the filter or the source's photos change, worked out off the main thread from the photos it already has,
/// the latest filter winning, as the folders' lists do (`LibraryFolderList`).
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
        /// The content keys of the source's photos that have one, filtered or not, for their thumbnails from the
        /// store.
        var keys: [URL: ContentKey]
        /// The index's ID of each of the source's photos, filtered or not, by its URL.
        var ids: [URL: Int64]
        /// The source's photos, filtered or not.
        var total = 0
        /// The filter it was made with, while one is on and for the change that took it off; nil for the source's
        /// photos as they come.
        var filter: LibraryListFilter?
        /// How long the query engine took to find its photos, and the list to be made of them.
        var took: (query: Duration, list: Duration) = (.zero, .zero)
    }

    let source: PhotoSource
    private let state = Mutex(State())

    private struct State {
        var task: Task<Void, Never>?
        var updates: PhotoListUpdates?
        var closed = false
        var filter = LibraryListFilter()
        var events: AsyncStream<Event>.Continuation?
    }

    private enum Event: Sendable {
        case update(PhotoListUpdate)
        case filter
    }

    /// Changes this small that keep the photos' order are handed over row by row; larger ones reset, which
    /// the filmstrip and the grid take faster than as many rows.
    static let largestDiff = 32

    /// The list opens once LibraryLive has applied the changes it has gathered.
    init(
        core: LibraryCore, source: PhotoSource, filter: LibraryListFilter = LibraryListFilter(),
        deliver: @escaping @MainActor @Sendable (Change) -> Void,
    ) {
        self.source = source
        let (live, index, engine) = (core.live, core.index, core.engine)
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        state.withLock { state in
            state.filter = filter
            state.events = continuation
        }
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await live.settle()
            let updates = live.open(source, sort: QuerySort(.captured))
            guard let self, state.withLock({ state in
                state.updates = updates
                return !state.closed
            }) else { return updates.close() }
            // An update is taken only once the one before it has reached the main thread: LibraryLive makes
            // one update of what changes meanwhile.
            let (handled, handing) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            let forwarding = Task {
                var turns = handled.makeAsyncIterator()
                for await update in updates {
                    continuation.yield(.update(update))
                    guard await turns.next() != nil else { break }
                }
                continuation.finish()
            }
            defer {
                forwarding.cancel()
                handing.finish()
            }
            var mapping = Mapping()
            var handedFilter: LibraryListFilter?
            for await event in events {
                let filter = state.withLock { $0.filter }
                var changed = false
                if case let .update(update) = event {
                    changed = await (try? mapping.take(update, index: index)) != nil
                }
                if mapping.hasList, changed || filter != handedFilter,
                   let change = try? await Self.change(
                       handing: filter,
                       after: handedFilter,
                       from: &mapping,
                       engine: engine,
                       source: source,
                   ) {
                    handedFilter = filter
                    await deliver(change)
                }
                if case .update = event {
                    handing.yield()
                }
            }
        }
        state.withLock { $0.task = task }
    }

    /// What the list is filtered and sorted by.
    var filter: LibraryListFilter {
        state.withLock { $0.filter }
    }

    /// Filters and sorts the list from now on: the list made with the latest filter is handed over.
    func setFilter(_ filter: LibraryListFilter) {
        let events = state.withLock { state -> AsyncStream<Event>.Continuation? in
            guard state.filter != filter else { return nil }
            state.filter = filter
            return state.events
        }
        events?.yield(.filter)
    }

    /// Stops following the list.
    func close() {
        let (task, updates, events) = state.withLock { state in
            state.closed = true
            return (state.task, state.updates, state.events)
        }
        updates?.close()
        events?.finish()
        task?.cancel()
    }

    /// The change handing over the photos `filter` finds of `mapping`'s, in its sort's order; `before` is the
    /// filter of the change handed over before, nil for the first.
    private static func change(
        handing filter: LibraryListFilter, after before: LibraryListFilter?, from mapping: inout Mapping,
        engine: QueryEngine, source: PhotoSource,
    ) async throws -> Change {
        let clock = ContinuousClock()
        let started = clock.now
        var queried = Duration.zero
        var ids = mapping.ids
        if filter.query != nil || filter.sort != nil {
            let list = try await engine.list(
                source, matching: filter.query ?? .all, sort: filter.sort ?? QuerySort(.captured),
            )
            queried = clock.now - started
            ids = filter.sort == nil ? ids.filter(list.contains) : list.ids.filter { mapping.holds($0) }
        }
        if filter.reversed {
            ids.reverse()
        }
        var change = mapping.change(handing: ids)
        change.filter = filter.isEmpty && before?.isEmpty != false ? nil : filter
        change.took = (queried, clock.now - started - queried)
        return change
    }

    /// What maps a list's updates to changes: every photo of the source by ID, filtered or not, their folders'
    /// paths, and the photos handed over last.
    struct Mapping: Sendable {
        private var items: [Int64: LibraryItem] = [:]
        private var folders: [Int64: String] = [:]
        /// The source's photos in its own order, capture time's.
        private(set) var ids: [Int64] = []
        private(set) var hasList = false
        /// Handed over whole with every change: merging a list's thousands on the main thread takes milliseconds.
        private var keys: [URL: ContentKey] = [:]
        private var indexIDs: [URL: Int64] = [:]
        /// The photos whose rows changed or that went since the last change was handed over: only those can differ
        /// from its rows. The rows handed over aren't kept: the main thread changes their badges in place, which
        /// a copy kept here would make it copy whole.
        private var touched = Set<Int64>()
        /// The IDs handed over last, in order, and each one's place among them; nil before the first.
        private var handed: (ids: [Int64], places: [Int64: Int32])?
        /// The last update was taken whole, so `ids` are the photos the next one's diff counts from.
        private var inStep = false
        /// Photos of the list whose rows weren't read when they came: read again with the next update.
        private var unread: [Int64] = []

        /// Whether photo `id` is one of the source's.
        func holds(_ id: Int64) -> Bool {
            items[id] != nil
        }

        /// The source's photos as `update` leaves them, reading the rows of those new or changed. Once an update
        /// has been taken whole, the next is taken from the photos its diff names alone: those that came, went or
        /// changed, and any whose row wasn't read before. A reset is taken by looking at every photo.
        mutating func take(_ update: PhotoListUpdate, index: LibraryIndex) async throws {
            let list = update.list
            let ids = Array(list.ids)
            let diff = update.diff
            let stepped = inStep && !diff.reset && (diff.removed.last ?? -1) < self.ids.count
            inStep = false
            let named = diff.reset ? []
                : diff.inserted.map { list[$0] } + diff.updated.map { list[$0] } + diff.moved.map { list[$0.to] }
            // With none of the source's photos kept yet, every photo is read, and is new, and none leaves.
            let fresh = items.isEmpty
            let reading: [Int64]
            var leaving: [Int64] = []
            if stepped {
                reading = named + unread
                leaving = diff.removed.map { self.ids[$0] }
            } else if fresh {
                reading = ids
            } else {
                let changed = Set(named)
                reading = ids.filter { items[$0] == nil || changed.contains($0) }
            }
            let read = try await Self.read(reading, folders: folders, index: index)
            folders.merge(read.folders) { _, new in new }
            let count = read.parts.reduce(0) { $0 + $1.count }
            if fresh {
                items.reserveCapacity(count)
                keys.reserveCapacity(count)
                indexIDs.reserveCapacity(count)
            }
            for photo in read.parts.joined() {
                keep(photo, fresh: fresh)
            }
            if !stepped, !fresh {
                let kept = Set(ids)
                leaving = items.keys.filter { !kept.contains($0) }
            }
            for id in leaving {
                guard let item = items.removeValue(forKey: id) else { continue }
                forget(item.url)
                touched.insert(id)
            }
            unread = count == reading.count ? [] : reading.filter { items[$0] == nil }
            self.ids = ids
            hasList = true
            inStep = true
        }

        /// Keeps `photo` as it was read; when none of the source's photos were kept before (`fresh`), without looking
        /// for what it was.
        private mutating func keep(_ photo: Read, fresh: Bool) {
            let url = photo.item.url
            if fresh {
                items[photo.id] = photo.item
                // Photos not handed over before differ from none handed over.
                if handed != nil {
                    touched.insert(photo.id)
                }
                keys[url] = photo.key
                indexIDs[url] = photo.id
                return
            }
            if let old = items[photo.id]?.url, old != url {
                forget(old)
            }
            if items[photo.id] != photo.item {
                items[photo.id] = photo.item
                touched.insert(photo.id)
            }
            // Written only when they differ: the main thread holds the last change's, which a write copies.
            if keys[url] != photo.key {
                keys[url] = photo.key
            }
            if indexIDs[url] != photo.id {
                indexIDs[url] = photo.id
            }
        }

        private mutating func forget(_ url: URL) {
            keys.removeValue(forKey: url)
            indexIDs.removeValue(forKey: url)
        }

        /// The change handing over the photos `ids` names, in its order, against those handed over before.
        mutating func change(handing ids: [Int64]) -> Change {
            let first = handed == nil
            let before = handed ?? ([], [:])
            var change = Change(
                items: [], positions: [:], previous: [], previousCount: first ? -1 : before.ids.count,
                diff: LibraryDiff(), keys: keys, ids: indexIDs, total: self.ids.count,
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
                guard let item = items[id] else { continue }
                let index = change.items.count
                // A URL listed twice keeps its first place.
                if let earlier = change.positions.updateValue(index, forKey: item.url) {
                    change.positions[item.url] = earlier
                    continue
                }
                let place = first ? -1 : before.places[id] ?? -1
                if place >= 0 {
                    carried.insert(Int(place))
                    inOrder = inOrder && place > lastCarried
                    lastCarried = place
                    if touched.contains(id) {
                        updated.insert(index)
                    }
                }
                change.items.append(item)
                change.previous.append(place)
                listed.append(id)
                places[id] = Int32(index)
            }
            change.diff = LibraryDiff(reset: true)
            if !first, inOrder {
                let removed = IndexSet(integersIn: 0 ..< before.ids.count).subtracting(carried)
                let inserted = IndexSet(change.previous.indices.filter { change.previous[$0] < 0 })
                if removed.count + inserted.count <= LibrarySourceList.largestDiff {
                    change.diff = LibraryDiff(removed: removed, inserted: inserted, updated: updated)
                }
            }
            handed = (listed, places)
            touched = []
            return change
        }
    }
}

extension LibrarySourceList {
    /// A photo of the source as the grid shows it, at its folder, and its content key, as its row is read.
    struct Read: Sendable {
        var id: Int64
        var item: LibraryItem
        var key: ContentKey?
    }
}

extension LibrarySourceList.Mapping {
    /// The columns of a photo's row the grid shows, those `LibraryFolderList.Mapping.item` takes, with its folder,
    /// name and content key, in the order `read(_:folder:)` reads them.
    static let shown = """
    id, folder, name, size, modified, sidecar_modified, edited, rating, flag, label, custom_label, marked, \
    other_fields, content_key
    """

    /// Photos are read in one pass over their IDs' range from this many, while the range holds at most `spread`
    /// times as many photos as are read.
    static let passFrom = 1024
    static let spread: Int64 = 16
    /// The pass's parts read at once: of the index's four readers, one is left for searches and counts.
    static let partsAtOnce = 3

    /// Photos `ids` as the grid shows them, from their rows, in parts, with the paths of the folders read for them,
    /// those `known` lacks at least. Many photos close together in ID are read in one pass over their range, in ID
    /// order, after every folder's path, a part of `part` IDs at a time on each of `partsAtOnce` readers, so a read
    /// asked for meanwhile waits for one part at most: a row read by its ID costs a lookup each, 16 s in all for a
    /// million photos.
    static func read(
        _ ids: [Int64], folders known: [Int64: String], index: LibraryIndex, part: Int64 = 1 << 15,
    ) async throws -> (parts: [[LibrarySourceList.Read]], folders: [Int64: String]) {
        guard ids.count >= passFrom, let low = ids.min(), let high = ids.max(),
              high - low < Int64(ids.count) * spread
        else {
            return try await index.read { reader in
                let statement = try reader.database.cached("SELECT \(shown) FROM photos WHERE id = ?")
                var photos: [LibrarySourceList.Read] = []
                photos.reserveCapacity(ids.count)
                var folders: [Int64: String] = [:]
                for id in ids {
                    try statement.bind(id, at: 1)
                    try statement.forEachRow { row in
                        let folder = row.int64(at: 1)
                        if known[folder] == nil, folders[folder] == nil {
                            folders[folder] = try reader.folder(id: folder)?.path
                        }
                        if let path = known[folder] ?? folders[folder] {
                            photos.append(Self.read(row, folder: path))
                        }
                    }
                }
                return ([photos], folders)
            }
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
        let (chosen, size) = (wanted, max(part, 1))
        @Sendable func reading(from start: Int64) async throws -> [LibrarySourceList.Read] {
            try await index.read { reader in
                let statement = try reader.database.cached("SELECT \(shown) FROM photos WHERE id BETWEEN ? AND ?")
                try statement.bind(start, at: 1)
                try statement.bind(min(start + size - 1, high), at: 2)
                var found: [LibrarySourceList.Read] = []
                try statement.forEachRow { row in
                    let bit = row.int64(at: 0) - low
                    guard chosen[Int(bit >> 6)] & 1 << UInt64(bit & 63) != 0, let path = folders[row.int64(at: 1)]
                    else { return }
                    found.append(Self.read(row, folder: path))
                }
                return found
            }
        }
        var starts = stride(from: low, through: high, by: Int(size)).makeIterator()
        let read = try await withThrowingTaskGroup(of: [LibrarySourceList.Read].self) { group in
            for _ in 0 ..< partsAtOnce {
                if let start = starts.next() {
                    group.addTask { try await reading(from: start) }
                }
            }
            var parts: [[LibrarySourceList.Read]] = []
            while let found = try await group.next() {
                parts.append(found)
                if let start = starts.next() {
                    group.addTask { try await reading(from: start) }
                }
            }
            return parts
        }
        return (read, folders)
    }

    /// The photo of `row`, read with `shown`'s columns, as the grid shows it in the folder at `folder`.
    private static func read(_ row: SQLiteStatement, folder: String) -> LibrarySourceList.Read {
        let photo = PhotoRecord(
            id: row.int64(at: 0), folder: row.int64(at: 1), name: row.string(at: 2) ?? "", size: row.int64(at: 3),
            modified: Date(timeIntervalSince1970: row.double(at: 4)), contentKey: row.data(at: 13),
            rating: row.int(at: 7), flag: PhotoRecord.flag(code: row.int(at: 8)),
            label: PhotoRecord.label(code: row.int(at: 9)), marked: row.bool(at: 11), edited: row.bool(at: 6),
            sidecarModified: row.optionalDouble(at: 5).map(Date.init(timeIntervalSince1970:)),
            customLabel: row.string(at: 10), otherFields: PhotoRecord.fields(code: row.int(at: 12)),
        )
        let url = URL(fileURLWithPath: (folder == "/" ? "" : folder) + "/" + photo.name, isDirectory: false)
        return LibrarySourceList.Read(
            id: photo.id, item: LibraryFolderList.Mapping.item(photo, url: url, folder: folder),
            key: photo.contentKey.flatMap(ContentKey.init(data:)),
        )
    }
}
