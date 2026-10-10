import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

/// A Library entry's or a collection's photos, for the grid and the filmstrip (LIB-23): the source's photo
/// list, in capture order, by the photos' IDs in the index, with each one as a `LibraryItem` at its own folder,
/// kept current by `LibraryLive`. Each update is mapped off the main thread, reading only the rows of the photos
/// new to the list or changed; an update is taken once the one before it has reached the main thread, so what
/// changes meanwhile comes as one. Nothing is kept by URL: a photo is found from its URL by its folder and name
/// (`PhotoPaths`), as hashing a million URLs took seconds.
///
/// With a filter or a sort (LIB-18) it hands over the photos the filter finds, in the sort's order, each time
/// the filter or the source's photos change, worked out off the main thread from the photos it already has,
/// the latest filter winning, as the folders' lists do (`LibraryFolderList`).
///
/// A source of more than `largestRead` photos is large: its rows aren't read as it changes, but as the grid and the
/// filmstrip ask for them (`largeRows`), since reading a million takes most of a second. Each change hands over its
/// list, with the rows read for it: the first screens' and those of `wanted` photos with the first change, and
/// with every change those of the photos the main thread holds rows of that it changed.
///
/// A photo's badges are its `.redlamp` sidecar's, as the folders' lists show them.
final class LibrarySourceList: Sendable {
    /// The photos in the list's order, and how they differ from those handed over before.
    struct Change: Sendable {
        /// The photos' IDs in the index, in the list's order.
        var list: PhotoList
        /// The photos, in the list's order; none for a large source, whose rows are `read`.
        var items: [LibraryItem]
        /// For a large source, the rows read for this change, by ID: of the photos the main thread holds that
        /// changed, or with the first change, those of its first screens and of the photos it wanted. Nil for a
        /// source whose rows are all in `items`.
        var read: [Int64: LibraryItem]?
        /// How many photos were handed over before; -1 for the first change.
        var previousCount: Int
        /// The rows removed, inserted and changed, or a reset when the photos that stayed moved.
        var diff: LibraryDiff
        /// The content keys of the source's photos that have one, filtered or not, by their IDs, for their
        /// thumbnails from the store; for a large source, those of the rows `read`.
        var keys: [Int64: ContentKey]
        /// The source's photos by their folders and names, filtered or not; for a large source, those of the rows
        /// `read`.
        var paths: PhotoPaths
        /// The source's photos, filtered or not.
        var total = 0
        /// The filter it was made with, while one is on and for the change that took it off; nil for the source's
        /// photos as they come.
        var filter: LibraryListFilter?
        /// How long the query engine took to find its photos, and the list to be made of them.
        var took: (query: Duration, list: Duration) = (.zero, .zero)
    }

    let source: PhotoSource
    /// Sources with more photos than this are large.
    let largestRead: Int
    /// A large source's rows, read as they're asked for.
    let largeRows: LargeListRows
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

    /// Sources with more photos than this are large, by default: reading and mapping as many rows takes about a
    /// sixth of a second.
    static let largestRead = 50000

    /// The rows read with a large source's first change, of its first photos: the screens the grid and the
    /// filmstrip open on, and the thumbnails warmed (`LibrarySources.warmedAsShown`).
    static let firstRead = 1000

