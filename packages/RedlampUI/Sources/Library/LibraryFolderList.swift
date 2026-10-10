import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

/// A folder's photos from the library, for the filmstrip (LIB-10): the photo list of the folder,
/// alone or with every folder below it, as `LibraryItem`s in the order Folders lists them (a
/// folder's photos by name, then each subfolder's), kept current by `LibraryLive`, whose diffs
/// become the photos removed, inserted and changed. The rows come from the index off the main
/// thread; only the changes reach it, each once the one before has: what changes meanwhile comes
/// as one change, so a culling batch's thousands of rows take a few turns of the main thread.
///
/// With a filter or a sort (LIB-18) it hands over the photos the filter finds, in the sort's order,
/// each time the filter or the folder's photos change: worked out off the main thread from the
/// folder's photos it already has, the latest filter winning, with each photo's place in the list
/// handed over before, so the main thread only takes the list.
///
/// A photo's badges are its `.redlamp` sidecar's, as Folders shows them: a photo without one shows
/// none, whatever other apps' metadata says.
final class LibraryFolderList: Sendable {
    /// How the photos changed since the last change delivered.
    struct Change: Sendable {
        /// Every photo, in order, each one's index, and their IDs in the index: the first change.
        var all: (items: [LibraryItem], positions: [URL: Int], ids: ContiguousArray<Int64>)?
        var removed: [URL] = []
        var inserted: [LibraryItem] = []
        /// Photos still shown under the same URL whose row changed.
        var updated: [LibraryItem] = []
        /// The index's IDs of the photos `inserted` and `updated`, by URL.
        var ids: [URL: Int64] = [:]
        /// The content keys of the photos in `all` and `inserted` that have one, and of those in `updated` whose
        /// key changed.
        var keys: [URL: ContentKey] = [:]
        /// The filtered or sorted list, which replaces every photo shown.
        var ordered: Ordered?
        /// A large folder's photos' IDs in Folders' order, filtered or not, with the rows read for them, as a large
        /// source's change has them (`Large`); nothing else is set.
        var large: LibrarySourceList.Change?
    }

    /// A filtered or sorted list in its order, and how it differs from the list handed over before.
    struct Ordered: Sendable {
        var items: [LibraryItem]
        var positions: [URL: Int]
        /// The photos' IDs in the index, in the list's order.
        var ids: ContiguousArray<Int64>
        /// Each photo's place in the list handed over before; -1 for a photo that list didn't have.
        var previous: [Int32]
        /// How many photos the list handed over before had; -1 when there was none.
        var previousCount: Int
        /// The rows removed, inserted and changed, or a reset when the photos that stayed moved.
        var diff: LibraryDiff
        /// The content keys of every photo of the folder that has one, filtered or not, by URL.
        var keys: [URL: ContentKey]
        /// The folder's photos, filtered or not.
        var total: Int
        /// The filter it was made with.
        var filter: LibraryListFilter
        /// How long the query engine took to find its photos, and the list to be made of them.
        var took: (query: Duration, list: Duration) = (.zero, .zero)
    }

    let folder: URL
    let includesSubfolders: Bool
    /// Folders with more photos than this are large (`Large`).
    let largestRead: Int
    /// A large folder's rows, read as they're asked for.
    let largeRows: LargeListRows
    private let live: LibraryLive
    private let state = Mutex(State())

    private struct State {
        var task: Task<Void, Never>?
        var updates: PhotoListUpdates?
        var closed = false
        var filter = LibraryListFilter()
        var events: AsyncStream<Event>.Continuation?
        /// LibraryLive's updates taken and handed over, each once its change reached the main thread.
        var handedOver = 0
    }

    /// What each change waits for before it's handed to the main thread: nothing, but in tests that hold the list
    /// back as a busy index does.
    let holding = Mutex<(@Sendable () async -> Void)?>(nil)

    private enum Event: Sendable {
        case update(PhotoListUpdate)
        case filter

        var isUpdate: Bool {
            if case .update = self {
                true
            } else {
                false
            }
        }
    }

    /// The source the list shows, as the query engine knows it.
    var source: PhotoSource {
        .folder(folder, includingSubfolders: includesSubfolders)
    }

