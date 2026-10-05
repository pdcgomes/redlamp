import Foundation

/// The index's queries, on a read connection inside `LibraryIndex.read` or on the write
/// connection inside `LibraryIndex.write` (where they see the transaction's own changes).
/// Neither connection may be kept past the closure it was passed to.
public protocol IndexQueries {
    var database: SQLiteDatabase { get }
}

public extension LibraryIndex {
    struct Reader: IndexQueries {
        public let database: SQLiteDatabase
    }

    /// The columns of a photo's text in `photo_text`, for searching only some of them. Folders,
    /// cameras and lenses are matched in their own tables (`QueryEngine`).
    enum TextColumn: String, Sendable, CaseIterable {
        case name, keywords, title, caption
    }
}

public extension IndexQueries {
    // MARK: - Volumes, roots and folders

    func volumes() throws -> [VolumeRecord] {
        try database.cached("SELECT \(IndexColumns.volume) FROM volumes ORDER BY id").map(VolumeRecord.init)
    }

    func volume(uuid: String) throws -> VolumeRecord? {
        let statement = try database.cached("SELECT \(IndexColumns.volume) FROM volumes WHERE uuid = ?")
        try statement.bind(uuid, at: 1)
        return try statement.first(VolumeRecord.init)
    }

    func roots() throws -> [RootRecord] {
        try database.cached("SELECT \(IndexColumns.root) FROM roots ORDER BY path").map(RootRecord.init)
    }

    func folder(id: Int64) throws -> FolderRecord? {
        let statement = try database.cached("SELECT \(IndexColumns.folder) FROM folders WHERE id = ?")
        try statement.bind(id, at: 1)
        return try statement.first(FolderRecord.init)
    }

    func folder(path: String) throws -> FolderRecord? {
        let statement = try database.cached("SELECT \(IndexColumns.folder) FROM folders WHERE path = ?")
        try statement.bind(path, at: 1)
        return try statement.first(FolderRecord.init)
    }

    /// The folders directly inside `parent`, by path.
    func subfolders(of parent: Int64) throws -> [FolderRecord] {
        let statement = try database.cached("SELECT \(IndexColumns.folder) FROM folders WHERE parent = ? ORDER BY path")
        try statement.bind(parent, at: 1)
        return try statement.map(FolderRecord.init)
    }

    /// The folders whose photos aren't indexed as their last listing found them, or that haven't
    /// been listed: where indexing resumes.
    func foldersToIndex() throws -> [FolderRecord] {
        try database.cached("""
        SELECT \(IndexColumns.folder) FROM folders
        WHERE signature IS NULL OR indexed_signature IS NOT signature ORDER BY path
        """).map(FolderRecord.init)
    }

    func folderCount() throws -> Int {
        try database.cached("SELECT count(*) FROM folders").first { $0.int(at: 0) } ?? 0
    }

    // MARK: - Photos

    func photo(id: Int64) throws -> PhotoRecord? {
        let statement = try database.cached("SELECT \(IndexColumns.photo) FROM photos WHERE id = ?")
        try statement.bind(id, at: 1)
        return try statement.first(PhotoRecord.init)
    }

    func photo(folder: Int64, name: String) throws -> PhotoRecord? {
        let statement = try database.cached("SELECT \(IndexColumns.photo) FROM photos WHERE folder = ? AND name = ?")
        try statement.bind(folder, at: 1)
        try statement.bind(name, at: 2)
        return try statement.first(PhotoRecord.init)
    }

