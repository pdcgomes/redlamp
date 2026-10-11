import Foundation
import SQLite3

extension LibraryIndex {
    /// A step from one schema version to the next, run in a transaction.
    typealias Migration = @Sendable (SQLiteDatabase) throws -> Void

    /// The schema's steps in order: the first makes version 1 from an empty database.
    static let migrations: [Migration] = [
        createVersion1, migrateToVersion2, migrateToVersion3, migrateToVersion4, migrateToVersion5,
        migrateToVersion6, migrateToVersion7, migrateToVersion8, migrateToVersion9, migrateToVersion10,
        migrateToVersion11, migrateToVersion12,
    ]

    /// The version of the schema this build makes and opens.
    public static var schemaVersion: Int {
        migrations.count
    }

    static func createVersion1(_ database: SQLiteDatabase) throws {
        try database.execute(schemaVersion1)
    }

    static func migrateToVersion2(_ database: SQLiteDatabase) throws {
        try database.execute(schemaVersion2)
    }

    static func migrateToVersion3(_ database: SQLiteDatabase) throws {
        try database.execute(schemaVersion3)
    }

    static func migrateToVersion4(_ database: SQLiteDatabase) throws {
        try database.execute(schemaVersion4)
    }

    static func migrateToVersion5(_ database: SQLiteDatabase) throws {
        try database.execute(schemaVersion5)
    }

    static func migrateToVersion6(_ database: SQLiteDatabase) throws {
        try database.execute(schemaVersion6)
    }

    static func migrateToVersion7(_ database: SQLiteDatabase) throws {
        try QueryFunctions.register(on: database)
        try database.execute(schemaVersion7)
    }

    static func migrateToVersion8(_ database: SQLiteDatabase) throws {
        try database.execute(schemaVersion8)
    }

    /// Adds nothing to an index that has the column already, one set back to version 8.
    static func migrateToVersion9(_ database: SQLiteDatabase) throws {
        let column = try database.prepare("SELECT 1 FROM pragma_table_info('photos') WHERE name = 'stack_position'")
        guard try column.first({ _ in true }) == nil else { return }
        try database.execute(schemaVersion9)
    }

    static func migrateToVersion10(_ database: SQLiteDatabase) throws {
        try database.execute(schemaVersion10)
    }

    /// Adds no column to an index that has it already, one set back to an earlier version.
    static func migrateToVersion11(_ database: SQLiteDatabase) throws {
        let column = try database.prepare("SELECT 1 FROM pragma_table_info('photos') WHERE name = 'missing_since'")
        if try column.first({ _ in true }) == nil {
            try database.execute(schemaVersion11)
        }
        try database.execute(schemaVersion11Index)
    }

    /// Adds no column to an index that has them already, one set back to an earlier version.
    static func migrateToVersion12(_ database: SQLiteDatabase) throws {
        let column = try database.prepare("SELECT 1 FROM pragma_table_info('photos') WHERE name = 'focal35'")
        if try column.first({ _ in true }) == nil {
            try database.execute(schemaVersion12)
        }
        try LensFunctions.register(on: database)
        try database.execute(schemaVersion12Fill)
    }

    /// Brings `database` up to the last version `migrations` knows, one step per transaction.
    static func migrate(_ database: SQLiteDatabase, with migrations: [Migration]) throws {
        var version = try database.userVersion
        guard version != migrations.count else { return }
        while version < migrations.count {
            // Read again under the write lock: another process may have migrated meanwhile.
            version = try database.transaction(.immediate) {
                let current = try database.userVersion
                guard current < migrations.count else { return current }
                try migrations[current](database)
                try database.setUserVersion(current + 1)
                return current + 1
            }
        }
        guard version == migrations.count else {
            throw LibraryIndexError.newerVersion(found: version, supported: migrations.count)
        }
    }

