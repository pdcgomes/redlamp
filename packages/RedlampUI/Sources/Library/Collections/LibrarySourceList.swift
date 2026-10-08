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

        /// Whether photo `id` is one of the source's.
        func holds(_ id: Int64) -> Bool {
            items[id] != nil
        }

        /// The source's photos as `update` leaves them, reading the rows of those new or changed.
        mutating func take(_ update: PhotoListUpdate, index: LibraryIndex) async throws {
            let list = update.list
            let ids = Array(list.ids)
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
            for row in read.0 {
                guard let folder = folders[row.folder] else { continue }
                let url = URL(fileURLWithPath: (folder == "/" ? "" : folder) + "/" + row.name, isDirectory: false)
                if let old = items[row.id]?.url, old != url {
                    forget(old)
                }
                let item = LibraryFolderList.Mapping.item(row, url: url)
                if items[row.id] != item {
                    items[row.id] = item
                    touched.insert(row.id)
                }
                // Written only when they differ: the main thread holds the last change's, which a write copies.
                let key = row.contentKey.flatMap(ContentKey.init(data:))
                if keys[url] != key {
                    keys[url] = key
                }
                if indexIDs[url] != row.id {
                    indexIDs[url] = row.id
                }
            }
            let kept = Set(ids)
            for (id, item) in items.filter({ !kept.contains($0.key) }) {
                items[id] = nil
                forget(item.url)
                touched.insert(id)
            }
            self.ids = ids
            hasList = true
        }

        private mutating func forget(_ url: URL) {
            if keys[url] != nil {
                keys[url] = nil
            }
            if indexIDs[url] != nil {
                indexIDs[url] = nil
            }
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
            let removed = IndexSet(integersIn: 0 ..< before.ids.count).subtracting(carried)
            let inserted = IndexSet(change.previous.indices.filter { change.previous[$0] < 0 })
            change.diff = !first && inOrder && removed.count + inserted.count <= LibrarySourceList.largestDiff
                ? LibraryDiff(removed: removed, inserted: inserted, updated: updated) : LibraryDiff(reset: true)
            handed = (listed, places)
            touched = []
            return change
        }
    }
}
