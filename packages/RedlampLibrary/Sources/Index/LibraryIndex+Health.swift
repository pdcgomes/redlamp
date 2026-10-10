import Foundation

/// The index's side of Library Health (LIB-40): what indexing found wrong with photos' files, in
/// `photo_health`, standing for a photo while its row has the size and modification date the file
/// had when it was read.
public extension LibraryIndex.Writer {
    /// Keeps `health` for photo `id`, or, when it's nil or has nothing to say of a file named `name`,
    /// forgets what was kept.
    func setHealth(_ health: PhotoHealth?, forPhoto id: Int64, name: String) throws {
        guard let health, health.isWorthKeeping(forName: name) else {
            let delete = try database.cached("DELETE FROM photo_health WHERE photo = ?")
            try delete.bind(id, at: 1)
            return try delete.run()
        }
        let statement = try database.cached("""
        INSERT OR REPLACE INTO photo_health (photo, size, modified, format, damage, missing, reason, end_unread,
          extension) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        var missing: Int64?
        var reason: String?
        switch health.damage {
        case let .endsEarly(bytes): missing = bytes
        case let .unreadable(text): reason = text
        default: break
        }
        try statement.bind(id, at: 1)
        try statement.bind(health.size, at: 2)
        try statement.bind(health.modified.timeIntervalSince1970, at: 3)
        try statement.bind(health.format.rawValue, at: 4)
        try statement.bind(health.damageCode, at: 5)
        try statement.bind(missing, at: 6)
        try statement.bind(reason, at: 7)
        try statement.bind(health.endUnread, at: 8)
        try statement.bind(health.proposedExtension, at: 9)
        try statement.run()
    }

    /// Records how the photo named `name` in the folder at `folder` ends, read while its file was
    /// `size` bytes and modified at `modified`: kept only while its row and its health have them
    /// still. Returns the photo's ID when it was kept.
    func setEnd(
        _ damage: PhotoHealth.Damage?, ofPhotoNamed name: String, inFolder folder: String, size: Int64,
        modified: Date,
    ) throws -> Int64? {
        guard let folderID = try self.folder(path: folder)?.id, let photo = try photo(folder: folderID, name: name),
              photo.size == size, LibraryIndexer.Run.same(photo.modified, modified),
              var health = try photoHealth([photo.id])[photo.id], health.endUnread
        else { return nil }
        health.endUnread = false
        health.damage = damage ?? health.damage
        try setHealth(health, forPhoto: photo.id, name: photo.name)
        return photo.id
    }
}

public extension IndexQueries {
    /// The health kept for photos `ids` that stands for them, by ID.
    func photoHealth(_ ids: [Int64]) throws -> [Int64: PhotoHealth] {
        let statement = try database.cached("""
        SELECT \(Self.healthColumns) FROM photo_health h JOIN photos p ON p.id = h.photo
        WHERE h.photo = ? AND p.size = h.size AND abs(p.modified - h.modified) < 1e-6
        """)
        var found: [Int64: PhotoHealth] = [:]
        for id in ids {
            try statement.bind(id, at: 1)
            if let health = try statement.first(Self.health) {
                found[id] = health
            }
        }
        return found
    }

    /// Every photo's health that stands, by ID, with its photo's name; not of roots marked removed.
    func photoHealth() throws -> [Int64: (health: PhotoHealth, name: String)] {
        var found: [Int64: (health: PhotoHealth, name: String)] = [:]
        try database.cached("""
        SELECT \(Self.healthColumns), h.photo, p.name FROM photo_health h JOIN photos p ON p.id = h.photo
        WHERE p.size = h.size AND abs(p.modified - h.modified) < 1e-6 AND \(inLibrary(
            folder: "p.folder",
            state: "p.state",
        ))
        """).forEachRow { row in
            found[row.int64(at: 8)] = (Self.health(row), row.string(at: 9) ?? "")
        }
        return found
    }

    /// The photos of `root` whose ends are still to be read: each one's folder path, name and health.
    func unreadEnds(inRoot root: Int64) throws -> [(folder: String, name: String, health: PhotoHealth)] {
        let statement = try database.cached("""
        SELECT \(Self.healthColumns), f.path, p.name FROM photo_health h JOIN photos p ON p.id = h.photo
          JOIN folders f ON f.id = p.folder
        WHERE h.end_unread != 0 AND f.root = ? AND p.size = h.size AND abs(p.modified - h.modified) < 1e-6
        ORDER BY f.path, p.name
        """)
        try statement.bind(root, at: 1)
        return try statement.map { row in (row.string(at: 8) ?? "", row.string(at: 9) ?? "", Self.health(row)) }
    }

    /// What `health(_:)` reads, columns 0 to 7.
    private static var healthColumns: String {
        "h.size, h.modified, h.format, h.damage, h.missing, h.reason, h.end_unread, h.extension"
    }

    private static func health(_ row: SQLiteStatement) -> PhotoHealth {
        PhotoHealth(
            size: row.int64(at: 0), modified: Date(timeIntervalSince1970: row.double(at: 1)),
            format: PhotoFormat(rawValue: row.int(at: 2)) ?? .unknown,
            damage: PhotoHealth.damage(
                code: row.int(at: 3),
                missing: row.optionalInt64(at: 4),
                reason: row.string(at: 5),
            ),
            endUnread: row.bool(at: 6), proposedExtension: row.string(at: 7),
        )
    }
}

extension LibraryIndex.Writer {
    /// Removes what's kept for photos `ids` beside their rows, which outlives them while a batch can bring them back:
    /// their health rows, hashes, rendered edits and XMP merge records.
    func removeRecords(ofPhotos ids: [Int64]) throws {
        let deletes = try ["photo_health", "photo_hashes", "photo_edits"]
            .map { try database.cached("DELETE FROM \($0) WHERE photo = ?") }
        for id in ids {
            for delete in deletes {
                try delete.bind(id, at: 1)
                try delete.run()
            }
            try setSetting(nil, for: XMPMergeRecord.key(id))
        }
    }

    /// Removes the health rows, hashes and rendered edits of photos the index no longer has, but for `keeping`'s;
    /// returns how many photos they were.
    @discardableResult
    func removeOrphanedHealth(keeping: Set<Int64>) throws -> Int {
        let tables = ["photo_health", "photo_hashes", "photo_edits"]
        var orphans = Set<Int64>()
        for table in tables {
            try database.cached("SELECT photo FROM \(table) WHERE photo NOT IN (SELECT id FROM photos)")
                .forEachRow { orphans.insert($0.int64(at: 0)) }
        }
        orphans.subtract(keeping)
        let deletes = try tables.map { try database.cached("DELETE FROM \($0) WHERE photo = ?") }
        for photo in orphans {
            for delete in deletes {
                try delete.bind(photo, at: 1)
                try delete.run()
            }
        }
        return orphans.count
    }
}
