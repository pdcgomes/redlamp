import Foundation

/// A photo's full SHA-256 (LIB-39), and the size, modification date and content key its file had
/// when it was read: it stands for the file while the photo's row has them still.
public struct PhotoHash: Sendable, Hashable {
    public var photo: Int64
    public var size: Int64
    public var modified: Date
    public var contentKey: Data
    public var sha256: Data

    public init(photo: Int64, size: Int64, modified: Date, contentKey: Data, sha256: Data) {
        self.photo = photo
        self.size = size
        self.modified = modified
        self.contentKey = contentKey
        self.sha256 = sha256
    }

    /// The hash of `photo` as its row is now.
    public init(_ photo: PhotoRecord, sha256: Data) {
        self.init(
            photo: photo.id, size: photo.size, modified: photo.modified, contentKey: photo.contentKey ?? Data(),
            sha256: sha256,
        )
    }

    /// Whether it still stands for `photo`'s file: recorded at the size, modification date and content
    /// key the row has, allowing for what storing a date as seconds since 1970 rounds away.
    public func stands(for photo: PhotoRecord) -> Bool {
        photo.id == self.photo && photo.size == size && photo.contentKey == contentKey
            && abs(photo.modified.timeIntervalSince1970 - modified.timeIntervalSince1970) < 1e-6
    }
}

public extension IndexQueries {
    /// The hashes recorded for `photos`, whatever their rows say now, by photo ID.
    func photoHashes(_ photos: [Int64]) throws -> [Int64: PhotoHash] {
        let statement = try database.cached(
            "SELECT photo, size, modified, content_key, sha256 FROM photo_hashes WHERE photo = ?",
        )
        var hashes: [Int64: PhotoHash] = [:]
        for photo in photos {
            try statement.bind(photo, at: 1)
            hashes[photo] = try statement.first(PhotoHash.init)
        }
        return hashes
    }

    func photoHashCount() throws -> Int {
        try database.cached("SELECT count(*) FROM photo_hashes").first { $0.int(at: 0) } ?? 0
    }
}

public extension LibraryIndex.Writer {
    /// Records the hashes, each in place of the one its photo had.
    func setPhotoHashes(_ hashes: [PhotoHash]) throws {
        let statement = try database.cached("""
        INSERT INTO photo_hashes (photo, size, modified, content_key, sha256) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT (photo) DO UPDATE SET size = excluded.size, modified = excluded.modified,
          content_key = excluded.content_key, sha256 = excluded.sha256
        """)
        for hash in hashes {
            try statement.bind(hash.photo, at: 1)
            try statement.bind(hash.size, at: 2)
            try statement.bind(hash.modified.timeIntervalSince1970, at: 3)
            try statement.bind(hash.contentKey, at: 4)
            try statement.bind(hash.sha256, at: 5)
            try statement.run()
        }
    }

    /// Removes the hashes of photos the index no longer has; returns how many.
    @discardableResult
    func removeOrphanedPhotoHashes() throws -> Int {
        try database.cached("DELETE FROM photo_hashes WHERE photo NOT IN (SELECT id FROM photos)").run()
        return database.changes
    }

    /// Removes every hash, so the next confirmation reads every file again; returns how many.
    @discardableResult
    func removePhotoHashes() throws -> Int {
        try database.cached("DELETE FROM photo_hashes").run()
        return database.changes
    }
}

extension PhotoHash {
    init(_ row: SQLiteStatement) {
        self.init(
            photo: row.int64(at: 0), size: row.int64(at: 1), modified: Date(timeIntervalSince1970: row.double(at: 2)),
            contentKey: row.data(at: 3) ?? Data(), sha256: row.data(at: 4) ?? Data(),
        )
    }
}
