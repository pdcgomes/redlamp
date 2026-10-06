import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

/// A folder's photos from the library, for the filmstrip (LIB-10): the photo list of the folder,
/// alone or with every folder below it, as `LibraryItem`s in the order Folders lists them (a
/// folder's photos by name, then each subfolder's), kept current by `LibraryLive`, whose diffs
/// become the photos removed, inserted and changed. The rows come from the index off the main
/// thread; only the changes reach it.
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
        /// Every photo, in order, and each one's index: the first change.
        var all: (items: [LibraryItem], positions: [URL: Int])?
        var removed: [URL] = []
        var inserted: [LibraryItem] = []
        /// Photos still shown under the same URL whose row changed.
        var updated: [LibraryItem] = []
        /// The content keys of the photos in `all`, `inserted` and `updated` that have one.
        var keys: [URL: ContentKey] = [:]
        /// The filtered or sorted list, which replaces every photo shown.
        var ordered: Ordered?
    }

    /// A filtered or sorted list in its order, and how it differs from the list handed over before.
    struct Ordered: Sendable {
        var items: [LibraryItem]
        var positions: [URL: Int]
        /// Each photo's place in the list handed over before; -1 for a photo that list didn't have.
        var previous: [Int32]
        /// How many photos the list handed over before had; -1 when there was none.
        var previousCount: Int
        /// The rows removed, inserted and changed, or a reset when the photos that stayed moved.
        var diff: LibraryDiff
        /// The content keys of the photos the list handed over before didn't have.
        var keys: [URL: ContentKey]
        /// The folder's photos, filtered or not.
        var total: Int
        /// The filter it was made with.
        var filter: LibraryListFilter
    }

    let folder: URL
    let includesSubfolders: Bool
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

    /// The source the list shows, as the query engine knows it.
    var source: PhotoSource {
        .folder(folder, includingSubfolders: includesSubfolders)
    }

    /// The list opens once LibraryLive has applied the changes it has gathered, so it holds every
    /// photo indexed so far.
    init(
        core: LibraryCore, folder: URL, includingSubfolders: Bool, filter: LibraryListFilter = LibraryListFilter(),
        deliver: @escaping @MainActor @Sendable (Change) -> Void,
    ) {
        self.folder = folder
        includesSubfolders = includingSubfolders
        let (live, index, engine) = (core.live, core.index, core.engine)
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
            let forwarding = Task {
                for await update in updates {
                    continuation.yield(.update(update))
                }
                continuation.finish()
            }
            defer { forwarding.cancel() }
            var mapping = Mapping(folder: folder, includesSubfolders: includingSubfolders)
            var handed = Handed()
            for await event in events {
                let filter = state.withLock { $0.filter }
                if !filter.isEmpty, !handed.isOrdered, mapping.hasList {
                    handed.takeOver(&mapping)
                }
                switch event {
                case let .update(update):
                    guard let change = try? await mapping.change(for: update, index: index) else { continue }
                    if filter.isEmpty, !handed.isOrdered {
                        handed.filter = filter
                        await deliver(change)
                        continue
                    }
                case .filter:
                    guard mapping.hasList, filter != handed.filter else { continue }
                }
                guard let ordered = try? await handed.next(filter, from: &mapping, engine: engine, source: source)
                else { continue }
                await deliver(Change(ordered: ordered))
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
                    continue
                }
                if let key = row.contentKey.flatMap(ContentKey.init(data:)) {
                    change.keys[item.url] = key
                    keys[id] = key
                }
                shown[id] = item.url
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
            return change
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
            guard let (rows, folders) = read ?? nil else { return Change(all: ([], [:])) }
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
            var positions: [URL: Int] = [:]
            positions.reserveCapacity(listed.count)
            for (index, item) in listed.enumerated() where positions[item.url] == nil {
                positions[item.url] = index
            }
            change.all = (listed, positions)
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

        /// `row` as an item at `url`: its badges only when it has a sidecar.
        static func item(_ row: PhotoRecord, url: URL) -> LibraryItem {
            let hasSidecar = row.sidecarModified != nil
            var item = LibraryItem(
                PhotoEntry(
                    url: url, size: row.size, modified: row.modified, hasSidecar: hasSidecar,
                    sidecarModified: row.sidecarModified,
                ),
                folderPath: url.deletingLastPathComponent().path,
            )
            if hasSidecar {
                item.hasEdits = row.edited
                item.metadata = PhotoMetadata(rating: row.rating, flag: row.flag, label: row.label)
            }
            return item
        }

        /// `items` in Folders' order: each folder's photos by name, a folder before its subfolders,
        /// subfolders in Finder's order (`LibraryItem.walkPrecedes`), each folder ranked once.
        static func ordered(_ items: [LibraryItem]) -> [LibraryItem] {
            let folders = Set(items.map(\.folderPath)).sorted { lhs, rhs in
                let left = lhs.split(separator: "/")
                let right = rhs.split(separator: "/")
                for (x, y) in zip(left, right) where x != y {
                    return FileOrder.precedes(String(x), String(y))
                }
                return left.count < right.count
            }
            let ranks = Dictionary(folders.enumerated().map { ($1, $0) }) { first, _ in first }
            let names = items.map(\.name)
            let order = items.indices.map { (rank: ranks[items[$0].folderPath] ?? 0, index: $0) }
                .sorted { lhs, rhs in
                    lhs.rank != rhs.rank ? lhs.rank < rhs.rank : FileOrder.precedes(names[lhs.index], names[rhs.index])
                }
            return order.map { items[$0.index] }
        }
    }
}

