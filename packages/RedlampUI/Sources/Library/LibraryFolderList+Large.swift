import Foundation
import RedlampDocument
import RedlampLibrary

extension LibraryFolderList {
    /// A large folder's photos (more than `largestRead` as it opens), handed over as a large source's are
    /// (`LibrarySourceList`): their IDs in Folders' order, filtered or not, with the rows of the first screens, of the
    /// photos the view kept and of those the main thread holds that changed; the others are read as their cells
    /// appear (`largeRows`), since reading a million rows took 3 s. It stays large while it's shown, whatever it holds.
    struct Large: Sendable {
        private let source: PhotoSource
        private let index: LibraryIndex
        private let engine: QueryEngine
        private let rows: LargeListRows
        /// The photos whose rows the first change brings, with its first screens'.
        private let wanted: [URL]
        private var order: FolderOrder
        private var mapping = LibrarySourceList.Mapping()
        /// The filter of the last change handed over; nil before the first.
        private var handed: LibraryListFilter?

        init(folder: URL, includesSubfolders: Bool, core: LibraryCore, rows: LargeListRows, wanted: [URL]) {
            source = .folder(folder, includingSubfolders: includesSubfolders)
            index = core.index
            engine = core.engine
            self.rows = rows
            self.wanted = wanted
            order = FolderOrder(path: LibraryService.path(folder), includesSubfolders: includesSubfolders)
        }

        /// The change `update` makes, or the filter does when there's none, handed over as `filter` has it; nil
        /// when nothing changed.
        mutating func change(
            taking update: PhotoListUpdate?, filter: LibraryListFilter,
        ) async throws -> LibrarySourceList.Change? {
            if let update {
                let (list, changed) = try await order.ordered(update, index: index)
                mapping.take(large: list, changed: changed)
            }
            guard mapping.hasList, update != nil || filter != handed else { return nil }
            var change = try await LibrarySourceList.change(
                handing: filter, after: handed, from: &mapping, engine: engine, source: source,
            )
            try await rows.read(into: &change, changed: mapping.rereading, first: handed == nil, wanted: wanted)
            handed = filter
            return change
        }
    }

    /// The order Folders lists a large folder's photos in: each folder's together, a folder's before its subfolders'
    /// (`Mapping.foldersPrecede`), and by name in Finder's order as Folders has it (`FileOrder`), from each photo's
    /// folder and name as the index has them. LibraryLive lists them by the query engine's Finder order, which puts
    /// punctuation before digits where `FileOrder` puts digits first: DSC_5513 before DSC05507. Each folder's photos
    /// come in runs already in order, which a stable sort merges.
    struct FolderOrder: Sendable {
        let path: String
        let includesSubfolders: Bool
        /// The place of the folder and of each folder below it in Folders' order, by its ID.
        private var ranks: [Int64: Int] = [:]
        /// Each photo's folder and name, by the photo's ID.
        private var photos: [Int64: Photo] = [:]

        private struct Photo: Sendable {
            var folder: Int64
            var name: String
        }

        /// Changes of more photos than this read every photo's folder and name again, rather than theirs alone.
        static let largestRead = 20000

        init(path: String, includesSubfolders: Bool) {
            self.path = path
            self.includesSubfolders = includesSubfolders
        }

        /// `update`'s photos in Folders' order, and those whose rows it changed (nil when any may have).
        mutating func ordered(
            _ update: PhotoListUpdate, index: LibraryIndex,
        ) async throws -> (list: PhotoList, changed: [Int64]?) {
            let (list, diff) = (update.list, update.diff)
            let changed = diff.reset ? nil
                : diff.inserted.map { list[$0] } + diff.updated.map { list[$0] } + diff.moved.map { list[$0.to] }
            if let changed, !photos.isEmpty, changed.count <= Self.largestRead {
                try await read(changed, index: index)
            } else {
                try await readAll(index: index)
            }
            return (PhotoList(source: list.source, sort: list.sort, ids: walked(list.ids)), changed)
        }

        /// `ids`, in LibraryLive's order, each folder's together in Folders' order, and sorted by name as Folders sorts
        /// them, those `FileOrder` takes as the same keeping LibraryLive's order.
        private func walked(_ ids: ContiguousArray<Int64>) -> ContiguousArray<Int64> {
            var folders = [[(id: Int64, name: String)]](repeating: [], count: ranks.count + 1)
            for id in ids {
                let photo = photos[id]
                folders[photo.flatMap { ranks[$0.folder] } ?? ranks.count].append((id, photo?.name ?? ""))
            }
            var walked = ContiguousArray<Int64>()
            walked.reserveCapacity(ids.count)
            for var folder in folders {
                folder.sort { FileOrder.precedes($0.name, $1.name) }
                walked.append(contentsOf: folder.lazy.map(\.id))
            }
            return walked
        }

        /// Reads the folders and names of the photos `ids`, and every folder's place again when one is new.
        private mutating func read(_ ids: [Int64], index: LibraryIndex) async throws {
            guard !ids.isEmpty else { return }
            let found = try await index.read { reader in
                let statement = try reader.database.cached("SELECT folder, name FROM photos WHERE id = ?")
                var found: [Int64: Photo] = [:]
                for id in ids {
                    try statement.bind(id, at: 1)
                    try statement
                        .forEachRow { found[id] = Photo(folder: $0.int64(at: 0), name: $0.string(at: 1) ?? "") }
                }
                return found
            }
            photos.merge(found) { _, read in read }
            if found.values.contains(where: { ranks[$0.folder] == nil }) {
                let path = path
                ranks = try await Self.ranks(of: index.read { try Self.folders(below: path, in: $0) })
            }
        }

        /// Reads every photo's folder and name, and every folder's place.
        private mutating func readAll(index: LibraryIndex) async throws {
            let (path, includesSubfolders) = (path, includesSubfolders)
            let read = try await index.read { reader -> (folders: [Int64: String], photos: [Int64: Photo]) in
                var tree = try Self.folders(below: path, in: reader)
                if !includesSubfolders {
                    tree = tree.filter { $0.value == path }
                }
                let statement = try reader.database.cached("SELECT id, name FROM photos WHERE folder = ?")
                var photos: [Int64: Photo] = [:]
                for folder in tree.keys {
                    try statement.bind(folder, at: 1)
                    try statement.forEachRow { photos[$0.int64(at: 0)] = Photo(
                        folder: folder,
                        name: $0.string(at: 1) ?? "",
                    ) }
                }
                return (tree, photos)
            }
            photos = read.photos
            ranks = Self.ranks(of: read.folders)
        }

        /// The folder at `path` and every folder below it, their paths by ID.
        private static func folders(below path: String, in reader: LibraryIndex.Reader) throws -> [Int64: String] {
            guard let top = try reader.folder(path: path) else { return [:] }
            let below = path == "/" ? "/" : path + "/"
            var folders: [Int64: String] = [:]
            for folder in try reader.folders(inRoot: top.root)
                where folder.path == path || folder.path.hasPrefix(below) {
                folders[folder.id] = folder.path
            }
            return folders
        }

        /// Each folder's place in Folders' order, by its ID.
        private static func ranks(of folders: [Int64: String]) -> [Int64: Int] {
            let ordered = folders.sorted { Mapping.foldersPrecede($0.value, $1.value) }
            return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.key, $0) })
        }
    }
}
