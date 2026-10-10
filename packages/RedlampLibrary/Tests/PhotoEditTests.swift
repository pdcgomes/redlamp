import Foundation
import Testing
@testable import RedlampLibrary

/// The edits whose renders the store holds, as the index records them (LIB-17, schema version 10): a photo's record
/// stands for its edit while the photo's row has the sidecar date it was recorded with, for the way of rendering that
/// recorded it, so a relaunch finds the photo's render before its sidecar is read again.
struct PhotoEditTests {
    static let read = Date(timeIntervalSince1970: 1_800_000_000.123456)

    static func digest(_ byte: UInt8) -> EditDigest {
        EditDigest(data: Data(repeating: byte, count: 16))!
    }

    /// Three photos of a folder, the first two edited.
    static func library() async throws -> (sandbox: IndexSandbox, ids: [Int64]) {
        let sandbox = try await IndexSandbox.make()
        let folders = try await sandbox.addFolders(["Shoot"])
        let folder = try #require(folders["Shoot"])
        var photos = (0 ..< 3).map { PhotoRecord(folder: folder, name: "IMG_\($0).JPG") }
        for number in 0 ..< 2 {
            photos[number].sidecarModified = read
            photos[number].edited = true
        }
        return try await (sandbox, sandbox.upsert(photos))
    }

    static func standing(
        _ sandbox: IndexSandbox,
        _ ids: [Int64],
        renderer: Int = 1,
    ) async throws -> [Int64: EditDigest] {
        try await sandbox.index.read { try $0.standingPhotoEdits(ofPhotos: ids, renderer: renderer) }
    }

    @Test func `a recorded edit stands for its photo while the sidecar's date holds, for the renderer that recorded it`(
    ) async throws {
        let (sandbox, ids) = try await Self.library()
        defer { sandbox.remove() }
        let recorded = try await sandbox.index.write { writer in
            try [
                // The date as the app has it, within a millisecond of the row's.
                writer.setPhotoEdit(
                    Self.digest(1),
                    ofPhoto: ids[0],
                    sidecarModified: Self.read.addingTimeInterval(4e-4),
                    renderer: 1,
                ),
                writer.setPhotoEdit(
                    Self.digest(2),
                    ofPhoto: ids[1],
                    sidecarModified: Self.read.addingTimeInterval(1),
                    renderer: 1,
                ),
                writer.setPhotoEdit(Self.digest(3), ofPhoto: ids[2], sidecarModified: Self.read, renderer: 1),
            ]
        }
        #expect(recorded == [true, false, false], "a sidecar saved since, or none, records nothing")
        #expect(try await Self.standing(sandbox, ids) == [ids[0]: Self.digest(1)])
        #expect(try await Self.standing(sandbox, ids, renderer: 2).isEmpty, "edits rendered another way stand for none")
        let first = try await sandbox.index.read { try $0.photo(id: ids[0]) }
        let folder = try #require(first?.folder)
        let inFolder = try await sandbox.index.read { try $0.standingPhotoEdits(inFolders: [folder], renderer: 1) }
        #expect(inFolder == [ids[0]: Self.digest(1)], "a folder's photos' at once")
        let (edits, row) = try await sandbox.index.read { try ($0.photoEdits(ids), $0.photo(id: ids[0])) }
        let edit = try #require(edits[ids[0]])
        #expect(edit.digest == Self.digest(1) && edit.renderer == 1)
        #expect(try edit.stands(for: #require(row)), "kept with the row's own date")

        // The sidecar saved again: the record stands for nothing until the edit is recorded again.
        let saved = Self.read.addingTimeInterval(5)
        try await sandbox.index.write { writer in
            let row = try writer.photo(id: ids[0])
            var changed = try #require(row)
            changed.sidecarModified = saved
            try writer.upsertPhotos([changed])
        }
        #expect(try await Self.standing(sandbox, ids).isEmpty)
        let changed = try await sandbox.index.read { try $0.photo(id: ids[0]) }
        #expect(try !edit.stands(for: #require(changed)))
        try await sandbox.index.write { try $0.setPhotoEdit(
            Self.digest(4),
            ofPhoto: ids[0],
            sidecarModified: saved,
            renderer: 1,
        ) }
        #expect(try await Self.standing(sandbox, ids) == [ids[0]: Self.digest(4)], "in place of the one before")

        try await sandbox.index.write { try $0.removePhotoEdits([ids[0]]) }
        #expect(try await sandbox.index.read { try $0.photoEdits(ids) }.isEmpty)
    }

    @Test func `records outlive their photos while a batch can bring them back, and go with what's kept beside them`(
    ) async throws {
        let (sandbox, ids) = try await Self.library()
        defer { sandbox.remove() }
        try await sandbox.index.write { writer in
            for (number, id) in ids.prefix(2).enumerated() {
                try writer.setPhotoEdit(
                    Self.digest(UInt8(number + 1)),
                    ofPhoto: id,
                    sidecarModified: Self.read,
                    renderer: 1,
                )
            }
            try writer.deletePhotos(Array(ids.prefix(2)))
        }
        #expect(try await sandbox.index.read { try $0.photoEdits(ids) }.count == 2, "kept for a photo put back")

        try await sandbox.index.write { try $0.removeOrphanedHealth(keeping: [ids[1]]) }
        #expect(try await Set(sandbox.index.read { try $0.photoEdits(ids) }.keys) == [ids[1]])
        try await sandbox.index.write { try $0.removeRecords(ofPhotos: [ids[1]]) }
        #expect(try await sandbox.index.read { try $0.photoEdits(ids) }.isEmpty)
    }

    @Test func `an index at version 8 gains stacks' places, then the table, and each step finds its own there if run again`(
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-photo-edits-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Index.sqlite")
        #expect(LibraryIndex.schemaVersion == 10)
        let older = try await LibraryIndex.open(at: url, migrations: Array(LibraryIndex.migrations.prefix(8)))
        #expect(try await older.read { try $0.database.userVersion } == 8)
        await older.close()

        let index = try await LibraryIndex.open(at: url)
        let (tables, columns) = try await index.read { reader in
            try (
                reader.database.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").map { $0.string(at: 0) },
                reader.database.prepare("SELECT name FROM pragma_table_info('photos')").map { $0.string(at: 0) },
            )
        }
        #expect(columns.contains("stack_position"), "version 9")
        #expect(tables.contains("photo_edits"), "version 10")
        #expect(try await index.read { try $0.database.userVersion } == 10)
        await index.close()

        for version in [9, 8] {
            do {
                let rewound = try SQLiteDatabase(path: url.path)
                try rewound.setUserVersion(version)
            }
            let again = try await LibraryIndex.open(at: url)
            #expect(try await again.read { try $0.database.userVersion } == 10, "from version \(version) again")
            await again.close()
        }
    }
}
