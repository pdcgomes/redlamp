import Foundation
import RedlampDocument
import SQLite3

public extension LibraryIndex {
    /// Changes to the index inside `write`, all in its transaction, with the queries, which see
    /// the changes made so far.
    final class Writer: IndexQueries {
        public let database: SQLiteDatabase
        /// Where the photos whose keywords change are noted, for the column store (LIB-44).
        let journal: IndexJournal?
        /// Where the IDs given are noted, for the marks beside the index set before the transaction commits
        /// (`IndexIDMarks`).
        let marks: IndexIDMarks?
        /// IDs looked up in this transaction: gone with it, so a rollback leaves none stale.
        private var cameraIDs: [String: Int64] = [:]
        private var lensIDs: [String: Int64] = [:]
        private var keywordIDs: [String: Int64] = [:]
        /// The transaction wrote photos' text, which FTS5 writes as a segment as it commits; text only deleted
        /// leaves the segments as they are.
        private(set) var wroteText = false

        init(database: SQLiteDatabase, journal: IndexJournal? = nil, marks: IndexIDMarks? = nil) {
            self.database = database
            self.journal = journal
            self.marks = marks
        }
    }

    /// An organising field to set on many photos at once.
    enum OrganisingChange: Sendable, Hashable {
        /// 0 to 5 stars.
        case rating(Int)
        case flag(PhotoFlag?)
        case label(ColorLabel?)
        case marked(Bool)
    }
}

public extension LibraryIndex.Writer {
    // MARK: - Volumes, roots and folders

    /// Adds the volume, or updates the one with its UUID, and returns its ID.
    @discardableResult
    func upsertVolume(_ volume: VolumeRecord) throws -> Int64 {
        let statement = try database.cached("""
        INSERT INTO volumes (uuid, name, kind, event_database, last_event) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT (uuid) DO UPDATE SET name = excluded.name, kind = excluded.kind,
          event_database = excluded.event_database, last_event = excluded.last_event
        RETURNING id
        """)
        try statement.bind(volume.uuid, at: 1)
        try statement.bind(volume.name, at: 2)
        try statement.bind(volume.kind.rawValue, at: 3)
        try statement.bind(volume.eventDatabase, at: 4)
        try statement.bind(volume.lastEvent.map { Int64(bitPattern: $0) }, at: 5)
        return try returnedID(statement)
    }

    /// Records the last FSEvents event applied from `volume`'s event database.
    func setLastEvent(_ event: UInt64, eventDatabase: String?, forVolume volume: Int64) throws {
        let statement = try database.cached("UPDATE volumes SET last_event = ?, event_database = ? WHERE id = ?")
        try statement.bind(Int64(bitPattern: event), at: 1)
        try statement.bind(eventDatabase, at: 2)
        try statement.bind(volume, at: 3)
        try statement.run()
    }

    /// Adds the root, or updates the one at its path, and returns its ID: a new root's is one no root had
    /// (`IndexIDs`).
    @discardableResult
    func upsertRoot(_ root: RootRecord) throws -> Int64 {
        let statement = try database.cached("""
        INSERT INTO roots (volume, path, bookmark, sidecars, id) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT (path) DO UPDATE SET volume = excluded.volume, bookmark = excluded.bookmark,
          sidecars = excluded.sidecars
        RETURNING id
        """)
        try statement.bind(root.volume, at: 1)
        try statement.bind(root.path, at: 2)
        try statement.bind(root.bookmark, at: 3)
        try statement.bind(root.sidecars.rawValue, at: 4)
        try statement.bind(self.root(path: root.path) == nil ? newID(of: .roots) : nil, at: 5)
        return try returnedID(statement)
    }

    /// Adds the folder, or updates the one at its path, and returns its ID: a new folder's is one no folder had
    /// (`IndexIDs`).
    @discardableResult
    func upsertFolder(_ folder: FolderRecord) throws -> Int64 {
        let existing = try database.cached("SELECT 1 FROM folders WHERE path = ?")
        try existing.bind(folder.path, at: 1)
        let statement = try database.cached("""
        INSERT INTO folders (root, parent, path, signature, indexed_signature, listed_at, id)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (path) DO UPDATE SET root = excluded.root, parent = excluded.parent,
          signature = excluded.signature, indexed_signature = excluded.indexed_signature,
          listed_at = excluded.listed_at
        RETURNING id
        """)
        try statement.bind(folder.root, at: 1)
        try statement.bind(folder.parent, at: 2)
        try statement.bind(folder.path, at: 3)
        try statement.bind(folder.signature, at: 4)
        try statement.bind(folder.indexedSignature, at: 5)
        try statement.bind(folder.listedAt?.timeIntervalSince1970, at: 6)
        try statement.bind(existing.first { _ in true } == nil ? newID(of: .folders) : nil, at: 7)
        return try returnedID(statement)
    }

