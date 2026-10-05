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
    }

    let folder: URL
    let includesSubfolders: Bool
    private let state = Mutex<(task: Task<Void, Never>?, updates: PhotoListUpdates?, closed: Bool)>((nil, nil, false))

    /// The list opens once LibraryLive has applied the changes it has gathered, so it holds every
    /// photo indexed so far.
    init(
        core: LibraryCore, folder: URL, includingSubfolders: Bool,
        deliver: @escaping @MainActor @Sendable (Change) -> Void,
    ) {
        self.folder = folder
        includesSubfolders = includingSubfolders
        let (live, index) = (core.live, core.index)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await live.settle()
            let updates = live.open(.folder(folder, includingSubfolders: includingSubfolders), sort: QuerySort(.name))
            guard let self, state.withLock({ state in
                state.updates = updates
                return !state.closed
            }) else { return updates.close() }
            var mapping = Mapping(folder: folder, includesSubfolders: includingSubfolders)
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

    /// What maps one list's updates to changes: the IDs shown, and their folders' paths.
    struct Mapping: Sendable {
        let folder: URL
        /// The folder's path as the index keeps it.
        let path: String
        let includesSubfolders: Bool
        private var previous: PhotoList?
        private var shown: [Int64: URL] = [:]
        private var folders: [Int64: String] = [:]

        init(folder: URL, includesSubfolders: Bool) {
            self.folder = folder
            path = LibraryService.path(folder)
            self.includesSubfolders = includesSubfolders
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
            }
            let rows = Dictionary(read.0.map { ($0.id, $0) }) { first, _ in first }
            for id in changed {
                let before = shown[id]
                guard let row = rows[id], let item = item(row) else {
                    if let before {
                        shown[id] = nil
                        change.removed.append(before)
                    }
                    continue
                }
                if let key = row.contentKey.flatMap(ContentKey.init(data:)) {
                    change.keys[item.url] = key
                }
                shown[id] = item.url
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
            guard let (rows, folders) = read ?? nil else { return Change(all: ([], [:])) }
            self.folders = folders
            shown = [:]
            var change = Change()
            var items: [LibraryItem] = []
            items.reserveCapacity(list.count)
            for row in rows where list.contains(row.id) {
                guard let item = item(row) else { continue }
                shown[row.id] = item.url
                if let key = row.contentKey.flatMap(ContentKey.init(data:)) {
                    change.keys[item.url] = key
                }
                items.append(item)
            }
            items = Self.ordered(items)
            var positions: [URL: Int] = [:]
            positions.reserveCapacity(items.count)
            for (index, item) in items.enumerated() where positions[item.url] == nil {
                positions[item.url] = index
            }
            change.all = (items, positions)
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
