import Foundation

// The queries and writes indexing and change tracking need beyond the index's own (LIB-07, LIB-08).

public extension IndexQueries {
    /// Every folder of `root`, by path.
    func folders(inRoot root: Int64) throws -> [FolderRecord] {
        let statement = try database.cached("SELECT \(IndexColumns.folder) FROM folders WHERE root = ? ORDER BY path")
        try statement.bind(root, at: 1)
        return try statement.map(FolderRecord.init)
    }

    func root(path: String) throws -> RootRecord? {
        let statement = try database.cached("SELECT \(IndexColumns.root) FROM roots WHERE path = ?")
        try statement.bind(path, at: 1)
        return try statement.first(RootRecord.init)
    }

    /// How many photos have any of the bits of `state`.
    func photoCount(withState state: PhotoRecord.State) throws -> Int {
        let statement = try database.cached("SELECT count(*) FROM photos WHERE state & ? != 0")
        try statement.bind(state.rawValue, at: 1)
        return try statement.first { $0.int(at: 0) } ?? 0
    }

    /// How many photos are on `volume`.
    func photoCount(onVolume volume: Int64) throws -> Int {
        let statement = try database.cached("""
        SELECT count(*) FROM photos WHERE folder IN
          (SELECT f.id FROM folders f JOIN roots r ON r.id = f.root WHERE r.volume = ?)
        """)
        try statement.bind(volume, at: 1)
        return try statement.first { $0.int(at: 0) } ?? 0
    }

    /// Whether the photos on the volume with `uuid` were marked offline and haven't been cleared.
    func isMarkedOffline(volume uuid: String) throws -> Bool {
        try setting(LibraryIndex.Writer.offlineKey(uuid)) != nil
    }
}

public extension LibraryIndex.Writer {
    /// Marks every photo on `volume` (whose UUID is `uuid`) offline, or clears the mark; returns how
    /// many photos changed. The mark is remembered in the settings, so clearing it costs nothing
    /// when there's none.
    @discardableResult
    func setOffline(_ offline: Bool, onVolume volume: Int64, uuid: String) throws -> Int {
        let bit = PhotoRecord.State.offline.rawValue
        let statement = try database.cached(offline ? """
        UPDATE photos SET state = state | ?1 WHERE state & ?1 = 0 AND folder IN
          (SELECT f.id FROM folders f JOIN roots r ON r.id = f.root WHERE r.volume = ?2)
        """ : """
        UPDATE photos SET state = state & ~?1 WHERE state & ?1 != 0 AND folder IN
          (SELECT f.id FROM folders f JOIN roots r ON r.id = f.root WHERE r.volume = ?2)
        """)
        try statement.bind(bit, at: 1)
        try statement.bind(volume, at: 2)
        try statement.run()
        let changed = database.changes
        try setSetting(offline ? "1" : nil, for: Self.offlineKey(uuid))
        return changed
    }

    internal static func offlineKey(_ uuid: String) -> String {
        "library.offline." + uuid
    }
}