    /// Records a listing of `folder`.
    func setListing(signature: Int64?, listedAt: Date, forFolder folder: Int64) throws {
        let statement = try database.cached("UPDATE folders SET signature = ?, listed_at = ? WHERE id = ?")
        try statement.bind(signature, at: 1)
        try statement.bind(listedAt.timeIntervalSince1970, at: 2)
        try statement.bind(folder, at: 3)
        try statement.run()
    }

    /// Records that `folder`'s photos are indexed as the listing with `signature` found them.
    func setIndexedSignature(_ signature: Int64?, forFolder folder: Int64) throws {
        let statement = try database.cached("UPDATE folders SET indexed_signature = ? WHERE id = ?")
        try statement.bind(signature, at: 1)
        try statement.bind(folder, at: 2)
        try statement.run()
    }

    /// Moves `folder` and every folder under it to `path` (a rename or move Redlamp made), keeping
    /// their rows and their photos' IDs.
    func moveFolder(_ folder: Int64, to path: String, parent: Int64?) throws {
        guard let old = try self.folder(id: folder)?.path, old != path else { return }
        let descendants = try database.cached("""
        UPDATE folders SET path = ?4 || substr(path, length(?1) + 1) WHERE path >= ?2 AND path < ?3
        """)
        try descendants.bindSubtree(of: old)
        try descendants.bind(path, at: 4)
        try descendants.run()
        let moved = try database.cached("UPDATE folders SET path = ?, parent = ? WHERE id = ?")
        try moved.bind(path, at: 1)
        try moved.bind(parent, at: 2)
        try moved.bind(folder, at: 3)
        try moved.run()
    }

    /// Removes `folder`, every folder under it and all their photos.
    func deleteFolder(_ folder: Int64) throws {
        guard let path = try self.folder(id: folder)?.path else { return }
        try deletePhotos(photoIDs(inSubtreeOf: folder))
        let statement = try database.cached("DELETE FROM folders WHERE path = ?1 OR (path >= ?2 AND path < ?3)")
        try statement.bindSubtree(of: path)
        try statement.run()
    }

    // MARK: - Photos

    /// Adds the photos, or updates those already in their folders under their names, keeping
    /// their IDs; returns the IDs in order. A photo added gets an ID no photo had (`IndexIDs`); `id`
    /// in the records is ignored. Pass a batch in one call: each call writes its photos' text once
    /// all its rows are in.
    @discardableResult
    func upsertPhotos(_ photos: [PhotoRecord]) throws -> [Int64] {
        let existing = try database.cached("SELECT id, title, caption FROM photos WHERE folder = ? AND name = ?")
        let upsert = try database.cached(Self.upsertPhoto)
        var ids: [Int64] = []
        ids.reserveCapacity(photos.count)
        var added: [Int64] = []
        var replaced: [Int64] = []
        var scheduled = Set<Int64>()
        var given: Int64?
        for photo in photos {
            try existing.bind(photo.folder, at: 1)
            try existing.bind(photo.name, at: 2)
            let before = try existing.first { row in
                (
                    id: row.int64(at: 0),
                    unchanged: row.string(at: 1) == photo.title && row.string(at: 2) == photo.caption,
                )
            }
            try bind(photo, to: upsert)
            if before == nil {
                given = try (given ?? lastID(of: .photos)) + 1
            }
            try upsert.bind(before == nil ? given : nil, at: Self.upsertPhotoID)
            let id = try returnedID(upsert)
            ids.append(id)
            if before?.unchanged == true || scheduled.contains(id) {
                continue
            }
            scheduled.insert(id)
            if before == nil {
                added.append(id)
            } else {
                replaced.append(id)
            }
        }
        if let given {
            try noteGiven(given, of: .photos)
        }
        try writeText(adding: added, replacing: replaced)
        return ids
    }