    /// The list opens once LibraryLive has applied the changes it has gathered, so it holds every
    /// photo indexed so far. A large folder's first change brings the rows of its first `firstRead` photos and of
    /// those at `wanted` (the view's active, selected and top photos).
    init(
        core: LibraryCore, folder: URL, includingSubfolders: Bool, filter: LibraryListFilter = LibraryListFilter(),
        largestRead: Int = LibrarySourceList.largestRead, firstRead: Int = LibrarySourceList.firstRead,
        wanted: [URL] = [], deliver: @escaping @MainActor @Sendable (Change) -> Void,
    ) {
        self.folder = folder
        includesSubfolders = includingSubfolders
        self.largestRead = largestRead
        let rows = LargeListRows(index: core.index, firstRead: firstRead)
        largeRows = rows
        let (live, index, engine) = (core.live, core.index, core.engine)
        self.live = live
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        state.withLock { state in
            state.filter = filter
            state.events = continuation
        }
        let source = PhotoSource.folder(folder, includingSubfolders: includingSubfolders)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await live.settle()
            let updates = live.open(source, sort: QuerySort(.name))
            guard let self, state.withLock({ state in
                state.updates = updates
                return !state.closed
            }) else { return updates.close() }
            // An update is taken only once the one before it has reached the main thread: LibraryLive makes
            // one update of what changes meanwhile, so a burst (a culling batch's rows) arrives as a few.
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
            var mapping = Mapping(folder: folder, includesSubfolders: includingSubfolders)
            var handed = Handed()
            var large: Large?
            let handOver: (Change) async -> Void = { change in
                if let hold = self.holding.withLock({ $0 }) {
                    await hold()
                }
                await deliver(change)
            }
            for await event in events {
                let filter = state.withLock { $0.filter }
                let update: PhotoListUpdate? = if case let .update(update) = event {
                    update
                } else {
                    nil
                }
                if large == nil, !mapping.hasList, let update, update.list.count > largestRead {
                    large = Large(
                        folder: folder, includesSubfolders: includingSubfolders, core: core, rows: rows, wanted: wanted,
                    )
                }
                if var taking = large {
                    let change = try? await taking.change(taking: update, filter: filter)
                    large = taking
                    if let change {
                        await handOver(Change(large: change))
                    }
                } else {
                    if !filter.isEmpty, !handed.isOrdered, mapping.hasList {
                        handed.takeOver(&mapping)
                    }
                    let orders: Bool
                    if let update {
                        let change = try? await mapping.change(for: update, index: index)
                        if let change, filter.isEmpty, !handed.isOrdered {
                            handed.filter = filter
                            await handOver(change)
                            orders = false
                        } else {
                            orders = change != nil
                        }
                    } else {
                        orders = mapping.hasList && filter != handed.filter
                    }
                    if orders, let ordered = try? await handed.next(
                        filter, from: &mapping, engine: engine, source: source, changed: event.isUpdate,
                    ) {
                        await handOver(Change(ordered: ordered))
                    }
                }
                if event.isUpdate {
                    state.withLock { $0.handedOver += 1 }
                    handing.yield()
                }
            }
        }
        state.withLock { $0.task = task }
    }

    /// Returns once the list has handed over every change the library had for its photos when it was called: what
    /// LibraryLive has gathered is applied, and each update that makes for the list has reached the main thread,
    /// however long the index takes to read their rows. At once once the list is closed.
    func caughtUp() async {
        await live.settle()
        var wanted = Int.max
        while true {
            let (closed, updates, handedOver) = state.withLock { ($0.closed, $0.updates, $0.handedOver) }
            // Before the list opens, its first update; one waiting can give way to none, the list having changed
            // back before it was taken.
            wanted = min(wanted, updates?.handed ?? 1)
            if closed || handedOver >= wanted {
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
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
}

extension LibraryFolderList {
    /// What maps one list's updates to changes: the IDs shown, and their folders' paths.
    struct Mapping: Sendable {
        let folder: URL
        /// The folder's path as the index keeps it.
        let path: String
        let includesSubfolders: Bool
        private var previous: PhotoList?
        private var shown: [Int64: URL] = [:]
        private var folders: [Int64: String] = [:]
        /// Every photo of the folder, filtered or not, and their content keys, by ID.
        private(set) var items: [Int64: LibraryItem] = [:]
        private(set) var keys: [Int64: ContentKey] = [:]
        /// The content keys by URL, for every filtered list to hand over whole: merging a list's thousands on
        /// the main thread took milliseconds a key typed.
        private(set) var urlKeys: [URL: ContentKey] = [:]
        /// The photos changed or gone since the last filtered list was made (`untouch`), or all of them: only
        /// those can differ from that list's.
        private(set) var touched = Set<Int64>()
        private(set) var touchedAll = true
        /// The photos' IDs in Folders' order, until photos come, go or move.
        private var order: [Int64]?

        init(folder: URL, includesSubfolders: Bool) {
            self.folder = folder
            path = LibraryService.path(folder)
            self.includesSubfolders = includesSubfolders
        }

        /// Whether the list's first update is in.
        var hasList: Bool {
            previous != nil
        }

        /// Every photo's ID in Folders' order.
        mutating func walkOrder() -> [Int64] {
            if let order {
                return order
            }
            let ids = items.keys.sorted()
            let ordered = Self.ordered(ids.compactMap { items[$0] })
            let byURL = Dictionary(ids.compactMap { id in items[id].map { ($0.url, id) } }) { first, _ in first }
            let made = ordered.compactMap { byURL[$0.url] }
            order = made
            return made
        }

        /// The change `update` makes to the photos shown, reading their rows from `index`.
        mutating func change(for update: PhotoListUpdate, index: LibraryIndex) async throws -> Change? {
            defer { previous = update.list }
            guard let previous, !update.diff.reset else {
                return try await everything(in: update.list, index: index)
            }
            let diff = update.diff
            let removed = diff.removed.map { previous[$0] }
            let changed = diff.inserted.map { update.list[$0] } + diff.moved.map { update.list[$0.to] }
                + diff.updated.map { update.list[$0] }
            let known = folders
            let read = try await index.read { reader in
                var rows: [PhotoRecord] = []
                var folders: [Int64: String] = [:]
                for id in changed {
                    guard let row = try reader.photo(id: id) else { continue }
                    rows.append(row)
                    if known[row.folder] == nil, folders[row.folder] == nil {
                        folders[row.folder] = try reader.folder(id: row.folder)?.path
                    }
                }
                return (rows, folders)
            }
            folders.merge(read.1) { _, new in new }
            var change = Change()
            var moved = !removed.isEmpty
            touched.formUnion(removed)
            touched.formUnion(changed)
            for id in removed {
                if let url = shown.removeValue(forKey: id) {
                    change.removed.append(url)
                }
                forget(id)
            }
            let rows = Dictionary(read.0.map { ($0.id, $0) }) { first, _ in first }
            for id in changed {
                let before = shown[id]
                guard let row = rows[id], let item = item(row) else {
                    if let before {
                        shown[id] = nil
                        change.removed.append(before)
                    }
                    forget(id)
                    moved = true
                    continue
                }
                // A photo shown under the same URL with the same content (a culling batch's thousands) sends no key.
                if let key = row.contentKey.flatMap(ContentKey.init(data:)), before != item.url || keys[id] != key {
                    change.keys[item.url] = key
                    keys[id] = key
                    urlKeys[item.url] = key
                }
                moved = moved || before.map { $0 != item.url } ?? false
                shown[id] = item.url
                change.ids[item.url] = id
                if items[id]?.url != item.url {
                    order = nil
                }
                items[id] = item
                if before == item.url {
                    change.updated.append(item)
                } else {
                    if let before {
                        change.removed.append(before)
                    }
                    change.inserted.append(item)
                }
            }
            if moved {
                urlKeys = [:]
                for (id, item) in items {
                    if let key = keys[id] {
                        urlKeys[item.url] = key
                    }
                }
            }
            return change
        }

        /// A filtered list was made of the photos as they are now.
        mutating func untouch() {
            touched = []
            touchedAll = false
        }

        private mutating func forget(_ id: Int64) {
            if items.removeValue(forKey: id) != nil {
                order = nil
            }
            keys[id] = nil
        }

        /// Every photo of `list`, from their rows, in Folders' order.
        private mutating func everything(in list: PhotoList, index: LibraryIndex) async throws -> Change? {
            let (path, includesSubfolders) = (path, includesSubfolders)
            let read = try await index.read { reader -> ([PhotoRecord], [Int64: String])? in
                guard let top = try reader.folder(path: path) else { return nil }
                guard includesSubfolders else { return try (reader.photos(inFolder: top.id), [top.id: top.path]) }
                let below = path == "/" ? "/" : path + "/"
                var folders: [Int64: String] = [:]
                for folder in try reader.folders(inRoot: top.root)
                    where folder.path == path || folder.path.hasPrefix(below) {
                    folders[folder.id] = folder.path
                }
                return try (reader.photos(inSubtreeOf: top.id), folders)
            }
            items = [:]
            keys = [:]
            order = nil
            touchedAll = true
            guard let (rows, folders) = read ?? nil else { return Change(all: ([], [:], [])) }
            self.folders = folders
            shown = [:]
            var change = Change()
            var listed: [LibraryItem] = []
            listed.reserveCapacity(list.count)
            var ids: [URL: Int64] = [:]
            for row in rows where list.contains(row.id) {
                guard let item = item(row) else { continue }
                shown[row.id] = item.url
                items[row.id] = item
                ids[item.url] = row.id
                if let key = row.contentKey.flatMap(ContentKey.init(data:)) {
                    change.keys[item.url] = key
                    keys[row.id] = key
                }
                listed.append(item)
            }
            listed = Self.ordered(listed)
            order = listed.compactMap { ids[$0.url] }
            urlKeys = change.keys
            var positions: [URL: Int] = [:]
            positions.reserveCapacity(listed.count)
            for (index, item) in listed.enumerated() where positions[item.url] == nil {
                positions[item.url] = index
            }
            change.all = (listed, positions, ContiguousArray(order ?? []))
            return change
        }

        /// The photo of `row` as Folders shows it, under the folder's URL; nil for a photo outside it.
        func item(_ row: PhotoRecord) -> LibraryItem? {
            guard let directory = folders[row.folder] else { return nil }
            let relative: String
            if directory == path {
                relative = row.name
            } else {
                let below = path == "/" ? "/" : path + "/"
                guard includesSubfolders, directory.hasPrefix(below) else { return nil }
                relative = String(directory.dropFirst(below.count)) + "/" + row.name
            }
            return Self.item(row, url: folder.appending(path: relative, directoryHint: .notDirectory))
        }

        /// `row` as an item at `url`: its badges are its sidecar's, or, before it has one, those Redlamp gave
        /// it ahead of writing one (a culling batch's), never other apps'.
        static func item(_ row: PhotoRecord, url: URL) -> LibraryItem {
            item(row, url: url, folder: url.deletingLastPathComponent().path)
        }

        /// `row` as an item at `url`, in the folder at the path `folder`, as `item(_:url:)` has it.
        static func item(_ row: PhotoRecord, url: URL, folder: String) -> LibraryItem {
            let hasSidecar = row.sidecarModified != nil
            var item = LibraryItem(
                PhotoEntry(
                    url: url, size: row.size, modified: row.modified, hasSidecar: hasSidecar,
                    sidecarModified: row.sidecarModified,
                ),
                folderPath: folder,
            )
            if hasSidecar {
                item.hasEdits = row.edited
            }
            item.metadata = metadata(
                rating: row.rating, flag: row.flag, label: row.label, customLabel: row.customLabel, marked: row.marked,
                otherFields: row.otherFields, hasSidecar: hasSidecar,
            )
            return item
        }

        /// The badges `item(_:url:)` shows of a photo the index has with these fields: other apps' (`otherFields`)
        /// left out until it has a sidecar.
        static func metadata(
            rating: Int, flag: PhotoFlag?, label: ColorLabel?, customLabel: String?, marked: Bool,
            otherFields: Set<XMPField>, hasSidecar: Bool,
        ) -> PhotoMetadata {
            let theirs = hasSidecar ? [] : otherFields
            return PhotoMetadata(
                rating: theirs.contains(.rating) ? 0 : rating, flag: theirs.contains(.flag) ? nil : flag,
                label: theirs.contains(.label) ? nil : label, customLabel: theirs.contains(.label) ? nil : customLabel,
                mark: marked,
            )
        }

        /// `items` in Folders' order: each folder's photos by name, a folder before its subfolders,
        /// subfolders in Finder's order (`LibraryItem.walkPrecedes`), each folder ranked once.
        static func ordered(_ items: [LibraryItem]) -> [LibraryItem] {
            let folders = Set(items.map(\.folderPath)).sorted(by: foldersPrecede)
            let ranks = Dictionary(folders.enumerated().map { ($1, $0) }) { first, _ in first }
            let names = items.map(\.name)
            let order = items.indices.map { (rank: ranks[items[$0].folderPath] ?? 0, index: $0) }
                .sorted { lhs, rhs in
                    lhs.rank != rhs.rank ? lhs.rank < rhs.rank : FileOrder.precedes(names[lhs.index], names[rhs.index])
                }
            return order.map { items[$0.index] }
        }

        /// Whether the folder at the path `lhs` comes before the one at `rhs` in Folders' order: a folder before its
        /// subfolders, each level in Finder's order.
        static func foldersPrecede(_ lhs: String, _ rhs: String) -> Bool {
            let left = lhs.split(separator: "/")
            let right = rhs.split(separator: "/")
            for (x, y) in zip(left, right) where x != y {
                return FileOrder.precedes(String(x), String(y))
            }
            return left.count < right.count
        }
    }
}

private extension LibraryFolderList {
    /// The filtered list handed over last, which the next is worked out against.
    struct Handed {
        var items: [LibraryItem] = []
        var places: [Int64: Int32] = [:]
        /// The IDs of the last list made, in its order, and each photo's index; nil for a list taken over.
        var listed: (ids: [Int64], positions: [URL: Int])?
        /// The filter of the last list handed over; nil before the first.
        var filter: LibraryListFilter?
        /// The last change handed over was a filtered or sorted list.
        var isOrdered = false

        /// Changes this small that keep the photos' order are handed over row by row; larger ones reset,
        /// which the filmstrip and the grid take faster than as many rows.
        static let largestDiff = 32

        /// The folder's photos in Folders' order, as the changes handed over so far have left them.
        mutating func takeOver(_ mapping: inout Mapping) {
            let ids = mapping.walkOrder()
            items = ids.compactMap { mapping.items[$0] }
            places = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, Int32($0)) })
            listed = nil
            mapping.untouch()
        }

        /// The list `filter` makes of `mapping`'s photos, against the list handed over before; `changed` when
        /// the photos have changed since it was made.
        mutating func next(
            _ filter: LibraryListFilter, from mapping: inout Mapping, engine: QueryEngine, source: PhotoSource,
            changed: Bool,
        ) async throws -> Ordered {
            let clock = ContinuousClock()
            let started = clock.now
            var queried = Duration.zero
            var ids: [Int64]
            if filter.query == nil, filter.sort == nil {
                ids = mapping.walkOrder()
            } else {
                let list = try await engine.list(
                    source, matching: filter.query ?? .all, sort: filter.sort ?? QuerySort(.name),
                    moments: filter.moments,
                )
                queried = clock.now - started
                ids = filter.sort == nil ? mapping.walkOrder().filter(list.contains)
                    : list.ids.filter { mapping.items[$0] != nil }
            }
            if filter.reversed {
                ids.reverse()
            }
            let first = self.filter == nil
            let (touched, touchedAll) = (mapping.touched, mapping.touchedAll)
            mapping.untouch()
            // The photos the last list found, in its order and unchanged: that list again, at once at any count.
            if !first, !changed, let listed, listed.ids == ids {
                self.filter = filter
                isOrdered = !filter.isEmpty
                var ordered = Ordered(
                    items: self.items, positions: listed.positions, ids: ContiguousArray(listed.ids),
                    previous: Array(0 ..< Int32(self.items.count)),
                    previousCount: self.items.count, diff: LibraryDiff(), keys: mapping.urlKeys,
                    total: mapping.items.count,
                    filter: filter,
                )
                ordered.took = (queried, clock.now - started - queried)
                return ordered
            }
            var items: [LibraryItem] = []
            items.reserveCapacity(ids.count)
            var listedIDs: [Int64] = []
            listedIDs.reserveCapacity(ids.count)
            var positions: [URL: Int] = [:]
            positions.reserveCapacity(ids.count)
            var previous: [Int32] = []
            previous.reserveCapacity(ids.count)
            var places: [Int64: Int32] = [:]
            places.reserveCapacity(ids.count)
            var updated = IndexSet()
            var carried = IndexSet()
            var inOrder = true
            var lastCarried: Int32 = -1
            for id in ids {
                guard let item = mapping.items[id] else { continue }
                let index = items.count
                // A URL listed twice keeps its first place.
                if let earlier = positions.updateValue(index, forKey: item.url) {
                    positions[item.url] = earlier
                    continue
                }
                let before = first ? -1 : self.places[id] ?? -1
                if before >= 0 {
                    carried.insert(Int(before))
                    inOrder = inOrder && before > lastCarried
                    lastCarried = before
                    if touchedAll || touched.contains(id), self.items[Int(before)] != item {
                        updated.insert(index)
                    }
                }
                items.append(item)
                listedIDs.append(id)
                previous.append(before)
                places[id] = Int32(index)
            }
            let removed = IndexSet(integersIn: 0 ..< self.items.count).subtracting(carried)
            let inserted = IndexSet(previous.indices.filter { previous[$0] < 0 })
            let diff = !first && inOrder && removed.count + inserted.count <= Self.largestDiff
                ? LibraryDiff(removed: removed, inserted: inserted, updated: updated) : LibraryDiff(reset: true)
            var ordered = Ordered(
                items: items, positions: positions, ids: ContiguousArray(listedIDs), previous: previous,
                previousCount: first ? -1 : self.items.count,
                diff: diff, keys: mapping.urlKeys, total: mapping.items.count, filter: filter,
            )
            ordered.took = (queried, clock.now - started - queried)
            self.items = items
            self.places = places
            listed = (listedIDs, positions)
            self.filter = filter
            isOrdered = !filter.isEmpty
            return ordered
        }
    }
}
