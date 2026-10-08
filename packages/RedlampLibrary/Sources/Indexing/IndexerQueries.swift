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

    /// How many photos the library has on `volume`: not those of roots marked removed.
    func photoCount(onVolume volume: Int64) throws -> Int {
        let statement = try database.cached("""
        SELECT count(*) FROM photos WHERE folder IN
          (SELECT f.id FROM folders f JOIN roots r ON r.id = f.root WHERE r.volume = ?) AND \(inLibrary())
        """)
        try statement.bind(volume, at: 1)
        return try statement.first { $0.int(at: 0) } ?? 0
    }

    /// Whether the photos on the volume with `uuid` were marked offline and haven't been cleared.
    func isMarkedOffline(volume uuid: String) throws -> Bool {
        try setting(LibraryIndex.Writer.offlineKey(uuid)) != nil
    }

    /// How far the index has applied the event history of the volume with `uuid`; nil when it has
    /// recorded none.
    func eventHistory(ofVolume uuid: String) throws -> VolumeEventHistory? {
        guard let volume = try volume(uuid: uuid), let database = volume.eventDatabase,
              let event = volume.lastEvent
        else { return nil }
        return VolumeEventHistory(eventDatabase: database, lastEvent: event)
    }
}

/// How far the index has applied a volume's event history (LIB-08): the history's database, and the
/// last of its events whose changes are in the index.
public struct VolumeEventHistory: Sendable, Hashable {
    /// The UUID of the volume's event database (`FSEventsCopyUUIDForDevice`).
    public var eventDatabase: String
    public var lastEvent: UInt64

    public init(eventDatabase: String, lastEvent: UInt64) {
        self.eventDatabase = eventDatabase
        self.lastEvent = lastEvent
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

    /// Records that the index holds the changes of the volume with `uuid` up to `history.lastEvent`
    /// of its event database; returns false when the index has no such volume.
    @discardableResult
    func setEventHistory(_ history: VolumeEventHistory, ofVolume uuid: String) throws -> Bool {
        guard let volume = try volume(uuid: uuid) else { return false }
        try setLastEvent(history.lastEvent, eventDatabase: history.eventDatabase, forVolume: volume.id)
        return true
    }

    internal static func offlineKey(_ uuid: String) -> String {
        "library.offline." + uuid
    }
}