    /// Moves a photo to another folder or name (a rename or move Redlamp made), keeping its ID.
    func movePhoto(_ photo: Int64, toFolder folder: Int64, name: String) throws {
        try movePhotos([(photo, folder, name)])
    }

    /// Moves photos to other folders or names (renames or moves Redlamp made), keeping their IDs; a
    /// new extension gives a photo the kind it names (LIB-40's renames to the extension a file's
    /// format takes).
    func movePhotos(_ moves: [(photo: Int64, folder: Int64, name: String)]) throws {
        let statement = try database.cached("UPDATE photos SET folder = ?, name = ?, kind = ? WHERE id = ?")
        for move in moves {
            try statement.bind(move.folder, at: 1)
            try statement.bind(move.name, at: 2)
            try statement.bind(PhotoRecord.Kind(pathExtension: (move.name as NSString).pathExtension).rawValue, at: 3)
            try statement.bind(move.photo, at: 4)
            try statement.run()
        }
        try writeText(replacing: moves.map(\.photo))
    }

    /// Removes photos, with their keywords, collection memberships and text; returns how many
    /// there were.
    @discardableResult
    func deletePhotos(_ ids: [Int64]) throws -> Int {
        let photo = try database.cached("DELETE FROM photos WHERE id = ?")
        let keywords = try database.cached("DELETE FROM photo_keywords WHERE photo = ?")
        let collections = try database.cached("DELETE FROM collection_photos WHERE photo = ?")
        let text = try database.cached("DELETE FROM photo_text WHERE rowid = ?")
        var deleted = 0
        for id in ids {
            try photo.bind(id, at: 1)
            try photo.run()
            guard database.changes > 0 else { continue }
            deleted += 1
            for statement in [keywords, collections, text] {
                try statement.bind(id, at: 1)
                try statement.run()
            }
        }
        return deleted
    }

    /// Sets organising fields on every photo in `ids` (the last change to a field wins); returns
    /// how many photos there were.
    @discardableResult
    func setOrganising(_ changes: [LibraryIndex.OrganisingChange], forPhotos ids: [Int64]) throws -> Int {
        var values: [String: Int] = [:]
        for change in changes {
            switch change {
            case let .rating(rating): values["rating"] = rating
            case let .flag(flag): values["flag"] = PhotoRecord.code(for: flag)
            case let .label(label): values["label"] = PhotoRecord.code(for: label)
            case let .marked(marked): values["marked"] = marked ? 1 : 0
            }
        }
        guard !values.isEmpty, !ids.isEmpty else { return 0 }
        let columns = values.keys.sorted()
        let statement = try database.cached(
            "UPDATE photos SET \(columns.map { "\($0) = ?" }.joined(separator: ", ")) WHERE id = ?",
        )
        for (index, column) in columns.enumerated() {
            try statement.bind(values[column], at: Int32(index + 1))
        }
        let idParameter = Int32(columns.count + 1)
        var updated = 0
        for id in ids {
            try statement.bind(id, at: idParameter)
            try statement.run()
            updated += database.changes
        }
        return updated
    }

    /// Shows `fields` in `photo`'s row: its rating, flag, label or custom label, and IPTC Core's fields,
    /// empty texts and locations as none, with its text indexed again. Keywords are set apart.
    func setFields(_ fields: XMPFields, forPhoto photo: Int64) throws {
        let statement = try database.cached("""
        UPDATE photos SET rating = ?, flag = ?, label = ?, custom_label = ?, title = ?, caption = ?, creator = ?,
          copyright = ?, sublocation = ?, city = ?, province = ?, country = ?, country_code = ? WHERE id = ?
        """)
        let location = XMPFields.place(fields.location)
        try statement.bind(fields.rating ?? 0, at: 1)
        try statement.bind(PhotoRecord.code(for: fields.flag), at: 2)
        try statement.bind(PhotoRecord.code(for: fields.label), at: 3)
        try statement.bind(fields.label == nil ? XMPFields.text(fields.customLabel) : nil, at: 4)
        try statement.bind(XMPFields.text(fields.title), at: 5)
        try statement.bind(XMPFields.text(fields.caption), at: 6)
        try statement.bind(XMPSource.joined(XMPFields.names(fields.creator)), at: 7)
        try statement.bind(XMPFields.text(fields.copyright), at: 8)
        try statement.bind(location?.sublocation, at: 9)
        try statement.bind(location?.city, at: 10)
        try statement.bind(location?.state, at: 11)
        try statement.bind(location?.country, at: 12)
        try statement.bind(location?.countryCode, at: 13)
        try statement.bind(photo, at: 14)
        try statement.run()
        try writeText(replacing: [photo])
    }

