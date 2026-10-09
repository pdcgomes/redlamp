import Foundation
import Testing
@testable import RedlampLibrary

/// The count Move Edits and Metadata… shows as its sheet opens (LIB-11): a root's photos with `.redlamp` sidecars, from
/// an index of those photos by folder (schema version 8), so the first count of a launch reads no photo's row.
struct SidecarCountTests {
    /// The sheet's count, as the app asked for it before the library had it.
    static let query = """
    SELECT count(*) FROM photos WHERE sidecar_modified IS NOT NULL AND folder IN (SELECT id FROM folders WHERE root = ?)
    """

    /// Shoot's ten photos in two folders, three with sidecars, and another root's photo with one.
    static func library() async throws -> IndexSandbox {
        let sandbox = try await IndexSandbox.make()
        let folders = try await sandbox.addFolders(["Shoot", "Shoot/Day 2"])
        var photos = try (0 ..< 6).map { try PhotoRecord(folder: #require(folders["Shoot"]), name: "A\($0).JPG") }
        photos += try (0 ..< 4).map { try PhotoRecord(folder: #require(folders["Shoot/Day 2"]), name: "B\($0).JPG") }
        for number in [0, 2, 7] {
            photos[number].sidecarModified = Date(timeIntervalSince1970: 1_800_000_000)
        }
        try await sandbox.upsert(photos)
        let volume = sandbox.volume
        try await sandbox.index.write { writer in
            let other = try writer.upsertRoot(RootRecord(volume: volume, path: "/Volumes/Test/Other"))
            var photo = try PhotoRecord(
                folder: writer.upsertFolder(FolderRecord(root: other, path: "/Volumes/Test/Other/Shoot")),
                name: "C.JPG",
            )
            photo.sidecarModified = Date(timeIntervalSince1970: 1_800_000_000)
            try writer.upsertPhotos([photo])
        }
        return sandbox
    }

    @Test func `a root's photos with sidecars are counted, and no others`() async throws {
        let sandbox = try await Self.library()
        defer { sandbox.remove() }
        let root = sandbox.root
        #expect(try await sandbox.index.read { try $0.photoCount(withSidecarsInRoot: root) } == 3)
    }

    @Test func `the count reads the index of photos with sidecars, not every photo of the root`() async throws {
        let sandbox = try await Self.library()
        defer { sandbox.remove() }
        let plan = try await sandbox.index.read { reader in
            try reader.database.prepare("EXPLAIN QUERY PLAN " + Self.query).map { $0.string(at: 3) ?? "" }
        }
        // Through `(folder, name)` it visited each of the root's photos and read its row.
        #expect(plan.contains { $0.contains("photos_sidecars") }, "\(plan)")
        #expect(!plan.contains { $0.contains("sqlite_autoindex_photos_1") }, "\(plan)")
    }

    @Test func `an index from the version before gains it as it opens`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-sidecar-count-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Index.sqlite")
        let root = try await LibraryIndex
            .withOlder(at: url, migrations: Array(LibraryIndex.migrations.prefix(7))) { older in
                let (root, folder) = try await older.write { writer in
                    let volume = try writer.upsertVolume(VolumeRecord(uuid: "TEST-VOLUME", kind: .ssd))
                    let root = try writer.upsertRoot(RootRecord(volume: volume, path: "/Volumes/Test/Photos"))
                    return try (root, writer.upsertFolder(FolderRecord(root: root, path: "/Volumes/Test/Photos/Shoot")))
                }
                var photo = PhotoRecord(folder: folder, name: "A.JPG")
                photo.sidecarModified = Date(timeIntervalSince1970: 1_800_000_000)
                let photos = [photo, PhotoRecord(folder: folder, name: "B.JPG")]
                try await older.write { try $0.upsertPhotos(photos) }
                return root
            }

        let index = try await LibraryIndex.open(at: url)
        defer { index.closeAndWait() }
        let (indexed, count) = try await index.read { reader in
            let count = try reader.database.prepare(Self.query)
            try count.bind(root, at: 1)
            return try (
                reader.database.prepare("SELECT sql FROM sqlite_master WHERE name = 'photos_sidecars'")
                    .first { $0.string(at: 0) ?? "" },
                count.first { $0.int(at: 0) },
            )
        }
        #expect(indexed?.contains("WHERE sidecar_modified IS NOT NULL") == true)
        #expect(count == 1)
    }
}
