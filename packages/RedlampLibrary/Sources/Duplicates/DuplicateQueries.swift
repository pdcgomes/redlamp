import Foundation
import SQLite3

// The queries finding duplicates needs beyond the index's own (LIB-39).

/// A candidate as the index has it: its row, where its file is, and the volume it's on.
struct DuplicateRow: Sendable, Hashable {
    var record: PhotoRecord
    var folder: String
    var root: String
    /// The index's name for its volume (`VolumeRecord.uuid`).
    var volume: String

    var url: URL {
        URL(fileURLWithPath: folder + "/" + record.name, isDirectory: false)
    }
}

extension IndexQueries {
    /// Every photo with a content key, grouped by it and its size in one pass over the photos.
    func groupContentKeys() throws -> DuplicateGrouper {
        var grouper = try DuplicateGrouper(capacity: photoCount())
        try database.cached("SELECT id, size, content_key FROM photos WHERE content_key IS NOT NULL")
            .forEachRow { row in
                guard let (high, low) = row.contentKeyHalves(at: 2) else { return }
                grouper.add(photo: row.int64(at: 0), high: high, low: low, size: row.int64(at: 1))
            }
        return grouper
    }

    /// The candidates the index still has, by ID.
    func duplicateRows(_ photos: [Int64]) throws -> [Int64: DuplicateRow] {
        let extra = Int32(IndexColumns.photoFields.count + 1)
        let statement = try database.cached("""
        SELECT \(IndexColumns.photo(prefix: "p.")), f.path, r.path, v.uuid FROM photos p
        JOIN folders f ON f.id = p.folder JOIN roots r ON r.id = f.root JOIN volumes v ON v.id = r.volume
        WHERE p.id = ?
        """)
        var rows: [Int64: DuplicateRow] = [:]
        for photo in photos {
            try statement.bind(photo, at: 1)
            rows[photo] = try statement.first { row in
                DuplicateRow(
                    record: PhotoRecord(row), folder: row.string(at: extra) ?? "",
                    root: row.string(at: extra + 1) ?? "",
                    volume: row.string(at: extra + 2) ?? "",
                )
            }
        }
        return rows
    }

    /// The names of the photos in `folder`.
    func photoNames(inFolder folder: Int64) throws -> [String] {
        let statement = try database.cached("SELECT name FROM photos WHERE folder = ?")
        try statement.bind(folder, at: 1)
        return try statement.map { $0.string(at: 0) ?? "" }
    }
}

extension SQLiteStatement {
    /// The column's bytes 0 to 7 and 8 to 15, big-endian, read in place: a content key's, as
    /// `DuplicateGrouper` takes them. Nil unless it holds exactly 16.
    func contentKeyHalves(at column: Int32) -> (high: UInt64, low: UInt64)? {
        guard let bytes = sqlite3_column_blob(handle, column), sqlite3_column_bytes(handle, column) == 16 else {
            return nil
        }
        return (
            UInt64(bigEndian: bytes.loadUnaligned(as: UInt64.self)),
            UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self)),
        )
    }
}
