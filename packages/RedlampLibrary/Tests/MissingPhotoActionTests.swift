import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Library Health's Missing check acting (DEC-59): Remove takes missing photos out of the library with nothing moved,
/// and Locate… relinks a photo to a file with its content, with the others of its folder found beside it; each one
/// journaled batch, checked before it runs, which one Undo takes back.
struct MissingPhotoActionTests {
    typealias Library = MissingPhotoTests

    /// What the index has of a photo: its row, keywords and collections.
    static func held(_ id: Int64, _ sandbox: KeywordSandbox) async throws -> (PhotoRecord?, [String], [String]) {
        try await sandbox.index.read { reader in
            try (reader.photo(id: id), reader.keywords(forPhoto: id), reader.collections(ofPhoto: id).map(\.text))
        }
    }

    static func health(_ sandbox: KeywordSandbox) -> (LibraryHealth, FileOperations) {
        let operations = FileOperations(index: sandbox.index, paths: sandbox.paths)
        return (LibraryHealth(operations: operations), operations)
    }

    @Test func `Remove takes missing photos out with nothing moved, and Undo puts them back as they were`(
    ) async throws {
        let (sandbox, ids) = try await Library.library()
        defer { sandbox.remove() }
        let (first, third) = try (#require(ids[Library.paths[0]]), #require(ids[Library.paths[2]]))
        try await LibraryMetadata(index: sandbox.index, paths: sandbox.paths).collections
            .apply(.add([first], to: Library.portfolio))
        try FileManager.default.removeItem(at: sandbox.url(Library.paths[0]))
        try await sandbox.indexAll()
        let before = try await Self.held(first, sandbox)
        let files = Set(FileManager.default.subpaths(atPath: sandbox.root.path) ?? [])

        let (health, operations) = Self.health(sandbox)
        let findings = try await health.findings(.missing)
        let plan = try await health.planRemoval([first, third], in: findings)
        #expect(plan.photos == [first], "a photo that isn't missing is left out")
        #expect(plan.batch.kind == .remove && plan.batch.title == "Remove 1 missing photo")
        #expect(try await health.run(plan).isFinished)
        #expect(try await Self.held(first, sandbox).0 == nil)
        #expect(try await health.findings(.missing).isEmpty)
        #expect(Set(FileManager.default.subpaths(atPath: sandbox.root.path) ?? []) == files, "nothing moved")

        #expect(try await operations.undo().isFinished)
        let after = try await Self.held(first, sandbox)
        #expect(after.0 == before.0 && after.1 == before.1 && after.2 == before.2, "back as it was, missing")
        try await health.engine.updateNames()
        #expect(try await health.findings(.missing).photos == [first])
    }

    @Test func `Remove's batch is checked again before it runs: a photo found since stops it, lists caught up or not`(
    ) async throws {
        let (sandbox, ids) = try await Library.library()
        defer { sandbox.remove() }
        let first = try #require(ids[Library.paths[0]])
        let outside = try TemporaryFolder()
        let away = outside.url.appending(path: "IMG_0001.ARW")
        try FileManager.default.moveItem(at: sandbox.url(Library.paths[0]), to: away)
        try await sandbox.indexAll()
        let (health, _) = Self.health(sandbox)
        let plan = try await health.planRemoval([first], in: health.findings(.missing))
        try FileManager.default.moveItem(at: away, to: sandbox.url(Library.paths[0]))
        try await sandbox.indexAll()
        await #expect(throws: HealthError.self) { try await health.run(plan) }
        #expect(try await Self.held(first, sandbox).0?.state == [])
    }

    @Test func `Locate… relinks a photo to a file with its content, with the others found beside it, and Undo takes it back`(
    ) async throws {
        let (sandbox, ids) = try await Library.library()
        defer { sandbox.remove() }
        let (first, second) = try (#require(ids[Library.paths[0]]), #require(ids[Library.paths[1]]))
        try await LibraryMetadata(index: sandbox.index, paths: sandbox.paths).collections
            .apply(.add([first], to: Library.portfolio))
        // Copies elsewhere in the library, say from a backup, then the originals deleted: the first's sidecar stays
        // behind, the second's goes with it.
        let found = sandbox.url("Found")
        try FileManager.default.createDirectory(at: found, withIntermediateDirectories: true)
        for name in ["IMG_0001.ARW", "IMG_0002.ARW"] {
            try FileManager.default.copyItem(at: sandbox.url("Shoot/" + name), to: found.appending(path: name))
        }
        try FileManager.default.removeItem(at: sandbox.url(Library.paths[0]))
        try FileManager.default.removeItem(at: sandbox.url(Library.paths[1]))
        try FileManager.default.removeItem(at: sandbox.url(Library.paths[1] + ".redlamp"))
        try await sandbox.indexAll()
        let copies = try await sandbox.ids(["Found/IMG_0001.ARW", "Found/IMG_0002.ARW"])
        let before = try await (Self.held(first, sandbox), Self.held(second, sandbox))
        let (health, operations) = Self.health(sandbox)

        #expect(try await health.locate(first, at: sandbox.url("Other/IMG_0100.ARW")).problem == .differs)
        let outside = try TemporaryFolder()
        try FileManager.default.copyItem(
            at: found.appending(path: "IMG_0001.ARW"),
            to: outside.url.appending(path: "A.ARW"),
        )
        #expect(try await health.locate(first, at: outside.url.appending(path: "A.ARW")).problem == .notInLibrary)
        let location = try await health.locate(first, at: found.appending(path: "IMG_0001.ARW"))
        let foundPath = LibraryIndexer.path(found)
        #expect(location.photo == PhotoRelink(id: first, path: foundPath + "/IMG_0001.ARW"))
        #expect(location.others == [PhotoRelink(id: second, path: foundPath + "/IMG_0002.ARW")])

        let plan = try await health.planRelink(
            [#require(location.photo)] + location.others, in: health.findings(.missing),
        )
        #expect(plan.batch.title == "Relink 2 missing photos" && Set(plan.photos) == [first, second])
        let relinks = plan.batch.steps.filter { $0.kind == .relink }
        #expect(relinks.first { $0.photos.first?.id == first }?.items.contains { $0.role == .sidecar } == true)
        #expect(relinks.first { $0.photos.first?.id == second }?.writesDecisions == true)
        #expect(try await health.run(plan).isFinished)

        let relinked = try #require(await Self.held(first, sandbox).0)
        let foundID = try await sandbox.index.read { try $0.folder(path: foundPath)?.id }
        #expect(relinked.folder == foundID && relinked.state.isEmpty && relinked.missingSince == nil)
        #expect(try await sandbox.index.read { reader in try copies.compactMap { try reader.photo(id: $0) } }.isEmpty)
        #expect(FileManager.default.fileExists(atPath: found.appending(path: "IMG_0001.ARW.redlamp").path))
        #expect(!FileManager.default.fileExists(atPath: sandbox.url(Library.paths[0] + ".redlamp").path))
        #expect(sandbox.sidecar("Found/IMG_0002.ARW")?.metadata?.keywords == ["Places/Lisbon"])

        // Read again from the files, each keeps what was decided about it.
        try await sandbox.indexAll()
        let (firstAfter, secondAfter) = try await (Self.held(first, sandbox), Self.held(second, sandbox))
        #expect(firstAfter.0?.rating == 4 && firstAfter.1 == ["Places/Lisbon"] && firstAfter.2 == ["Portfolio"])
        #expect(secondAfter.1 == ["Places/Lisbon"] && secondAfter.0?.name == "IMG_0002.ARW")
        #expect(try await health.findings(.missing).isEmpty)

        #expect(try await operations.undo().isFinished)
        let undone = try await (Self.held(first, sandbox), Self.held(second, sandbox))
        #expect(undone.0.0 == before.0.0 && undone.0.1 == before.0.1 && undone.0.2 == before.0.2)
        #expect(undone.1.0 == before.1.0, "missing again where it was")
        #expect(try await sandbox.index.read { reader in
            try copies.compactMap { try reader.photo(id: $0)?.id }
        } == copies)
        #expect(FileManager.default.fileExists(atPath: sandbox.url(Library.paths[0] + ".redlamp").path))
        try await health.engine.updateNames()
        #expect(try await Set(health.findings(.missing).photos) == [first, second])
    }
}