    /// The photo at `path`: its folder's path, a slash and its name, as the file system lists them.
    func photo(path: String) throws -> PhotoRecord? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let statement = try database.cached("""
        SELECT \(IndexColumns.photo(prefix: "p.")) FROM photos p JOIN folders f ON f.id = p.folder
        WHERE f.path = ? AND p.name = ?
        """)
        try statement.bind(String(path[..<slash]), at: 1)
        try statement.bind(String(path[path.index(after: slash)...]), at: 2)
        return try statement.first(PhotoRecord.init)
    }

    /// The photos with file identifier `fileID` on `volume`: one, unless the volume reused it.
    func photos(fileID: UInt64, volume: Int64) throws -> [PhotoRecord] {
        let statement = try database.cached("""
        SELECT \(IndexColumns.photo(prefix: "p.")) FROM photos p JOIN folders f ON f.id = p.folder
        JOIN roots r ON r.id = f.root WHERE p.file_id = ? AND r.volume = ? ORDER BY p.id
        """)
        try statement.bind(Int64(bitPattern: fileID), at: 1)
        try statement.bind(volume, at: 2)
        return try statement.map(PhotoRecord.init)
    }

    /// The photos showing the same content: copies of one file, on any volume. It reads every photo,
    /// since content keys have no index (schema version 2): looking up many, load the keys once.
    func photos(contentKey: Data) throws -> [PhotoRecord] {
        let statement = try database
            .cached("SELECT \(IndexColumns.photo) FROM photos WHERE content_key = ? ORDER BY id")
        try statement.bind(contentKey, at: 1)
        return try statement.map(PhotoRecord.init)
    }

    /// The photos in `folder`, by name.
    func photos(inFolder folder: Int64) throws -> [PhotoRecord] {
        let statement = try database.cached("SELECT \(IndexColumns.photo) FROM photos WHERE folder = ? ORDER BY name")
        try statement.bind(folder, at: 1)
        return try statement.map(PhotoRecord.init)
    }

    /// The photos in `folder` and every folder under it, by folder and name.
    func photos(inSubtreeOf folder: Int64) throws -> [PhotoRecord] {
        guard let path = try self.folder(id: folder)?.path else { return [] }
        let statement = try database.cached("""
        SELECT \(IndexColumns.photo(prefix: "p.")) FROM folders f JOIN photos p ON p.folder = f.id
        WHERE f.path = ?1 OR (f.path >= ?2 AND f.path < ?3) ORDER BY f.path, p.name
        """)
        try statement.bindSubtree(of: path)
        return try statement.map(PhotoRecord.init)
    }

    /// The IDs of the photos in `folder` and every folder under it, in ID order.
    func photoIDs(inSubtreeOf folder: Int64) throws -> [Int64] {
        guard let path = try self.folder(id: folder)?.path else { return [] }
        let statement = try database.cached("""
        SELECT p.id FROM folders f JOIN photos p ON p.folder = f.id
        WHERE f.path = ?1 OR (f.path >= ?2 AND f.path < ?3) ORDER BY p.id
        """)
        try statement.bindSubtree(of: path)
        return try statement.map { $0.int64(at: 0) }
    }

    func photoCount() throws -> Int {
        try database.cached("SELECT count(*) FROM photos").first { $0.int(at: 0) } ?? 0
    }

    func photoCount(inFolder folder: Int64) throws -> Int {
        let statement = try database.cached("SELECT count(*) FROM photos WHERE folder = ?")
        try statement.bind(folder, at: 1)
        return try statement.first { $0.int(at: 0) } ?? 0
    }

    /// Photos per folder, for folders with any.
    func photoCountsByFolder() throws -> [Int64: Int] {
        var counts: [Int64: Int] = [:]
        try database.cached("SELECT folder, count(*) FROM photos GROUP BY folder").forEachRow { row in
            counts[row.int64(at: 0)] = row.int(at: 1)
        }
        return counts
    }

    // MARK: - Text, keywords, cameras and lenses

    /// The IDs of the photos whose name, keywords, title or caption contain `text`, ignoring case,
    /// in ID order, or only those whose `column` does. Text shorter than three characters matches
    /// nothing, since the index holds trigrams.
    func photoIDs(matching text: String, in column: LibraryIndex.TextColumn? = nil, limit: Int? = nil) throws
        -> [Int64] {
        let phrase = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let statement = try database.cached(
            "SELECT rowid FROM photo_text WHERE photo_text MATCH ? ORDER BY rowid LIMIT ?",
        )
        try statement.bind(column.map { "\($0.rawValue) : \(phrase)" } ?? phrase, at: 1)
        try statement.bind(limit ?? -1, at: 2)
        return try statement.map { $0.int64(at: 0) }
    }

    /// The keywords on `photo`, by path.
    func keywords(forPhoto photo: Int64) throws -> [String] {
        let statement = try database.cached("""
        SELECT k.path FROM photo_keywords pk JOIN keywords k ON k.id = pk.keyword WHERE pk.photo = ? ORDER BY k.path
        """)
        try statement.bind(photo, at: 1)
        return try statement.map { $0.string(at: 0) ?? "" }
    }

    /// The IDs of the photos with the keyword at `path`, or, with `includingChildren`, any keyword
    /// under it, in ID order.
    func photoIDs(withKeyword path: String, includingChildren: Bool = true) throws -> [Int64] {
        let statement = try database.cached("""
        SELECT DISTINCT pk.photo FROM keywords k JOIN photo_keywords pk ON pk.keyword = k.id
        WHERE k.path = ?1 OR (?4 AND k.path >= ?2 AND k.path < ?3) ORDER BY pk.photo
        """)
        try statement.bindSubtree(of: path)
        try statement.bind(includingChildren, at: 4)
        return try statement.map { $0.int64(at: 0) }
    }

    /// Every keyword's path, by ID.
    func keywordPaths() throws -> [Int64: String] {
        try names("SELECT id, path FROM keywords")
    }

    /// Every camera's name, by ID.
    func cameraNames() throws -> [Int64: String] {
        try names("SELECT id, name FROM cameras")
    }

    /// Every lens's name, by ID.
    func lensNames() throws -> [Int64: String] {
        try names("SELECT id, name FROM lenses")
    }

    func setting(_ key: String) throws -> String? {
        let statement = try database.cached("SELECT value FROM settings WHERE key = ?")
        try statement.bind(key, at: 1)
        return try statement.first { $0.string(at: 0) } ?? nil
    }

    // MARK: - Scanning

    /// Every photo's hot columns, in ID order, one call per photo: what the column store is built
    /// from (LIB-06).
    func scanHotColumns(_ body: (HotColumns) throws -> Void) throws {
        try database.cached("""
        SELECT id, folder, captured, camera, lens, rating, flag, label, marked, edited, iso, aperture, focal, kind,
          name
        FROM photos ORDER BY id
        """).forEachRow { row in
            try body(HotColumns(
                id: row.int64(at: 0), folder: row.int64(at: 1), captured: row.optionalDouble(at: 2),
                camera: row.optionalInt64(at: 3), lens: row.optionalInt64(at: 4), rating: row.int(at: 5),
                flag: row.int(at: 6), label: row.int(at: 7), marked: row.bool(at: 8), edited: row.bool(at: 9),
                iso: row.optionalDouble(at: 10), aperture: row.optionalDouble(at: 11),
                focal: row.optionalDouble(at: 12),
                kind: row.int(at: 13), name: row.string(at: 14) ?? "",
            ))
        }
    }

    // MARK: - Helpers

    private func names(_ sql: String) throws -> [Int64: String] {
        var names: [Int64: String] = [:]
        try database.cached(sql).forEachRow { row in
            names[row.int64(at: 0)] = row.string(at: 1) ?? ""
        }
        return names
    }
}

