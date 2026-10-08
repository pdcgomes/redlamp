import Foundation

/// What the library holds, as `redlamp library stats` shows it: its photos and folders, its roots
/// and where each keeps its sidecars, its volumes and which are offline, how many photos are
/// edited, rated, flagged and labelled, and what its index and store take on disk.
public struct LibraryStatistics: Sendable, Hashable {
    public struct Root: Sendable, Hashable {
        public var path: String
        public var sidecars: RootRecord.Sidecars
        public var photos: Int
    }

    public struct Volume: Sendable, Hashable {
        /// The library's name for it: its UUID where it has one.
        public var uuid: String
        public var name: String?
        public var kind: VolumeRecord.Kind
        /// Its photos are marked offline: it wasn't there when it was last looked for.
        public var isOffline: Bool
        public var photos: Int
    }

    public var photos = 0
    public var folders = 0
    public var roots: [Root] = []
    public var volumes: [Volume] = []
    public var edited = 0
    /// Photos with a star or more.
    public var rated = 0
    public var picked = 0
    public var rejected = 0
    public var labelled = 0
    /// The index's database with its write-ahead log.
    public var indexBytes: Int64 = 0
    /// The thumbnail and preview store's files.
    public var storeBytes: Int64 = 0

    public init() {}

    /// The statistics of the library whose index is `index`, with its store at `paths.store`. The roots marked
    /// removed, which the index keeps until they're swept, aren't counted.
    public static func read(index: LibraryIndex, paths: LibraryPaths) async throws -> LibraryStatistics {
        var statistics = try await index.read { reader in
            var statistics = LibraryStatistics()
            try reader.database.cached("""
            SELECT count(*), coalesce(sum(edited != 0), 0), coalesce(sum(rating > 0), 0), coalesce(sum(flag = 1), 0),
              coalesce(sum(flag = 2), 0), coalesce(sum(label != 0), 0)
            FROM photos WHERE \(reader.inLibrary())
            """).forEachRow { row in
                statistics.photos = row.int(at: 0)
                statistics.edited = row.int(at: 1)
                statistics.rated = row.int(at: 2)
                statistics.picked = row.int(at: 3)
                statistics.rejected = row.int(at: 4)
                statistics.labelled = row.int(at: 5)
            }
            let removed = try reader.removedRoots()
            statistics.folders = try reader.folderCount() - reader.removedFolders().count
            statistics.roots = try reader.roots().filter { removed[$0.id] == nil }.map { root in
                try Root(path: root.path, sidecars: root.sidecars, photos: reader.photoCount(inRoot: root.id))
            }
            statistics.volumes = try reader.volumes().map { volume in
                try Volume(
                    uuid: volume.uuid, name: volume.name, kind: volume.kind,
                    isOffline: reader.isMarkedOffline(volume: volume.uuid),
                    photos: reader.photoCount(onVolume: volume.id),
                )
            }
            return statistics
        }
        let database = index.url
        let store = paths.store
        (statistics.indexBytes, statistics.storeBytes) = try await LibraryIndex.offCaller {
            let index = ["", "-wal"].reduce(Int64(0)) { total, suffix in
                total + Self.size(of: URL(fileURLWithPath: database.path + suffix))
            }
            return (index, Self.size(of: store))
        }
        return statistics
    }

    /// The bytes of the file at `url`, or of every file below it.
    private static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in files {
            if let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