    // MARK: - Cameras, lenses and keywords

    /// The ID of the camera named `name`, added the first time it's seen with an ID no camera had (`IndexIDs`).
    func cameraID(for name: String, make: String? = nil, model: String? = nil) throws -> Int64 {
        if let id = cameraIDs[name] {
            return id
        }
        let id: Int64
        if let existing = try existingID(of: name, in: "cameras") {
            id = existing
        } else {
            let insert = try database.cached("""
            INSERT INTO cameras (name, make, model, id) VALUES (?, ?, ?, ?) RETURNING id
            """)
            try insert.bind(name, at: 1)
            try insert.bind(make, at: 2)
            try insert.bind(model, at: 3)
            try insert.bind(newID(of: .cameras), at: 4)
            id = try returnedID(insert)
        }
        cameraIDs[name] = id
        return id
    }

    /// The ID of the lens named `name`, added the first time it's seen with an ID no lens had (`IndexIDs`).
    func lensID(for name: String) throws -> Int64 {
        if let id = lensIDs[name] {
            return id
        }
        let id: Int64
        if let existing = try existingID(of: name, in: "lenses") {
            id = existing
        } else {
            let insert = try database.cached("INSERT INTO lenses (name, id) VALUES (?, ?) RETURNING id")
            try insert.bind(name, at: 1)
            try insert.bind(newID(of: .lenses), at: 2)
            id = try returnedID(insert)
        }
        lensIDs[name] = id
        return id
    }

    /// The ID of the keyword at `path` (`Places/Portugal/Lisbon`), added with any parent it lacks, each with an ID no
    /// keyword had (`IndexIDs`).
    func keywordID(forPath path: String) throws -> Int64 {
        var id: Int64?
        var prefix = ""
        for name in Self.keywordNames(path) {
            prefix = prefix.isEmpty ? name : prefix + "/" + name
            id = try keywordID(prefix, name: name, parent: id)
        }
        guard let id else { throw LibraryIndexError.emptyKeywordPath }
        return id
    }

    /// Gives `photo` the keywords at `paths` and no others.
    func setKeywords(_ paths: [String], forPhoto photo: Int64) throws {
        let wanted = try Set(paths.map(keywordID(forPath:)))
        let current = try database.cached("SELECT keyword FROM photo_keywords WHERE photo = ?")
        try current.bind(photo, at: 1)
        let had = try Set(current.map { $0.int64(at: 0) })
        guard had != wanted else { return }
        for keyword in had.subtracting(wanted) {
            try unlink(photo, keyword)
        }
        for keyword in wanted.subtracting(had) {
            try link(photo, keyword)
        }
        try writeText(replacing: [photo])
    }

    /// Adds the keyword at `path` to every photo in `ids`; returns how many photos gained it.
    @discardableResult
    func addKeyword(_ path: String, toPhotos ids: [Int64]) throws -> Int {
        let keyword = try keywordID(forPath: path)
        let gained = try ids.filter { try link($0, keyword) }
        try writeText(replacing: gained)
        return gained.count
    }

    /// Takes the keyword at `path` off every photo in `ids`; returns how many photos had it.
    @discardableResult
    func removeKeyword(_ path: String, fromPhotos ids: [Int64]) throws -> Int {
        let statement = try database.cached("SELECT id FROM keywords WHERE path = ?")
        try statement.bind(Self.keywordNames(path).joined(separator: "/"), at: 1)
        guard let keyword = try statement.first({ $0.int64(at: 0) }) else { return 0 }
        let lost = try ids.filter { try unlink($0, keyword) }
        try writeText(replacing: lost)
        return lost.count
    }

