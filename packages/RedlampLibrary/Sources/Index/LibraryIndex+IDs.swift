import Foundation

/// The tables whose IDs are never given twice (LIB-05): a photo, folder or root never gets the ID of one the index
/// had before, as SQLite would give it once the row with the largest ID is gone. Photo IDs outlive their rows in
/// culling's, the panels' and rename's Undo, the metadata, keyword and file journals, lists, their diffs and
/// selections, the column store and its snapshot, and the health rows, hashes and XMP merge records kept for a
/// photo; folder IDs in the file journal's moves and Put Back; root IDs in the settings kept for a root. Each table's
/// last ID given is kept in the settings, in the transaction that gives it.
///
/// Not AUTOINCREMENT: an upsert that only updates a row spends an ID there, so each pass reading a million photos
/// again would spend a million.
enum IndexIDs: String, Sendable, CaseIterable {
    case photos, folders, roots

    /// The setting keeping the last ID the table gave.
    var key: String {
        "index.lastID." + rawValue
    }

    /// The largest ID anything in the index holds for the table's rows, its own included: where an index that
    /// has kept no last ID starts, so none of them is given again.
    fileprivate var held: String {
        let sources = switch self {
        case .photos:
            [
                "SELECT max(id) FROM photos", "SELECT max(photo) FROM photo_hashes",
                "SELECT max(photo) FROM photo_health", "SELECT max(photo) FROM photo_keywords",
                "SELECT max(photo) FROM collection_photos", Self.largest(in: XMPMergeRecord.key(0)),
            ]
        case .folders:
            ["SELECT max(id) FROM folders", "SELECT max(folder) FROM photos"]
        case .roots:
            [
                "SELECT max(id) FROM roots", "SELECT max(root) FROM folders",
                Self.largest(in: LibraryIndex.Writer.removingKey(0)), Self.largest(in: LibrarySidecars.probedKey(0)),
                Self.largest(in: LibrarySidecars.pathKey(0)),
            ]
        }
        return "SELECT max(" + sources.map { "coalesce((\($0)), 0)" }.joined(separator: ", ") + ")"
    }

    /// The largest ID ending the settings' keys made as `key` is for ID 0.
    private static func largest(in key: String) -> String {
        let prefix = String(key.dropLast())
        return """
        SELECT max(CAST(substr(key, \(prefix.utf8.count + 1)) AS INTEGER)) FROM settings \
        WHERE key > '\(prefix)' AND key < '\(prefix.dropLast())/'
        """
    }
}

extension LibraryIndex.Writer {
    /// The last ID `table` gave: the one the settings keep, or a larger one in the table that a build before
    /// them added; on an index that has kept none, the largest ID anything holds for the table.
    func lastID(of table: IndexIDs) throws -> Int64 {
        guard let kept = try setting(table.key).flatMap({ Int64($0) }) else {
            return try database.cached(table.held).first { $0.int64(at: 0) } ?? 0
        }
        let largest = try database.cached("SELECT coalesce(max(id), 0) FROM \(table.rawValue)")
        return try max(kept, largest.first { $0.int64(at: 0) } ?? 0)
    }

    /// An ID `table` hasn't given, noted as given.
    func newID(of table: IndexIDs) throws -> Int64 {
        let id = try lastID(of: table) + 1
        try setSetting(String(id), for: table.key)
        return id
    }

    /// Notes `id` as given by `table`, and every ID before it: once IDs are given in order from `lastID`, and for
    /// a row put back under its own ID, which an index made again from nothing hasn't given.
    func noteGiven(_ id: Int64, of table: IndexIDs) throws {
        try setSetting(String(max(lastID(of: table), id)), for: table.key)
    }
}