    /// The list opens once LibraryLive has applied the changes it has gathered; with a large source, its first
    /// change brings the rows of the photos at `wanted` too (the kept view's active, selected and top photos).
    init(
        core: LibraryCore, source: PhotoSource, filter: LibraryListFilter = LibraryListFilter(),
        largestRead: Int = LibrarySourceList.largestRead, firstRead: Int = LibrarySourceList.firstRead,
        wanted: [URL] = [], deliver: @escaping @MainActor @Sendable (Change) -> Void,
    ) {
        self.source = source
        self.largestRead = largestRead
        let rows = LargeListRows(index: core.index, firstRead: firstRead)
        largeRows = rows
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
            var mapping = Mapping(largestRead: largestRead)
            var handedFilter: LibraryListFilter?
            var first = true
            for await event in events {
                let filter = state.withLock { $0.filter }
                var changed = false
                if case let .update(update) = event {
                    changed = await (try? mapping.take(update, index: index)) != nil
                }
                if mapping.hasList, changed || filter != handedFilter,
                   var change = try? await Self.change(
                       handing: filter,
                       after: handedFilter,
                       from: &mapping,
                       engine: engine,
                       source: source,
                   ) {
                    if change.read != nil {
                        try? await rows.read(into: &change, changed: mapping.rereading, first: first, wanted: wanted)
                    }
                    first = false
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

    // MARK: - A large source's rows

    /// Rows read for a large source, by ID, as the main thread takes them.
    struct Rows: Sendable {
        var items: [Int64: LibraryItem] = [:]
        var keys: [Int64: ContentKey] = [:]
        var paths = PhotoPaths()

        mutating func take(_ parts: [[Read]]) {
            for part in parts {
                for photo in part {
                    items[photo.id] = photo.item
                    if let key = photo.key {
                        keys[photo.id] = key
                    }
                }
                paths.insert(part)
            }
        }
    }

    /// The change handing over the photos `filter` finds of `mapping`'s, in its sort's order; `before` is the
    /// filter of the change handed over before, nil for the first.
    static func change(
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
                moments: filter.moments,
            )
            queried = clock.now - started
            ids = filter.sort == nil ? ids.filter(list.contains) : list.ids.filter { mapping.holds($0) }
        }
        if filter.reversed {
            ids.reverse()
        }
        let whole = filter.query == nil && filter.sort == nil && !filter.reversed
        var change = mapping.change(handing: ids, of: source, whole: whole)
        change.filter = filter.isEmpty && before?.isEmpty != false ? nil : filter
        change.took = (queried, clock.now - started - queried)
        return change
    }
}

extension LibrarySourceList {
    /// What maps a list's updates to changes: every photo of the source by ID, filtered or not, their folders'
    /// paths, and the photos handed over last; for a large source, its list alone.
    struct Mapping: Sendable {
        /// Sources with more photos than this are large.
        let largestRead: Int
        /// The source's photos while it's large; nil while their rows are kept here.
        private var large: PhotoList?
        /// While the source is large, the photos whose rows changed since the last change was handed over; nil when
        /// any may have, as after the list was made afresh.
        private var changedSinceHanded: Set<Int64>? = []
        /// What the last change handed over of a large source changed (`changedSinceHanded`), for its rows to be
        /// read again.
        private(set) var rereading: Set<Int64>? = []
        /// The rows kept when the source became large, handed over with the next change.
        private var leftover: Rows?
        private var items: [Int64: LibraryItem] = [:]
        private var folders: [Int64: String] = [:]
        /// The source's photos in its own order, capture time's.
        private(set) var ids: [Int64] = []
        private(set) var hasList = false
        /// Handed over whole with every change: merging a list's thousands on the main thread takes milliseconds.
        private var keys: [Int64: ContentKey] = [:]
        private var paths = PhotoPaths()
        /// The photos whose rows changed or that went since the last change was handed over: only those can differ
        /// from its rows. The rows handed over aren't kept: the main thread changes their badges in place, which
        /// a copy kept here would make it copy whole.
        private var touched = Set<Int64>()
        /// The photos handed over last, in order; nil before the first.
        private var handed: PhotoList?
        /// The last update was taken whole, so `ids` are the photos the next one's diff counts from.
        private var inStep = false
        /// Photos of the list whose rows weren't read when they came: read again with the next update.
        private var unread: [Int64] = []

        init(largestRead: Int = LibrarySourceList.largestRead) {
            self.largestRead = largestRead
        }

        /// Whether photo `id` is one of the source's.
        func holds(_ id: Int64) -> Bool {
            large?.contains(id) ?? (items[id] != nil)
        }

        /// The source's photos as `update` leaves them, reading the rows of those new or changed. Once an update
        /// has been taken whole, the next is taken from the photos its diff names alone: those that came, went or
        /// changed, and any whose row wasn't read before. A reset is taken by looking at every photo. A large
        /// source's rows aren't read: the photos the update changed are noted, for the main thread's rows of them
        /// to be read again.
        mutating func take(_ update: PhotoListUpdate, index: LibraryIndex) async throws {
            let list = update.list
            let ids = Array(list.ids)
            let diff = update.diff
            let named = diff.reset ? []
                : diff.inserted.map { list[$0] } + diff.updated.map { list[$0] } + diff.moved.map { list[$0.to] }
            guard list.count <= largestRead else {
                return takeLarge(list, ids: ids, changed: diff.reset ? nil : named)
            }
            if large != nil {
                large = nil
                handed = nil
                changedSinceHanded = []
            }
            let stepped = inStep && !diff.reset && (diff.removed.last ?? -1) < self.ids.count
            inStep = false
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
            }
            for photo in read.parts.joined() {
                keep(photo, fresh: fresh)
            }
            if fresh {
                for part in read.parts {
                    paths.insert(part)
                }
            }
            if !stepped, !fresh {
                let kept = Set(ids)
                leaving = items.keys.filter { !kept.contains($0) }
            }
            for id in leaving {
                guard let item = items.removeValue(forKey: id) else { continue }
                forget(id, at: item.url)
                touched.insert(id)
            }
            unread = count == reading.count ? [] : reading.filter { items[$0] == nil }
            self.ids = ids
            hasList = true
            inStep = true
        }

