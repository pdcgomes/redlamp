import Foundation

/// The tables whose IDs are never given twice (LIB-05): a photo, folder, root, collection, keyword, camera or lens
/// never gets the ID of one the index had before, as SQLite would give it once the row with the largest ID is gone,
/// nor of one an index it replaced had (`IndexIDMarks`). Photo IDs outlive their rows in culling's, the panels' and
/// rename's Undo, the metadata, keyword and file journals, the photos waiting for an XMP sync, lists, their diffs and
/// selections, the column store and its snapshot, and the health rows, hashes and XMP merge records kept for a
/// photo; folder IDs in the file journal's moves and Put Back; root IDs in the settings kept for a root and the
/// sidecar move's journal; collection IDs in the file journal's places of a photo put back, and collection and
/// keyword IDs in the query engine's names, plans and postings until they're read again after a change; camera and
/// lens IDs in the rows the file journal keeps. Each table's last ID given is kept in the settings, in the
/// transaction that gives it.
///
/// Not AUTOINCREMENT: an upsert that only updates a row spends an ID there, so each pass reading a million photos
/// again would spend a million.
enum IndexIDs: String, Sendable, CaseIterable {
    case photos, folders, roots, collections, keywords, cameras, lenses

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
        case .collections:
            ["SELECT max(id) FROM collections", "SELECT max(collection) FROM collection_photos"]
        case .keywords:
            ["SELECT max(id) FROM keywords", "SELECT max(keyword) FROM photo_keywords"]
        case .cameras, .lenses:
            // Never removed, so no photo holds one the table hasn't.
            ["SELECT max(id) FROM \(rawValue)"]
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
        marks?.raise(table, to: id)
        return id
    }

    /// Notes `id` as given by `table`, and every ID before it: once IDs are given in order from `lastID`, and for
    /// a row put back under its own ID, which an index made again from nothing hasn't given.
    func noteGiven(_ id: Int64, of table: IndexIDs) throws {
        let last = try max(lastID(of: table), id)
        try setSetting(String(last), for: table.key)
        marks?.raise(table, to: last)
    }
}

/// The last ID each of `IndexIDs`' tables gave, kept beside the index as well as in it (`Index.ids` beside
/// `Index.sqlite`): an index restored from an older snapshot, or made again from nothing, would otherwise give again
/// the IDs given since, and what holds them outside the index (the journals, Undo, the photos waiting for an XMP
/// sync) would reach other photos with them. Whatever holds an ID finds the photo it meant, or none.
///
/// The file is written and synced in each transaction that gives an ID, before it commits, so it's never behind the
/// index, even when a power cut takes the index's last commits. As the index opens, its last IDs are raised to the
/// file's, and the file's to the index's (`reconcile`). The file is JSON, its tables' last IDs by name, keys a newer
/// build wrote kept: `{"folders":12,"photos":1040,"roots":2}`.
final class IndexIDMarks: @unchecked Sendable {
    let url: URL
    /// The last IDs given in the transaction in progress, by table. Used only on the writer's queue.
    private var raised: [String: Int64] = [:]

    /// The file is written at this length, or longer if it must be, over what it held: a write that small
    /// isn't torn.
    static let length = 512

    /// The marks of the index at `index`.
    init(index: URL) {
        url = index.deletingPathExtension().appendingPathExtension("ids")
    }

    /// Starts noting a transaction's IDs.
    func begin() {
        raised.removeAll()
    }

    /// Notes `id` as the last `table` gave in the transaction in progress.
    func raise(_ table: IndexIDs, to id: Int64) {
        raised[table.rawValue] = max(raised[table.rawValue] ?? 0, id)
    }

    /// Writes the IDs the transaction in progress gave, before it commits; nothing when the file has them.
    func save() throws {
        guard !raised.isEmpty else { return }
        defer { raised.removeAll() }
        let kept = read()
        let marks = kept.merging(raised, uniquingKeysWith: max)
        if marks != kept {
            try write(marks)
        }
    }

    /// Brings the index `writer` writes and the file into step as the index opens: each table's last ID raised to
    /// the file's, where an index restored or made again from nothing is behind it, and the file's to the index's.
    func reconcile(_ writer: LibraryIndex.Writer) throws {
        let kept = read()
        var marks = kept
        for table in IndexIDs.allCases {
            let (last, mark) = try (writer.lastID(of: table), kept[table.rawValue] ?? 0)
            // An index from before the last IDs were kept has them worked out once.
            if try mark > last || last > 0 && writer.setting(table.key) == nil {
                try writer.setSetting(String(max(mark, last)), for: table.key)
            }
            if last > mark {
                marks[table.rawValue] = last
            }
        }
        if marks != kept {
            try write(marks)
        }
    }

    /// What the file holds; nothing when there's none, or it can't be read.
    func read() -> [String: Int64] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Int64].self, from: data)) ?? [:]
    }

    private func write(_ marks: [String: Int64]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var data = try encoder.encode(marks)
        data.append(contentsOf: repeatElement(UInt8(ascii: " "), count: max(Self.length - 1 - data.count, 0)))
        data.append(0x0A)
        let made = !FileManager.default.fileExists(atPath: url.path)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError.current }
        defer { close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = pwrite(descriptor, bytes.baseAddress! + written, bytes.count - written, off_t(written))
                if count < 0 {
                    guard errno == EINTR else { throw POSIXError.current }
                    continue
                }
                written += count
            }
        }
        guard ftruncate(descriptor, off_t(data.count)) == 0, fsync(descriptor) == 0 else { throw POSIXError.current }
        if made {
            try FileJournal.synchronizeFolder(url.deletingLastPathComponent())
        }
    }
}
