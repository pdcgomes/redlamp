import Foundation
import Testing
@testable import RedlampLibrary

struct IndexSchemaTests {
    private struct Failure: Error {}

    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "redlamp-schema-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var url: URL {
        directory.appending(path: "Index.sqlite")
    }

    private static func pragmas(_ names: [String], on database: SQLiteDatabase) throws -> [String] {
        try names.map { name in try database.prepare("PRAGMA \(name)").first { $0.string(at: 0) ?? "" } ?? "" }
    }

    private static let version = LibraryIndex.migrations.count

    @Test func `a new index has the design's tables and settings, at the current schema version`() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try await LibraryIndex.open(at: url)
        defer { index.closeAndWait() }

        let (tables, text, writer) = try await index.write { writer in
            let tables = try writer.database.prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
                .map { $0.string(at: 0) ?? "" }
            let text = try writer.database.prepare("SELECT sql FROM sqlite_master WHERE name = 'photo_text'")
                .first { $0.string(at: 0) ?? "" }
            let pragmas = try Self.pragmas(
                ["journal_mode", "synchronous", "mmap_size", "temp_store", "cache_size", "user_version"],
                on: writer.database,
            )
            return (tables, text, pragmas)
        }
        let reader = try await index
            .read { try Self.pragmas(["mmap_size", "temp_store", "cache_size"], on: $0.database) }

        let designed: Set = [
            "volumes", "roots", "folders", "photos", "cameras", "lenses", "keywords", "photo_keywords", "collections",
            "collection_photos", "photo_text", "settings",
        ]
        #expect(designed.isSubset(of: tables))
        #expect(text?.contains("tokenize='trigram'") == true && text?.contains("contentless_delete=1") == true)
        #expect(
            writer == ["wal", "1", "\(1 << 30)", "2", "-16384", "\(Self.version)"],
            "WAL, NORMAL, 1 GB mapped, in memory, 16 MB",
        )
        #expect(reader == ["\(1 << 30)", "2", "-16384"])
    }

    @Test func `reopening an index keeps its rows and its version`() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await LibraryIndex.open(at: url)
        try await first.write { try $0.upsertVolume(VolumeRecord(uuid: "A", kind: .spinning)) }
        await first.close()

        let reopened = try await LibraryIndex.open(at: url)
        defer { reopened.closeAndWait() }
        let volumes = try await reopened.read { try $0.volumes() }
        #expect(volumes.map(\.uuid) == ["A"] && volumes.first?.kind == .spinning)
        #expect(try await reopened.read { try $0.database.userVersion } == Self.version)
    }

    @Test func `a migration to the next version runs once, in its own transaction`() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await LibraryIndex.open(at: url)
        try await first.write { try $0.setSetting("kept", for: "before") }
        await first.close()

        let migrations = LibraryIndex.migrations + [
            { database in
                guard database.isInTransaction else { throw Failure() }
                try database.execute("ALTER TABLE photos ADD COLUMN pixel_aspect REAL NOT NULL DEFAULT 1")
            },
        ]
        let migrated = try await LibraryIndex.open(at: url, migrations: migrations)
        let (version, columns, kept) = try await migrated.read { reader in
            let columns = try reader.database.prepare("SELECT name FROM pragma_table_info('photos')")
                .map { $0.string(at: 0) ?? "" }
            return try (reader.database.userVersion, columns, reader.setting("before"))
        }
        #expect(version == Self.version + 1 && columns.contains("pixel_aspect") && kept == "kept")
        await migrated.close()

        // Adding the column twice would fail, so opening again shows the step didn't run again.
        let again = try await LibraryIndex.open(at: url, migrations: migrations)
        defer { again.closeAndWait() }
        #expect(try await again.read { try $0.database.userVersion } == Self.version + 1)
    }

    @Test func `a migration that fails leaves the index at its version, unchanged`() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try await LibraryIndex.open(at: url).close()

        let failing = LibraryIndex.migrations + [
            { database in
                try database.execute("CREATE TABLE half_done (n INTEGER)")
                throw Failure()
            },
        ]
        await #expect(throws: Failure.self) { try await LibraryIndex.open(at: url, migrations: failing) }

        let index = try await LibraryIndex.open(at: url)
        defer { index.closeAndWait() }
        let (version, tables) = try await index.read { reader in
            try (
                reader.database.userVersion,
                reader.database.prepare("SELECT name FROM sqlite_master").map { $0.string(at: 0) ?? "" },
            )
        }
        #expect(version == Self.version && !tables.contains("half_done"))
    }

    @Test func `an index from a newer Redlamp is refused`() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try await LibraryIndex.open(at: url).close()
        try SQLiteDatabase(path: url.path).setUserVersion(Self.version + 1)

        await #expect(throws: LibraryIndexError.newerVersion(found: Self.version + 1, supported: Self.version)) {
            try await LibraryIndex.open(at: url)
        }
    }
}