    func setSetting(_ value: String?, for key: String) throws {
        guard let value else {
            let statement = try database.cached("DELETE FROM settings WHERE key = ?")
            try statement.bind(key, at: 1)
            return try statement.run()
        }
        let statement = try database.cached("""
        INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value
        """)
        try statement.bind(key, at: 1)
        try statement.bind(value, at: 2)
        try statement.run()
    }
}

extension LibraryIndex.Writer {
    /// A photo's fields in `IndexColumns.photoFields` order, then at `upsertPhotoID` the ID of a photo added, none
    /// for one its folder has.
    static let upsertPhoto: String = {
        let fields = IndexColumns.photoFields
        let parameters = (fields.indices.map { "?\($0 + 1)" } + ["?\(upsertPhotoID)"]).joined(separator: ", ")
        let updates = fields.dropFirst(2).map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        return """
        INSERT INTO photos (\(fields.joined(separator: ", ")), id) VALUES (\(parameters))
        ON CONFLICT (folder, name) DO UPDATE SET \(updates) RETURNING id
        """
    }()

    static let upsertPhotoID = Int32(IndexColumns.photoFields.count + 1)

    /// Binds `photo`'s fields in `IndexColumns.photoFields` order.
    func bind(_ photo: PhotoRecord, to statement: SQLiteStatement) throws {
        try statement.bind(photo.folder, at: 1)
        try statement.bind(photo.name, at: 2)
        try statement.bind(photo.kind.rawValue, at: 3)
        try statement.bind(photo.size, at: 4)
        try statement.bind(photo.modified.timeIntervalSince1970, at: 5)
        try statement.bind(photo.fileID.map { Int64(bitPattern: $0) }, at: 6)
        try statement.bind(photo.contentKey, at: 7)
        try statement.bind(photo.captured?.timeIntervalSince1970, at: 8)
        try statement.bind(photo.capturedOffset, at: 9)
        try statement.bind(photo.camera, at: 10)
        try statement.bind(photo.lens, at: 11)
        try statement.bind(photo.iso, at: 12)
        try statement.bind(photo.aperture, at: 13)
        try statement.bind(photo.shutter, at: 14)
        try statement.bind(photo.focal, at: 15)
        try statement.bind(photo.width, at: 16)
        try statement.bind(photo.height, at: 17)
        try statement.bind(photo.orientation, at: 18)
        try statement.bind(photo.latitude, at: 19)
        try statement.bind(photo.longitude, at: 20)
        try statement.bind(photo.rating, at: 21)
        try statement.bind(PhotoRecord.code(for: photo.flag), at: 22)
        try statement.bind(PhotoRecord.code(for: photo.label), at: 23)
        try statement.bind(photo.marked, at: 24)
        try statement.bind(photo.edited, at: 25)
        try statement.bind(photo.sidecarModified?.timeIntervalSince1970, at: 26)
        try statement.bind(photo.xmpModified?.timeIntervalSince1970, at: 27)
        try statement.bind(photo.title, at: 28)
        try statement.bind(photo.caption, at: 29)
        try statement.bind(photo.state.rawValue, at: 30)
        try statement.bind(photo.indexed, at: 31)
        try statement.bind(photo.customLabel, at: 32)
        try statement.bind(photo.creator, at: 33)
        try statement.bind(photo.copyright, at: 34)
        try statement.bind(photo.location?.sublocation, at: 35)
        try statement.bind(photo.location?.city, at: 36)
        try statement.bind(photo.location?.state, at: 37)
        try statement.bind(photo.location?.country, at: 38)
        try statement.bind(photo.location?.countryCode, at: 39)
        try statement.bind(photo.stack?.id?.uuidString, at: 40)
        try statement.bind(photo.stack?.top ?? false, at: 41)
        try statement.bind(PhotoRecord.code(for: photo.otherFields), at: 42)
        try statement.bind(photo.xmpSignature, at: 43)
        try statement.bind(photo.cameraCaptured?.timeIntervalSince1970, at: 44)
        try statement.bind(photo.cameraOffset, at: 45)
        try statement.bind(photo.stack?.position, at: 46)
        try statement.bind(photo.missingSince?.timeIntervalSince1970, at: 47)
    }

    /// The ID an `INSERT ... RETURNING id` returns. SQLite makes the change at the first step.
    func returnedID(_ statement: SQLiteStatement) throws -> Int64 {
        guard let id = try statement.first({ $0.int64(at: 0) }) else {
            throw SQLiteError(code: SQLITE_ERROR, message: "no row ID returned", sql: statement.sql)
        }
        return id
    }