        /// A large list's photos as `list` has them, in an order of its own (`LibraryFolderList.Large`), `changed`
        /// naming those whose rows changed (nil when any may have): it stays large, whatever its count.
        mutating func take(large list: PhotoList, changed: [Int64]?) {
            takeLarge(list, ids: Array(list.ids), changed: changed)
        }

        /// A large source's photos as `list` has them, `changed` naming those whose rows it changed (nil when any
        /// may have). The rows kept from before the source was large go to the main thread with the next change.
        private mutating func takeLarge(_ list: PhotoList, ids: [Int64], changed: [Int64]?) {
            if large == nil, !items.isEmpty {
                var kept = Rows()
                for (id, item) in items where list.contains(id) {
                    kept.items[id] = item
                    kept.keys[id] = keys[id]
                }
                kept.paths = paths
                leftover = kept
            }
            if let changed {
                changedSinceHanded?.formUnion(changed)
            } else {
                changedSinceHanded = nil
            }
            large = list
            self.ids = ids
            hasList = true
            inStep = false
            items = [:]
            keys = [:]
            paths = PhotoPaths()
            touched = []
            unread = []
        }

        /// Keeps `photo` as it was read; when none of the source's photos were kept before (`fresh`), without looking
        /// for what it was.
        private mutating func keep(_ photo: Read, fresh: Bool) {
            if fresh {
                items[photo.id] = photo.item
                // Photos not handed over before differ from none handed over.
                if handed != nil {
                    touched.insert(photo.id)
                }
                keys[photo.id] = photo.key
                return
            }
            let old = items[photo.id]?.url
            if old != photo.item.url {
                if let old {
                    paths.remove(at: old)
                }
                paths.insert(photo.id, folder: photo.item.folderPath, name: photo.name)
            }
            if items[photo.id] != photo.item {
                items[photo.id] = photo.item
                touched.insert(photo.id)
            }
            // Written only when they differ: the main thread holds the last change's, which a write copies.
            if keys[photo.id] != photo.key {
                keys[photo.id] = photo.key
            }
        }

        private mutating func forget(_ id: Int64, at url: URL) {
            keys.removeValue(forKey: id)
            paths.remove(at: url)
        }

        /// The change handing over the photos `ids` names, in its order, as `source`'s list, against those handed
        /// over before; `whole` when they're the source's photos in its own order.
        mutating func change(handing ids: [Int64], of source: PhotoSource, whole: Bool = false) -> Change {
            if let large {
                return change(handing: ids, of: source, from: large, whole: whole)
            }
            let before = handed
            var shown: [LibraryItem] = []
            shown.reserveCapacity(ids.count)
            var listed = ContiguousArray<Int64>()
            listed.reserveCapacity(ids.count)
            var updated = IndexSet()
            var carried = IndexSet()
            var inserted = IndexSet()
            var inOrder = true
            var lastCarried = -1
            for id in ids {
                guard let item = items[id] else { continue }
                let index = shown.count
                if let place = before?.index(of: id) {
                    carried.insert(place)
                    inOrder = inOrder && place > lastCarried
                    lastCarried = place
                    if touched.contains(id) {
                        updated.insert(index)
                    }
                } else {
                    inserted.insert(index)
                }
                shown.append(item)
                listed.append(id)
            }
            let list = PhotoList(source: source, ids: listed)
            var change = Change(
                list: list, items: shown, previousCount: before?.count ?? -1, diff: LibraryDiff(reset: true),
                keys: keys, paths: paths, total: self.ids.count,
            )
            if let before, inOrder {
                let removed = IndexSet(integersIn: 0 ..< before.count).subtracting(carried)
                if removed.count + inserted.count <= LibrarySourceList.largestDiff {
                    change.diff = LibraryDiff(removed: removed, inserted: inserted, updated: updated)
                }
            }
            handed = list
            touched = []
            return change
        }

        /// A large source's change: its list, `large` itself when it hands over the source's photos `whole`, with
        /// no rows but those kept from before it was large; row by row when it keeps the photos' order and changes
        /// few, the photos whose rows changed updated.
        private mutating func change(
            handing ids: [Int64], of source: PhotoSource, from large: PhotoList, whole: Bool,
        ) -> Change {
            let before = handed
            let list = whole ? large : PhotoList(source: source, ids: ContiguousArray(ids))
            var change = Change(
                list: list, items: [], read: leftover?.items ?? [:], previousCount: before?.count ?? -1,
                diff: LibraryDiff(reset: true), keys: leftover?.keys ?? [:], paths: leftover?.paths ?? PhotoPaths(),
                total: self.ids.count,
            )
            if let before, let changed = changedSinceHanded,
               abs(list.count - before.count) <= LibrarySourceList.largestDiff,
               let diff = Self.diff(from: before, to: list, changed: changed) {
                change.diff = diff
            }
            rereading = changedSinceHanded
            changedSinceHanded = []
            leftover = nil
            handed = list
            return change
        }