    /// The design's schema (`docs/plans/2026-10-05-library-design.md`), with the indexes its
    /// lookups need and the view `photo_text` is filled from.
    ///
    /// There are no triggers: FTS5 writes the terms it holds in memory out as a new segment at
    /// every statement savepoint, which a statement with a trigger or an upsert opens, so text
    /// kept in step by triggers cost a segment per photo and halved the rate photos are added.
    /// The writer keeps `photo_text`, keywords and collections in step itself, after each batch.
    static let schemaVersion1 = """
    CREATE TABLE volumes (id INTEGER PRIMARY KEY, uuid TEXT UNIQUE NOT NULL, name TEXT, kind INTEGER NOT NULL,
      event_database TEXT, last_event INTEGER);                  -- kind: 0 unknown, 1 SSD, 2 spinning, 3 network
    CREATE TABLE roots (id INTEGER PRIMARY KEY, volume INTEGER NOT NULL, path TEXT UNIQUE NOT NULL, bookmark BLOB,
      sidecars INTEGER NOT NULL DEFAULT 0);                      -- sidecars: 0 beside the photos, 1 on this Mac
    CREATE TABLE folders (id INTEGER PRIMARY KEY, root INTEGER NOT NULL, parent INTEGER, path TEXT UNIQUE NOT NULL,
      signature INTEGER, indexed_signature INTEGER, listed_at REAL);
    CREATE TABLE photos (id INTEGER PRIMARY KEY, folder INTEGER NOT NULL, name TEXT NOT NULL, kind INTEGER NOT NULL,
      size INTEGER NOT NULL, modified REAL NOT NULL, file_id INTEGER, content_key BLOB,
      captured REAL, captured_offset INTEGER, camera INTEGER, lens INTEGER, iso REAL, aperture REAL, shutter REAL,
      focal REAL, width INTEGER, height INTEGER, orientation INTEGER, latitude REAL, longitude REAL,
      rating INTEGER NOT NULL DEFAULT 0, flag INTEGER NOT NULL DEFAULT 0, label INTEGER NOT NULL DEFAULT 0,
      marked INTEGER NOT NULL DEFAULT 0, edited INTEGER NOT NULL DEFAULT 0, sidecar_modified REAL, xmp_modified REAL,
      title TEXT, caption TEXT, state INTEGER NOT NULL DEFAULT 0, indexed INTEGER NOT NULL DEFAULT 0,
      UNIQUE (folder, name));                                    -- state bits: missing, offline, settling
    CREATE TABLE cameras (id INTEGER PRIMARY KEY, make TEXT, model TEXT, name TEXT UNIQUE NOT NULL);
    CREATE TABLE lenses (id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL);
    CREATE TABLE keywords (id INTEGER PRIMARY KEY, parent INTEGER, name TEXT NOT NULL, path TEXT UNIQUE NOT NULL);
    CREATE TABLE photo_keywords (photo INTEGER NOT NULL, keyword INTEGER NOT NULL, PRIMARY KEY (photo, keyword))
      WITHOUT ROWID;
    CREATE TABLE collections (id INTEGER PRIMARY KEY, parent INTEGER, name TEXT NOT NULL, kind INTEGER NOT NULL,
      query TEXT);                                               -- kind: 0 set, 1 collection, 2 smart collection
    CREATE TABLE collection_photos (collection INTEGER NOT NULL, photo INTEGER NOT NULL, position INTEGER,
      PRIMARY KEY (collection, photo)) WITHOUT ROWID;
    CREATE VIRTUAL TABLE photo_text USING fts5(name, folder, keywords, title, caption, camera, lens,
      content='', contentless_delete=1, tokenize='trigram');     -- rowid is photos.id
    CREATE TABLE settings (key TEXT PRIMARY KEY, value) WITHOUT ROWID;

    CREATE INDEX folders_parent ON folders (parent);
    CREATE INDEX photos_file_id ON photos (file_id) WHERE file_id IS NOT NULL;
    CREATE INDEX photos_content_key ON photos (content_key) WHERE content_key IS NOT NULL;
    CREATE INDEX photo_keywords_keyword ON photo_keywords (keyword);
    CREATE INDEX collection_photos_photo ON collection_photos (photo);

    CREATE VIEW photo_text_rows AS
      SELECT p.id AS id, p.name AS name, f.path AS folder,
        (SELECT group_concat(k.path, ' ') FROM photo_keywords pk JOIN keywords k ON k.id = pk.keyword
          WHERE pk.photo = p.id) AS keywords,
        p.title AS title, p.caption AS caption, c.name AS camera, l.name AS lens
      FROM photos p LEFT JOIN folders f ON f.id = p.folder LEFT JOIN cameras c ON c.id = p.camera
        LEFT JOIN lenses l ON l.id = p.lens;
    """

