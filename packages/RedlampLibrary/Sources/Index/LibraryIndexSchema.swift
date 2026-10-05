import Foundation

extension LibraryIndex {
    /// A step from one schema version to the next, run in a transaction.
    typealias Migration = @Sendable (SQLiteDatabase) throws -> Void

    /// The schema's steps in order: the first makes version 1 from an empty database.
    static let migrations: [Migration] = [createVersion1]

    static func createVersion1(_ database: SQLiteDatabase) throws {
        try database.execute(schemaVersion1)
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
}
