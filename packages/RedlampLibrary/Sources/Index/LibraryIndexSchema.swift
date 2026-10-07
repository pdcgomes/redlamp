import Foundation

extension LibraryIndex {
    /// A step from one schema version to the next, run in a transaction.
    typealias Migration = @Sendable (SQLiteDatabase) throws -> Void

    /// The schema's steps in order: the first makes version 1 from an empty database.
    static let migrations: [Migration] = [
        createVersion1, migrateToVersion2, migrateToVersion3, migrateToVersion4, migrateToVersion5,
        migrateToVersion6, migrateToVersion7,
    ]

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
}
