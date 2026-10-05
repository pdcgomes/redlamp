import Foundation
import Testing
@testable import RedlampLibrary

/// Version 2 of the index's schema (LIB-06): the text index holds names, keywords, titles and
/// captions, and there's no index on the content key.
struct QueryIndexMigrationTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "redlamp-migration-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var url: URL {
        directory.appending(path: "Index.sqlite")
    }

    private static let key = Data((0 ..< 16).map { UInt8($0 * 3) })

    /// An index at version 1 with a photo whose text is in all seven of that version's columns.
    private func makeVersion1() async throws -> Int64 {
        let index = try await LibraryIndex.open(at: url, migrations: [LibraryIndex.createVersion1])
        let id = try await index.write { writer in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "MIGRATION", kind: .ssd))
            let root = try writer.upsertRoot(RootRecord(volume: volume, path: "/Volumes/Test/Photos"))
            let folder = try writer.upsertFolder(FolderRecord(root: root, path: "/Volumes/Test/Photos/Lisbon Trip"))
            let id = try writer.upsertPhotos([PhotoRecord(
                folder: folder, name: "DSCF4821.RAF", contentKey: Self.key,
                camera: writer.cameraID(for: "Fujifilm X-T5"),
                lens: writer.lensID(for: "XF35mmF1.4 R"), title: "Tram 28", caption: "Alfama at dusk",
            )])[0]
            try writer.setKeywords(["Places/Portugal"], forPhoto: id)
            try writer.database.execute("""
            DELETE FROM photo_text;
            INSERT INTO photo_text (rowid, name, folder, keywords, title, caption, camera, lens)
              SELECT id, name, folder, keywords, title, caption, camera, lens FROM photo_text_rows;
            """)
            return id
        }
        #expect(try await index.read { try $0.photoIDs(matching: "lisbon") } == [id], "version 1 searched folders")
        await index.close()
        return id
    }

    @Test func `version 2 searches names, keywords, titles and captions, keeps content keys and drops their index`(
    ) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try await makeVersion1()

        let index = try await LibraryIndex.open(at: url)
        defer { index.closeAndWait() }
        let (version, columns, keyIndexes, key) = try await index.read { reader in
            try (
                reader.database.userVersion,
                reader.database.prepare("SELECT name FROM pragma_table_info('photo_text')").map { $0.string(at: 0) },
                reader.database.prepare("SELECT count(*) FROM sqlite_master WHERE name = 'photos_content_key'")
                    .first { $0.int(at: 0) },
                reader.photo(id: id)?.contentKey,
            )
        }
        #expect(version == 3 && LibraryIndex.migrations.count == 3)
        #expect(columns == ["name", "keywords", "title", "caption"])
        #expect(keyIndexes == 0 && key == Self.key)

        let searches = ["4821", "portugal", "tram 2", "alfama", "lisbon", "x-t5", "35mm"]
        let found = try await index.read { reader in try searches.map { try reader.photoIDs(matching: $0) } }
        #expect(found == [[id], [id], [id], [id], [], [], []])
    }

    @Test func `after the migration, the writer keeps the four columns in step`() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try await makeVersion1()
        let index = try await LibraryIndex.open(at: url)
        defer { index.closeAndWait() }

        try await index.write { writer in
            let folder = try #require(try writer.photo(id: id)?.folder)
            try writer.movePhoto(id, toFolder: folder, name: "Ribeira.RAF")
            try writer.addKeyword("Events/Festival", toPhotos: [id])
            var photo = try #require(try writer.photo(id: id))
            photo.caption = "Fado at night"
            try writer.upsertPhotos([photo])
        }
        let searches = ["4821", "ribeira", "festival", "portugal", "fado", "alfama", "tram 2"]
        let found = try await index.read { reader in try searches.map { try reader.photoIDs(matching: $0) } }
        #expect(found == [[], [id], [id], [id], [id], [], [id]])
    }
}
