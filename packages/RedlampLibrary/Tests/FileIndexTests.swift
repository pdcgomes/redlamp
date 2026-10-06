import Foundation
import Testing
@testable import RedlampLibrary

/// The file operations write what they do to the index themselves (LIB-26): after each batch and
/// each Undo, indexing every folder again finds nothing to change, so the folders change tracking
/// lists again for their events have nothing more to give.
struct FileIndexTests {
    /// What indexing every folder again changed, by what it is, after `step`; empty when nothing.
    private static func changes(after step: String, _ indexer: LibraryIndexer, _ sandbox: IndexerSandbox) async
        -> [String] {
        let run = await IndexerRun.collect(indexer.index([sandbox.root]))
        guard let summary = run.summary else { return ["\(step): no summary"] }
        let counts = [
            ("inserted", summary.photosInserted), ("updated", summary.photosUpdated),
            ("moved", summary.photosMoved), ("removed", summary.photosRemoved), ("read", summary.headsRead),
            ("folders removed", summary.foldersRemoved), ("failed", summary.failures),
        ]
        return counts.filter { $0.1 != 0 }.map { "\(step): \($0.1) \($0.0)" } + run.failures
    }

    private static func ids(_ photos: [FixturePhoto], in sandbox: IndexerSandbox) async throws -> [Int64] {
        let paths = photos.map { sandbox.path($0.path) }
        return try await sandbox.index.read { reader in try paths.compactMap { try reader.photo(path: $0)?.id } }
    }

    /// The fixture's folders with at least three photos and no folders below them.
    private static func leaves(_ sandbox: IndexerSandbox) -> [LibraryFixture.Folder] {
        let all = sandbox.fixture.folders
        return all.filter { folder in
            folder.photos.count >= 3 && !all.contains { $0.path.hasPrefix(folder.path + "/") }
        }
    }

    @Test func `each batch and its Undo leave the index as indexing the folders again finds it`() async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 300, seed: 48, shapes: [.clients]))
        defer { sandbox.remove() }
        let simulated = SimulatedFileSystem(profile: .ssd)
        simulated.useTrash(sandbox.indexFolder.appending(path: "Trash", directoryHint: .isDirectory))
        let indexer = LibraryIndexer(index: sandbox.index, fileSystem: simulated, configuration: .testing())
        let indexed = await IndexerRun.collect(indexer.index([sandbox.root]))
        try #require(indexed.failures.isEmpty && indexed.summary?.photosInserted == 300, "\(indexed.failures)")
        let operations = FileOperations(index: sandbox.index, fileSystem: simulated)
        let before = try await LibraryIndexerTests.rows(sandbox)

        let folders = Self.leaves(sandbox)
        try #require(folders.count >= 4)
        let url = { (path: String) in sandbox.root.appending(path: path, directoryHint: .isDirectory) }
        let photos = folders.filter { $0 != folders[2] && $0 != folders[3] }.flatMap(sandbox.fixture.photos(in:))
        let accompanied = try await Self.ids(photos.filter { $0.sidecar != nil || $0.xmp != nil }, in: sandbox)
        try #require(accompanied.count >= 4, "photos with sidecars and .xmp to take along")

        let renamed = try await operations.renamePreview(
            NamingTemplate(parsing: "Renamed-{sequence:3}"),
            photos: Self.ids(sandbox.fixture.photos(in: folders[0]), in: sandbox),
        )
        #expect(try await operations.run(operations.planRename(renamed)).isFinished)
        var found = await Self.changes(after: "rename", indexer, sandbox)
        let moved = Array(accompanied.prefix(accompanied.count / 2))
        #expect(try await operations.run(operations.planMove(photos: moved, to: url(folders[2].path))).isFinished)
        found += await Self.changes(after: "move", indexer, sandbox)
        #expect(try await operations.run(operations.planTrash(photos: Array(accompanied.suffix(2)))).isFinished)
        found += await Self.changes(after: "trash", indexer, sandbox)
        let folder = url("Moved")
        #expect(try await operations.run(operations.planNewFolder(folder)).isFinished)
        found += await Self.changes(after: "new folder", indexer, sandbox)
        let source = url(folders[3].path)
        #expect(try await operations.run(operations.planMove(
            folder: source, to: folder.appending(path: source.lastPathComponent),
        )).isFinished)
        found += await Self.changes(after: "folder moved", indexer, sandbox)

        for step in ["folder moved", "new folder", "trash", "move", "rename"] {
            #expect(try await operations.undo().isFinished, "\(step)'s Undo")
            found += await Self.changes(after: "\(step)'s Undo", indexer, sandbox)
        }
        #expect(found.isEmpty, "\(found)")
        let after = try await LibraryIndexerTests.rows(sandbox)
        #expect(after.mapValues(\.id) == before.mapValues(\.id), "every photo back where it was, under its ID")
    }

    @Test func `photos put back from the Trash, and the Put Back's Undo, leave the index as indexing finds it`(
    ) async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 150, seed: 49, shapes: [.clients]))
        defer { sandbox.remove() }
        let simulated = SimulatedFileSystem(profile: .ssd)
        simulated.useTrash(sandbox.indexFolder.appending(path: "Trash", directoryHint: .isDirectory))
        let indexer = LibraryIndexer(index: sandbox.index, fileSystem: simulated, configuration: .testing())
        let indexed = await IndexerRun.collect(indexer.index([sandbox.root]))
        try #require(indexed.failures.isEmpty && indexed.summary?.photosInserted == 150, "\(indexed.failures)")
        let operations = FileOperations(index: sandbox.index, fileSystem: simulated)
        let before = try await LibraryIndexerTests.rows(sandbox)

        let folders = Self.leaves(sandbox)
        try #require(folders.count >= 2)
        let photos = folders.prefix(2).flatMap(sandbox.fixture.photos(in:))
        try #require(photos.contains { $0.sidecar != nil || $0.xmp != nil }, "photos with sidecars and .xmp")
        let trashing = try await operations.planTrash(photos: Self.ids(photos, in: sandbox))
        #expect(try await operations.run(trashing).isFinished)
        var found = await Self.changes(after: "trash", indexer, sandbox)
        // The first folder, left empty, removed outside Redlamp, and the index told.
        try FileManager.default.removeItem(at: sandbox.root.appending(path: folders[0].path))
        _ = await IndexerRun.collect(indexer.index([sandbox.root]))

        let listed = try await operations.trashed()
        #expect(listed.count == photos.count)
        let some = listed.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element.id)
        #expect(try await operations.run(operations.planPutBack(some)).isFinished)
        found += await Self.changes(after: "put back", indexer, sandbox)
        #expect(try await operations.run(operations.planPutBack(batch: trashing.id)).isFinished)
        found += await Self.changes(after: "put back, the rest", indexer, sandbox)
        #expect(try await operations.undo().isFinished)
        found += await Self.changes(after: "Put Back's Undo", indexer, sandbox)
        #expect(try await operations.run(operations.planPutBack(operations.trashed().map(\.id))).isFinished)
        found += await Self.changes(after: "put back again", indexer, sandbox)

        #expect(found.isEmpty, "\(found)")
        #expect(try await operations.trashed().isEmpty)
        let after = try await LibraryIndexerTests.rows(sandbox)
        #expect(after.mapValues(\.id) == before.mapValues(\.id), "every photo back where it was, under its ID")
        #expect(after.mapValues(\.contentKey) == before.mapValues(\.contentKey))
    }
}