    /// The design's Results (LIB-05): the text index holds names, keywords, titles and captions, which
    /// added photos at 17,700 a second where all seven text columns managed 12,100; folders, cameras
    /// and lenses are matched in their own tables, thousands of rows rather than millions. And there's
    /// no index on the content key, which alone took a replica of the inserts from 104,000 rows a
    /// second to 20,000: lookups by content key load the keys into a set once instead.
    ///
    /// The text of photos already indexed is written again from the view in one statement, so FTS5
    /// writes its terms out once.
    static let schemaVersion2 = """
    DROP INDEX photos_content_key;
    DROP VIEW photo_text_rows;
    DROP TABLE photo_text;
    CREATE VIRTUAL TABLE photo_text USING fts5(name, keywords, title, caption,
      content='', contentless_delete=1, tokenize='trigram');     -- rowid is photos.id

    CREATE VIEW photo_text_rows AS
      SELECT p.id AS id, p.name AS name,
        (SELECT group_concat(k.path, ' ') FROM photo_keywords pk JOIN keywords k ON k.id = pk.keyword
          WHERE pk.photo = p.id) AS keywords,
        p.title AS title, p.caption AS caption
      FROM photos p;

    INSERT INTO photo_text (rowid, name, keywords, title, caption)
      SELECT id, name, keywords, title, caption FROM photo_text_rows;
    """

    /// The full SHA-256 of photos confirmed as duplicates or not (LIB-39), with the size, modification
    /// date and content key their files had when they were read: a hash stands for its photo while
    /// the photo's row has them still, so an unchanged file is never read twice.
    static let schemaVersion3 = """
    CREATE TABLE photo_hashes (photo INTEGER PRIMARY KEY, size INTEGER NOT NULL, modified REAL NOT NULL,
      content_key BLOB NOT NULL, sha256 BLOB NOT NULL);          -- photo is photos.id
    """

    /// The rest of the organising fields the sidecar holds (LIB-15, LIB-22, LIB-23, LIB-28), so the index
    /// is rebuilt from the sidecars with nothing lost (DEC-42): IPTC Core's creator, copyright and
    /// location beside the title and caption, a custom label's name, the manual stack, which fields
    /// show other apps' values rather than the `.redlamp`'s, a signature of the photo's `.xmp` files,
    /// and collections found by path. Manual stacks the settings kept move to their columns.
    static let schemaVersion4 = """
    ALTER TABLE photos ADD COLUMN creator TEXT;
    ALTER TABLE photos ADD COLUMN copyright TEXT;
    ALTER TABLE photos ADD COLUMN sublocation TEXT;
    ALTER TABLE photos ADD COLUMN city TEXT;
    ALTER TABLE photos ADD COLUMN province TEXT;                  -- a state or province
    ALTER TABLE photos ADD COLUMN country TEXT;
    ALTER TABLE photos ADD COLUMN country_code TEXT;
    ALTER TABLE photos ADD COLUMN custom_label TEXT;
    ALTER TABLE photos ADD COLUMN stack TEXT;                     -- a manual stack's UUID
    ALTER TABLE photos ADD COLUMN stack_top INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE photos ADD COLUMN other_fields INTEGER NOT NULL DEFAULT 0; -- bits: XMPField's order
    ALTER TABLE photos ADD COLUMN xmp_signature INTEGER;
    ALTER TABLE collections ADD COLUMN path TEXT;

    CREATE UNIQUE INDEX collections_path ON collections (path);
    CREATE INDEX photos_stack ON photos (stack) WHERE stack IS NOT NULL;

    UPDATE photos SET stack = json_extract(settings.value, '$.id'),
      stack_top = coalesce(json_extract(settings.value, '$.top'), 0)
      FROM settings WHERE settings.key = 'library.stack.' || photos.id;
    DELETE FROM settings WHERE key >= 'library.stack.' AND key < 'library.stack/';
    """

