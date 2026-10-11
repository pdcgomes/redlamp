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

    /// The photos missing from their folders (DEC-59), read through their own index (schema version 11).
    func missingPhotoIDs() throws -> Set<Int64> {
        var ids = Set<Int64>()
        try database.cached(Self.missingPhotos).forEachRow { ids.insert($0.int64(at: 0)) }
        return ids
    }

    /// The names of the photos missing from each folder, by the folder's ID, as `photos_missing` finds them.
    func foldersWithMissingPhotos() throws -> [Int64: Set<String>] {
        var folders: [Int64: Set<String>] = [:]
        try database.cached("""
        SELECT folder, name FROM photos WHERE state & \(PhotoRecord.State.missing.rawValue) != 0
        """).forEachRow { folders[$0.int64(at: 0), default: []].insert($0.string(at: 1) ?? "") }
        return folders
    }

    /// The folders holding photos whose lens's fields are still to read (`PhotoRecord.lensToRead`), as
    /// `photos_lens_unread` finds them.
    func foldersWithLensesToRead() throws -> Set<Int64> {
        var folders: Set<Int64> = []
        try database.cached("""
        SELECT DISTINCT folder FROM photos WHERE indexed = \(PhotoRecord.lensToRead) AND state = 0
        """).forEachRow { folders.insert($0.int64(at: 0)) }
        return folders
    }

    /// A query of the missing photos' IDs, as `photos_missing` answers it.
    static var missingPhotos: String {
        "SELECT id FROM photos WHERE state & \(PhotoRecord.State.missing.rawValue) != 0"
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

    /// Marks missing, from `date`, the photos of `rows` still in the folder each vanished from (DEC-59), but those
    /// missing already and those of roots marked removed; returns those marked.
    @discardableResult
    func markMissing(_ rows: [(photo: Int64, folder: Int64)], at date: Date) throws -> [Int64] {
        let statement = try database.cached("""
        UPDATE photos SET state = state | ?1, missing_since = ?2
        WHERE id = ?3 AND folder = ?4 AND state & ?1 = 0 AND \(notRemoved())
        """)
        try statement.bind(PhotoRecord.State.missing.rawValue, at: 1)
        try statement.bind(date.timeIntervalSince1970, at: 2)
        var marked: [Int64] = []
        for row in rows {
            try statement.bind(row.photo, at: 3)
            try statement.bind(row.folder, at: 4)
            try statement.run()
            if database.changes > 0 {
                marked.append(row.photo)
            }
        }
        return marked
    }

    /// Marks missing, from `date`, the photos in `folder` and every folder under it, as `markMissing(_:at:)` does.
    @discardableResult
    func markMissing(inSubtreeOf folder: Int64, at date: Date) throws -> [Int64] {
        try markMissing(photos(inSubtreeOf: folder).map { ($0.id, $0.folder) }, at: date)
    }

    /// Takes the missing mark off photos `ids`, found again; returns those that had it.
    @discardableResult
    func markFound(_ ids: [Int64]) throws -> [Int64] {
        let statement = try database.cached("""
        UPDATE photos SET state = state & ~?1, missing_since = NULL WHERE id = ?2 AND state & ?1 != 0
        """)
        try statement.bind(PhotoRecord.State.missing.rawValue, at: 1)
        var found: [Int64] = []
        for id in ids {
            try statement.bind(id, at: 2)
            try statement.run()
            if database.changes > 0 {
                found.append(id)
            }
        }
        return found
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