extension SQLiteStatement {
    /// Binds `path` to `?1`, and to `?2` and `?3` the bounds of the paths under it: `/` sorts
    /// just before `0`, so they're the paths from `path/` up to `path0`.
    func bindSubtree(of path: String) throws {
        let base = path.hasSuffix("/") ? String(path.dropLast()) : path
        try bind(path, at: 1)
        try bind(base + "/", at: 2)
        try bind(base + "0", at: 3)
    }
}

/// The column lists the records are read from, in the order their initializers read them.
enum IndexColumns {
    static let volume = "id, uuid, name, kind, event_database, last_event"
    static let root = "id, volume, path, bookmark, sidecars"
    static let folder = "id, root, parent, path, signature, indexed_signature, listed_at"
    static let photo = photo(prefix: "")

    /// Every column of `photos` but the ID, in table order.
    static let photoFields = [
        "folder", "name", "kind", "size", "modified", "file_id", "content_key", "captured", "captured_offset", "camera",
        "lens", "iso", "aperture", "shutter", "focal", "width", "height", "orientation", "latitude", "longitude",
        "rating", "flag", "label", "marked", "edited", "sidecar_modified", "xmp_modified", "title", "caption", "state",
        "indexed",
    ]

    static func photo(prefix: String) -> String {
        (["id"] + photoFields).map { prefix + $0 }.joined(separator: ", ")
    }
}