    /// The camera's own capture time and zone, kept while a photo's sidecar shifts the time or gives the
    /// camera another zone (LIB-22): `captured` and `captured_offset` show the sidecar's, so the camera's
    /// can always be worked out again, and a sidecar changed since is shown without reading the photo.
    static let schemaVersion5 = """
    ALTER TABLE photos ADD COLUMN camera_captured REAL;
    ALTER TABLE photos ADD COLUMN camera_offset INTEGER;
    """

    /// What indexing found wrong with photos' files (LIB-40), for the photos with something to say: the
    /// format their first bytes hold where it isn't their extension's, damage, or an end still to read,
    /// with the size and modification date their files had when they were read, so a row stands for its
    /// photo while the photo's row has them still. Rows outlive their photos, as hashes do, so a photo
    /// Undo or Put Back brings back under its ID finds its row again.
    static let schemaVersion6 = """
    CREATE TABLE photo_health (photo INTEGER PRIMARY KEY, size INTEGER NOT NULL, modified REAL NOT NULL,
      format INTEGER NOT NULL DEFAULT 0, damage INTEGER NOT NULL DEFAULT 0, missing INTEGER, reason TEXT,
      end_unread INTEGER NOT NULL DEFAULT 0, extension TEXT);  -- photo is photos.id; damage: PhotoHealth.Damage
    CREATE INDEX photo_health_unread ON photo_health (photo) WHERE end_unread != 0;
    """

    /// Text that ignores accents and width, as the small tables and completion do (DEC-52): the text
    /// index built again with the trigram tokenizer's `remove_diacritics 1`, and every photo's text
    /// written again from the view folded as the writer now folds it (`redlamp_text`), in one
    /// statement as version 2's was.
    static let schemaVersion7 = """
    DROP TABLE photo_text;
    CREATE VIRTUAL TABLE photo_text USING fts5(name, keywords, title, caption,
      content='', contentless_delete=1, tokenize='trigram remove_diacritics 1');  -- rowid is photos.id

    INSERT INTO photo_text (rowid, name, keywords, title, caption)
      SELECT id, redlamp_text(name), redlamp_text(keywords), redlamp_text(title), redlamp_text(caption)
      FROM photo_text_rows;
    """

    /// The photos with a `.redlamp` sidecar, by folder (LIB-11): Move Edits and Metadata… counts a root's as its
    /// sheet opens (`photoCount(withSidecarsInRoot:)`), which visited every photo of the root through
    /// `(folder, name)` and read its row, 35 ms the first time in a launch for 150,000 photos, and takes 1.1 ms with
    /// it. Built in 0.11 s at a million photos, 0.65 s while the file isn't in memory, it takes 1.6 MB for their
    /// 150,000 with sidecars.
    static let schemaVersion8 = """
    CREATE INDEX IF NOT EXISTS photos_sidecars ON photos (folder) WHERE sidecar_modified IS NOT NULL;
    """

    /// A photo's place in its manual stack (LIB-28), as its sidecar's `stack.position` holds it once the stack's photos
    /// have been put in an order, so a stack keeps its order however the index is built. Adding the column rewrites no
    /// row.
    static let schemaVersion9 = """
    ALTER TABLE photos ADD COLUMN stack_position INTEGER;         -- from 0 at the top
    """

    /// The edits whose renders the store holds (LIB-17), so a relaunch shows a photo's render before its sidecar is
    /// read again: for each photo rendered, its edit's digest, the way of rendering edits that digest is for, and the
    /// modification date its sidecar had when the edit was read. A row stands for its photo while the photo's row has
    /// that date still (`PhotoEdit`). Rows outlive their photos, as hashes do, so a photo Undo or Put Back brings back
    /// under its ID finds its render again.
    static let schemaVersion10 = """
    CREATE TABLE IF NOT EXISTS photo_edits (photo INTEGER PRIMARY KEY, sidecar_modified REAL NOT NULL,
      digest BLOB NOT NULL, renderer INTEGER NOT NULL);         -- photo is photos.id
    """