        /// The rows `list` removes, inserts and updates from `before`, `changed` naming the photos whose rows
        /// changed; nil when the photos that stay move, or it removes and inserts too many to hand over row by row.
        static func diff(from before: PhotoList, to list: PhotoList, changed: Set<Int64>) -> LibraryDiff? {
            var carried = IndexSet()
            var inserted = IndexSet()
            var updated = IndexSet()
            var lastCarried = -1
            for (index, id) in list.ids.enumerated() {
                guard let place = before.index(of: id) else {
                    inserted.insert(index)
                    guard inserted.count <= LibrarySourceList.largestDiff else { return nil }
                    continue
                }
                guard place > lastCarried else { return nil }
                carried.insert(place)
                lastCarried = place
                if changed.contains(id) {
                    updated.insert(index)
                }
            }
            let removed = IndexSet(integersIn: 0 ..< before.count).subtracting(carried)
            guard removed.count + inserted.count <= LibrarySourceList.largestDiff else { return nil }
            return LibraryDiff(removed: removed, inserted: inserted, updated: updated)
        }
    }
}

extension LibrarySourceList {
    /// A photo of the source as the grid shows it, at its folder, its name and its content key, as its row is
    /// read.
    struct Read: Sendable {
        var id: Int64
        var item: LibraryItem
        var name: String
        var key: ContentKey?
    }
}

/// The photos of a source by their folders and names, to find one from its URL: a table keyed by every photo's URL
/// took seconds to make at a million photos, where this hashes a folder's path once for each run of its photos.
struct PhotoPaths: Sendable {
    /// Each folder's photos by name, by the folder's path as the index keeps it.
    private var folders: [String: [String: Int64]] = [:]

    /// The photo at `url`, as the source's list makes its URL from its folder and its name.
    func id(of url: URL) -> Int64? {
        let (folder, name) = Self.split(url.path)
        return folders[folder]?[name]
    }

    mutating func insert(_ id: Int64, folder: String, name: String) {
        folders[folder, default: [:]][name] = id
    }

    /// Adds `photos`, read a run of one folder's at a time.
    mutating func insert(_ photos: some Sequence<LibrarySourceList.Read>) {
        var folder: String?
        var names: [String: Int64] = [:]
        for photo in photos {
            if photo.item.folderPath != folder {
                if let folder {
                    folders[folder] = names
                }
                folder = photo.item.folderPath
                names = folders.removeValue(forKey: photo.item.folderPath) ?? [:]
            }
            names[photo.name] = photo.id
        }
        if let folder {
            folders[folder] = names
        }
    }

    mutating func remove(at url: URL) {
        let (folder, name) = Self.split(url.path)
        guard folders[folder]?.removeValue(forKey: name) != nil, folders[folder]?.isEmpty == true else { return }
        folders[folder] = nil
    }

    /// Adds `other`'s photos, which take the place of any at their paths.
    mutating func merge(_ other: PhotoPaths) {
        for (folder, names) in other.folders {
            folders[folder, default: [:]].merge(names) { _, new in new }
        }
    }

    /// Whether it holds no photo.
    var isEmpty: Bool {
        folders.isEmpty
    }

    /// A photo's path as its folder's and its name; `/` for a photo at the top of its disk.
    private static func split(_ path: String) -> (folder: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        let folder = slash == path.startIndex ? "/" : String(path[..<slash])
        return (folder, String(path[path.index(after: slash)...]))
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
                try Self.addRenderedEdits(to: &photos, from: reader)
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
                try Self.addRenderedEdits(to: &found, from: reader)
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

    /// Gives each edited photo of `photos` the edit whose render the store holds, as the index records it for its
    /// sidecar as it is (LIB-17): read in the transaction that read their rows.
    private static func addRenderedEdits(to photos: inout [LibrarySourceList.Read], from reader: some IndexQueries)
        throws {
        let edited = photos.indices.filter { photos[$0].item.hasEdits }
        guard !edited.isEmpty else { return }
        let edits = try reader.standingPhotoEdits(
            ofPhotos: edited.map { photos[$0].id },
            renderer: EditRenders.renderer,
        )
        for index in edited {
            photos[index].item.renderedEdit = edits[photos[index].id]
        }
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
            id: photo.id, item: LibraryFolderList.Mapping.item(photo, url: url, folder: folder), name: photo.name,
            key: photo.contentKey.flatMap(ContentKey.init(data:)),
        )
    }
}
