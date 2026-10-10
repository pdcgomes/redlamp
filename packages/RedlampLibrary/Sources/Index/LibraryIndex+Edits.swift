import Foundation

/// A photo's edit whose render the store holds (LIB-17): the edit's digest, the way of rendering edits that digest is
/// for (`renderer`), and the modification date the photo's sidecar had when the edit was read. It stands for the
/// photo's edit while the photo's row has that date still, so a relaunch finds the photo's render before its sidecar
/// is read again; a sidecar saved since, by Redlamp or another app, leaves it standing for nothing.
public struct PhotoEdit: Sendable, Hashable {
    public var photo: Int64
    public var sidecarModified: Date
    public var digest: EditDigest
    public var renderer: Int

    public init(photo: Int64, sidecarModified: Date, digest: EditDigest, renderer: Int) {
        self.photo = photo
        self.sidecarModified = sidecarModified
        self.digest = digest
        self.renderer = renderer
    }

    /// Whether it still stands for `photo`'s edit: recorded at the sidecar modification date the row has, allowing for
    /// what storing a date as seconds since 1970 rounds away.
    public func stands(for photo: PhotoRecord) -> Bool {
        guard photo.id == self.photo, let modified = photo.sidecarModified else { return false }
        return abs(modified.timeIntervalSince1970 - sidecarModified.timeIntervalSince1970) < 1e-6
    }
}

public extension IndexQueries {
    /// The edits recorded for `photos`, whatever their rows say now, by photo ID.
    func photoEdits(_ photos: [Int64]) throws -> [Int64: PhotoEdit] {
        let statement = try database.cached(
            "SELECT photo, sidecar_modified, digest, renderer FROM photo_edits WHERE photo = ?",
        )
        var edits: [Int64: PhotoEdit] = [:]
        for photo in photos {
            try statement.bind(photo, at: 1)
            edits[photo] = try statement.first(PhotoEdit.init) ?? nil
        }
        return edits
    }

    /// The digests of the edits recorded for `photos` that stand for them as their rows are now, for `renderer`, by
    /// photo ID: read in the transaction that read the rows, the edits of those rows.
    func standingPhotoEdits(ofPhotos photos: some Sequence<Int64>, renderer: Int) throws -> [Int64: EditDigest] {
        let statement = try database.cached("""
        SELECT e.digest FROM photo_edits e JOIN photos p ON p.id = e.photo
        WHERE e.photo = ? AND e.renderer = ? AND e.sidecar_modified = p.sidecar_modified
        """)
        try statement.bind(renderer, at: 2)
        var edits: [Int64: EditDigest] = [:]
        for photo in photos {
            try statement.bind(photo, at: 1)
            if let digest = try statement.first({ $0.data(at: 0).flatMap(EditDigest.init(data:)) }) ?? nil {
                edits[photo] = digest
            }
        }
        return edits
    }
}

public extension LibraryIndex.Writer {
    /// Records `digest`, for `renderer`, as the edit of `photo` whose render the store holds, read from its sidecar as
    /// it was modified at `sidecarModified`: in place of the one recorded before, with the date the photo's row has,
    /// if that's `sidecarModified` within a millisecond. Whether it was recorded: a row with another date, a sidecar
    /// saved since, or none, records nothing.
    @discardableResult
    func setPhotoEdit(_ digest: EditDigest, ofPhoto photo: Int64, sidecarModified: Date, renderer: Int) throws -> Bool {
        let statement = try database.cached("""
        INSERT INTO photo_edits (photo, sidecar_modified, digest, renderer)
          SELECT id, sidecar_modified, ?, ? FROM photos WHERE id = ? AND abs(sidecar_modified - ?) < 0.001
        ON CONFLICT (photo) DO UPDATE SET sidecar_modified = excluded.sidecar_modified, digest = excluded.digest,
          renderer = excluded.renderer
        """)
        try statement.bind(digest.data, at: 1)
        try statement.bind(renderer, at: 2)
        try statement.bind(photo, at: 3)
        try statement.bind(sidecarModified.timeIntervalSince1970, at: 4)
        try statement.run()
        return database.changes > 0
    }

    /// Removes the edits recorded for `photos`.
    func removePhotoEdits(_ photos: some Sequence<Int64>) throws {
        let statement = try database.cached("DELETE FROM photo_edits WHERE photo = ?")
        for photo in photos {
            try statement.bind(photo, at: 1)
            try statement.run()
        }
    }
}

extension PhotoEdit {
    /// The row's edit; nil when its digest isn't 16 bytes.
    init?(_ row: SQLiteStatement) {
        guard let digest = row.data(at: 2).flatMap(EditDigest.init(data:)) else { return nil }
        self.init(
            photo: row.int64(at: 0), sidecarModified: Date(timeIntervalSince1970: row.double(at: 1)), digest: digest,
            renderer: row.int(at: 3),
        )
    }
}