    /// Photos whose files went outside Redlamp are kept with the state's missing bit rather than removed (DEC-59): when
    /// change tracking found each file gone, for Library Health's Missing check, the one list that shows them, and the
    /// missing photos by folder, so the check and Locate…'s look beside a found file read only theirs. Adding the
    /// column
    /// rewrites no row.
    static let schemaVersion11 = """
    ALTER TABLE photos ADD COLUMN missing_since REAL;            -- while state has the missing bit
    """

    static let schemaVersion11Index = """
    CREATE INDEX IF NOT EXISTS photos_missing ON photos (folder) WHERE state & 1 != 0;
    """

    /// The lens's widest aperture at the photo's focal length and the focal length in 35 mm terms (LIB-06), for the
    /// traits Wide Open, Telephoto and Ultra Wide (`LensOptics`). Adding the columns rewrites no row.
    static let schemaVersion12 = """
    ALTER TABLE photos ADD COLUMN widest_aperture REAL;          -- an f-number
    ALTER TABLE photos ADD COLUMN focal35 REAL;                  -- millimetres
    """

    /// Fills the two from what the index keeps of photos already read, where that allows: the widest aperture from
    /// the lens's name, and the 35 mm focal length from the camera's make and model for the cameras whose crop factor
    /// `LensOptics` knows. The index doesn't keep EXIF's lens specification or 35 mm focal length, so every photo
    /// read is marked to be read again for the two (`PhotoRecord.lensToRead`), and `photos_lens_unread` lists the
    /// folders holding such photos, for the indexer to find them however long ago the folders changed.
    static let schemaVersion12Fill = """
    UPDATE photos SET indexed = 2,
      widest_aperture = coalesce(widest_aperture,
        (SELECT redlamp_widest_aperture(l.name, photos.focal) FROM lenses l WHERE l.id = photos.lens)),
      focal35 = coalesce(focal35,
        (SELECT redlamp_focal35(c.make, c.model, photos.focal) FROM cameras c WHERE c.id = photos.camera))
    WHERE indexed = 1;
    CREATE INDEX IF NOT EXISTS photos_lens_unread ON photos (folder) WHERE indexed = 2 AND state = 0;
    """
}

/// What schema version 12's migration computes from the index's own tables: `LensOptics` registered with SQLite.
enum LensFunctions {
    static func register(on database: SQLiteDatabase) throws {
        let flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC
        let results = [
            sqlite3_create_function_v2(
                database.handle, "redlamp_widest_aperture", 2, flags, nil, widestApertureFunction, nil, nil, nil,
            ),
            sqlite3_create_function_v2(
                database.handle,
                "redlamp_focal35",
                3,
                flags,
                nil,
                focal35Function,
                nil,
                nil,
                nil,
            ),
        ]
        if let failed = results.first(where: { $0 != SQLITE_OK }) {
            throw SQLiteError(code: failed, message: "couldn't register the lens functions", sql: nil)
        }
    }
}

private func text(_ value: OpaquePointer?) -> String? {
    sqlite3_value_text(value).map { String(cString: $0) }
}

private func real(_ value: OpaquePointer?) -> Double? {
    sqlite3_value_type(value) == SQLITE_NULL ? nil : sqlite3_value_double(value)
}

private func result(_ context: OpaquePointer?, _ number: Double?) {
    if let number {
        sqlite3_result_double(context, number)
    } else {
        sqlite3_result_null(context)
    }
}

/// `redlamp_widest_aperture(lens, focal)`: the widest f-number the lens's name gives at `focal`.
private func widestApertureFunction(
    _ context: OpaquePointer?, _: Int32, _ values: UnsafeMutablePointer<OpaquePointer?>?,
) {
    guard let values, let lens = text(values[0]) else { return sqlite3_result_null(context) }
    result(context, LensOptics.widestAperture(lens: lens, focal: real(values[1])))
}

/// `redlamp_focal35(make, model, focal)`: `focal` in 35 mm terms, for a camera whose crop factor `LensOptics` knows.
private func focal35Function(_ context: OpaquePointer?, _: Int32, _ values: UnsafeMutablePointer<OpaquePointer?>?) {
    guard let values else { return sqlite3_result_null(context) }
    result(
        context,
        LensOptics.focal35(written: nil, focal: real(values[2]), make: text(values[0]), model: text(values[1])),
    )
}