    func existingID(of name: String, in table: String) throws -> Int64? {
        let statement = try database.cached("SELECT id FROM \(table) WHERE name = ?")
        try statement.bind(name, at: 1)
        return try statement.first { $0.int64(at: 0) }
    }

    func keywordID(_ path: String, name: String, parent: Int64?) throws -> Int64 {
        if let id = keywordIDs[path] {
            return id
        }
        let select = try database.cached("SELECT id FROM keywords WHERE path = ?")
        try select.bind(path, at: 1)
        let id: Int64
        if let existing = try select.first({ $0.int64(at: 0) }) {
            id = existing
        } else {
            let insert = try database.cached("""
            INSERT INTO keywords (parent, name, path, id) VALUES (?, ?, ?, ?) RETURNING id
            """)
            try insert.bind(parent, at: 1)
            try insert.bind(name, at: 2)
            try insert.bind(path, at: 3)
            try insert.bind(newID(of: .keywords), at: 4)
            id = try returnedID(insert)
        }
        keywordIDs[path] = id
        return id
    }

    /// A keyword path's levels, without empty ones or the spaces around them.
    static func keywordNames(_ path: String) -> [String] {
        path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether `photo` gained `keyword` (it didn't have it).
    @discardableResult
    func link(_ photo: Int64, _ keyword: Int64) throws -> Bool {
        let statement = try database.cached("INSERT OR IGNORE INTO photo_keywords (photo, keyword) VALUES (?, ?)")
        try statement.bind(photo, at: 1)
        try statement.bind(keyword, at: 2)
        try statement.run()
        return database.changes > 0
    }

    /// Whether `photo` lost `keyword` (it had it).
    @discardableResult
    func unlink(_ photo: Int64, _ keyword: Int64) throws -> Bool {
        let statement = try database.cached("DELETE FROM photo_keywords WHERE photo = ? AND keyword = ?")
        try statement.bind(photo, at: 1)
        try statement.bind(keyword, at: 2)
        try statement.run()
        return database.changes > 0
    }

    /// Writes the text of the photos in `adding`, which have none in `photo_text` yet, and of those
    /// in `replacing`, from `photo_text_rows`, folded as the index holds text (`redlamp_text`). Its
    /// statements open no savepoint, so FTS5 keeps the terms in memory until the transaction
    /// commits; a photo that's gone gets no text.
    func writeText(adding added: [Int64] = [], replacing replaced: [Int64]) throws {
        journal?.touch(photos: added)
        journal?.touch(photos: replaced)
        let delete = try database.cached("DELETE FROM photo_text WHERE rowid = ?")
        for id in replaced {
            try delete.bind(id, at: 1)
            try delete.run()
        }
        let select = try database.cached("""
        SELECT redlamp_text(name), redlamp_text(keywords), redlamp_text(title), redlamp_text(caption)
        FROM photo_text_rows WHERE id = ?
        """)
        let insert = try database.cached("""
        INSERT INTO photo_text (rowid, name, keywords, title, caption) VALUES (?, ?, ?, ?, ?)
        """)
        for id in added + replaced {
            try select.bind(id, at: 1)
            let found = try select.first { row in
                for column in Int32(0) ..< 4 {
                    try insert.bind(column, of: row, at: column + 2)
                }
                return true
            }
            guard found == true else { continue }
            try insert.bind(id, at: 1)
            try insert.run()
            wroteText = true
        }
    }

    /// Merges up to about `pages` pages of the text index's segments, as FTS5's automerge would have merged them in
    /// the commits of the writes (`IndexTextMerges`): whether there was anything to merge. A merge stops only between
    /// terms, so the trigrams most names share, in a million photos' segments, take a step of their own of up to a
    /// few hundred pages.
    func mergeText(pages: Int) throws -> Bool {
        let before = database.totalChanges
        let merge = try database.cached("INSERT INTO photo_text (photo_text, rank) VALUES ('merge', ?)")
        try merge.bind(pages, at: 1)
        try merge.run()
        // The command counts as one change; what it merges, as more.
        return database.totalChanges - before > 1
    }
}
