import Foundation
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

    /// The order Folders lists a large folder's photos in, from LibraryLive's list of them by name, in the Finder's
    /// order as the query engine has it: with subfolders, each photo goes with its folder's, a folder's before its
    /// subfolders' (`Mapping.foldersPrecede`), as the index keeps each photo's folder.
    struct FolderOrder: Sendable {
        let path: String
        let includesSubfolders: Bool
        /// The place of the folder and of each folder below it in Folders' order, by its ID.
        private var ranks: [Int64: Int] = [:]
        /// Each photo's folder, by the photo's ID.
        private var folders: [Int64: Int64] = [:]

        /// Changes of more photos than this read every photo's folder again, rather than theirs alone.
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
            guard includesSubfolders else { return (list, changed) }
            if let changed, !folders.isEmpty, changed.count <= Self.largestRead {
                try await read(changed, index: index)
            } else {
                try await readAll(index: index)
            }
            return (PhotoList(source: list.source, sort: list.sort, ids: walked(list.ids)), changed)
        }

        /// `ids`, in LibraryLive's order, each taken to its folder's place, keeping that order within each folder.
        private func walked(_ ids: ContiguousArray<Int64>) -> ContiguousArray<Int64> {
            let unknown = ranks.count
            var starts = [Int](repeating: 0, count: unknown + 2)
            var places = [Int](repeating: unknown, count: ids.count)
            for (index, id) in ids.enumerated() {
                let rank = folders[id].flatMap { ranks[$0] } ?? unknown
                places[index] = rank
                starts[rank + 1] += 1
            }
            for rank in 1 ..< starts.count {
                starts[rank] += starts[rank - 1]
            }
            var walked = ContiguousArray<Int64>(repeating: 0, count: ids.count)
            for (index, id) in ids.enumerated() {
                walked[starts[places[index]]] = id
                starts[places[index]] += 1
            }
            return walked
        }

        /// Reads the folders of the photos `ids`, and every folder's place again when one is new.
        private mutating func read(_ ids: [Int64], index: LibraryIndex) async throws {
            guard !ids.isEmpty else { return }
            let found = try await index.read { reader in
                let statement = try reader.database.cached("SELECT folder FROM photos WHERE id = ?")
                var found: [(photo: Int64, folder: Int64)] = []
                for id in ids {
                    try statement.bind(id, at: 1)
                    try statement.forEachRow { found.append((id, $0.int64(at: 0))) }
                }
                return found
            }
            for (photo, folder) in found {
                folders[photo] = folder
            }
            if found.contains(where: { ranks[$0.folder] == nil }) {
                let path = path
                ranks = try await Self.ranks(of: index.read { try Self.folders(below: path, in: $0) })
            }
        }

        /// Reads every photo's folder, and every folder's place.
        private mutating func readAll(index: LibraryIndex) async throws {
            let path = path
            let read = try await index.read { reader -> (folders: [Int64: String], photos: [Int64: Int64]) in
                let tree = try Self.folders(below: path, in: reader)
                let statement = try reader.database.cached("SELECT id FROM photos WHERE folder = ?")
                var photos: [Int64: Int64] = [:]
                for folder in tree.keys {
                    try statement.bind(folder, at: 1)
                    try statement.forEachRow { photos[$0.int64(at: 0)] = folder }
                }
                return (tree, photos)
            }
            folders = read.photos
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