extension VolumeRecord {
    init(_ row: SQLiteStatement) {
        self.init(
            id: row.int64(at: 0), uuid: row.string(at: 1) ?? "", name: row.string(at: 2),
            kind: Kind(rawValue: row.int(at: 3)) ?? .unknown, eventDatabase: row.string(at: 4),
            lastEvent: row.optionalInt64(at: 5).map { UInt64(bitPattern: $0) },
        )
    }
}

extension RootRecord {
    init(_ row: SQLiteStatement) {
        self.init(
            id: row.int64(at: 0), volume: row.int64(at: 1), path: row.string(at: 2) ?? "", bookmark: row.data(at: 3),
            sidecars: Sidecars(rawValue: row.int(at: 4)) ?? .besidePhotos,
        )
    }
}

extension FolderRecord {
    init(_ row: SQLiteStatement) {
        self.init(
            id: row.int64(at: 0), root: row.int64(at: 1), parent: row.optionalInt64(at: 2),
            path: row.string(at: 3) ?? "",
            signature: row.optionalInt64(at: 4), indexedSignature: row.optionalInt64(at: 5),
            listedAt: row.optionalDouble(at: 6).map(Date.init(timeIntervalSince1970:)),
        )
    }
}

extension PhotoRecord {
    init(_ row: SQLiteStatement) {
        func date(_ column: Int32) -> Date? {
            row.optionalDouble(at: column).map(Date.init(timeIntervalSince1970:))
        }
        self.init(
            id: row.int64(at: 0), folder: row.int64(at: 1), name: row.string(at: 2) ?? "",
            kind: Kind(rawValue: row.int(at: 3)) ?? .other, size: row.int64(at: 4),
            modified: Date(timeIntervalSince1970: row.double(at: 5)),
            fileID: row.optionalInt64(at: 6).map { UInt64(bitPattern: $0) }, contentKey: row.data(at: 7),
            captured: date(8), capturedOffset: row.optionalInt(at: 9), camera: row.optionalInt64(at: 10),
            lens: row.optionalInt64(at: 11), iso: row.optionalDouble(at: 12), aperture: row.optionalDouble(at: 13),
            shutter: row.optionalDouble(at: 14), focal: row.optionalDouble(at: 15), width: row.optionalInt(at: 16),
            height: row.optionalInt(at: 17), orientation: row.optionalInt(at: 18), latitude: row.optionalDouble(at: 19),
            longitude: row.optionalDouble(at: 20), rating: row.int(at: 21), flag: Self.flag(code: row.int(at: 22)),
            label: Self.label(code: row.int(at: 23)), marked: row.bool(at: 24), edited: row.bool(at: 25),
            sidecarModified: date(26), xmpModified: date(27), title: row.string(at: 28), caption: row.string(at: 29),
            state: State(rawValue: row.int(at: 30)), indexed: row.int(at: 31),
        )
    }
}