private extension LibraryFolderList {
    /// The filtered list handed over last, which the next is worked out against.
    struct Handed {
        var items: [LibraryItem] = []
        var places: [Int64: Int32] = [:]
        /// The filter of the last list handed over; nil before the first.
        var filter: LibraryListFilter?
        /// The last change handed over was a filtered or sorted list.
        var isOrdered = false

        /// Changes this small that keep the photos' order are handed over row by row; larger ones reset.
        static let largestDiff = 256

        /// The folder's photos in Folders' order, as the changes handed over so far have left them.
        mutating func takeOver(_ mapping: inout Mapping) {
            let ids = mapping.walkOrder()
            items = ids.compactMap { mapping.items[$0] }
            places = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, Int32($0)) })
        }

        /// The list `filter` makes of `mapping`'s photos, against the list handed over before.
        mutating func next(
            _ filter: LibraryListFilter, from mapping: inout Mapping, engine: QueryEngine, source: PhotoSource,
        ) async throws -> Ordered {
            var ids: [Int64]
            if filter.query == nil, filter.sort == nil {
                ids = mapping.walkOrder()
            } else {
                let list = try await engine.list(
                    source, matching: filter.query ?? .all, sort: filter.sort ?? QuerySort(.name),
                )
                ids = filter.sort == nil ? mapping.walkOrder().filter(list.contains)
                    : list.ids.filter { mapping.items[$0] != nil }
            }
            if filter.reversed {
                ids.reverse()
            }
            let first = self.filter == nil
            var items: [LibraryItem] = []
            items.reserveCapacity(ids.count)
            var positions: [URL: Int] = [:]
            positions.reserveCapacity(ids.count)
            var previous: [Int32] = []
            previous.reserveCapacity(ids.count)
            var places: [Int64: Int32] = [:]
            places.reserveCapacity(ids.count)
            var keys: [URL: ContentKey] = [:]
            var updated = IndexSet()
            var carried = IndexSet()
            var inOrder = true
            var lastCarried: Int32 = -1
            for id in ids {
                guard let item = mapping.items[id], positions[item.url] == nil else { continue }
                let index = items.count
                let before = first ? -1 : self.places[id] ?? -1
                if before >= 0 {
                    carried.insert(Int(before))
                    inOrder = inOrder && before > lastCarried
                    lastCarried = before
                    if self.items[Int(before)] != item {
                        updated.insert(index)
                    }
                } else if let key = mapping.keys[id] {
                    keys[item.url] = key
                }
                items.append(item)
                positions[item.url] = index
                previous.append(before)
                places[id] = Int32(index)
            }
            let removed = IndexSet(integersIn: 0 ..< self.items.count).subtracting(carried)
            let inserted = IndexSet(previous.indices.filter { previous[$0] < 0 })
            let diff = !first && inOrder && removed.count + inserted.count <= Self.largestDiff
                ? LibraryDiff(removed: removed, inserted: inserted, updated: updated) : LibraryDiff(reset: true)
            let ordered = Ordered(
                items: items, positions: positions, previous: previous, previousCount: first ? -1 : self.items.count,
                diff: diff, keys: keys, total: mapping.items.count, filter: filter,
            )
            self.items = items
            self.places = places
            self.filter = filter
            isOrdered = !filter.isEmpty
            return ordered
        }
    }
}
