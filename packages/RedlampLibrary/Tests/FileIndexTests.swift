import Foundation
import Testing
@testable import RedlampLibrary

/// The file operations write what they do to the index themselves (LIB-26): after each batch and
/// each Undo, indexing every folder again finds nothing to change, so the folders change tracking
/// lists again for their events have nothing more to give.
struct FileIndexTests {
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

        /// What indexing every folder again changed, by what it is, after `step`; empty when nothing.
        func changes(after step: String) async -> [String] {
            let run = await IndexerRun.collect(indexer.index([sandbox.root]))
            guard let summary = run.summary else { return ["\(step): no summary"] }
            let counts = [
                ("inserted", summary.photosInserted), ("updated", summary.photosUpdated),
                ("moved", summary.photosMoved), ("removed", summary.photosRemoved), ("read", summary.headsRead),
                ("folders removed", summary.foldersRemoved), ("failed", summary.failures),
            ]
            return counts.filter { $0.1 != 0 }.map { "\(step): \($0.1) \($0.0)" } + run.failures
        }
        func ids(_ photos: [FixturePhoto]) async throws -> [Int64] {
            let paths = photos.map { sandbox.path($0.path) }
            return try await sandbox.index.read { reader in try paths.compactMap { try reader.photo(path: $0)?.id } }
        }

        let all = sandbox.fixture.folders
        let folders = all.filter { folder in
            folder.photos.count >= 3 && !all.contains { $0.path.hasPrefix(folder.path + "/") }
        }
        try #require(folders.count >= 4)
        let url = { (path: String) in sandbox.root.appending(path: path, directoryHint: .isDirectory) }
        let photos = folders.filter { $0 != folders[2] && $0 != folders[3] }.flatMap(sandbox.fixture.photos(in:))
        let accompanied = try await ids(photos.filter { $0.sidecar != nil || $0.xmp != nil })
        try #require(accompanied.count >= 4, "photos with sidecars and .xmp to take along")

        let renamed = try await operations.renamePreview(
            NamingTemplate(parsing: "Renamed-{sequence:3}"), photos: ids(sandbox.fixture.photos(in: folders[0])),
        )
        #expect(try await operations.run(operations.planRename(renamed)).isFinished)
        var found = await changes(after: "rename")
        let moved = Array(accompanied.prefix(accompanied.count / 2))
        #expect(try await operations.run(operations.planMove(photos: moved, to: url(folders[2].path))).isFinished)
        found += await changes(after: "move")
        #expect(try await operations.run(operations.planTrash(photos: Array(accompanied.suffix(2)))).isFinished)
        found += await changes(after: "trash")
        let folder = url("Moved")
        #expect(try await operations.run(operations.planNewFolder(folder)).isFinished)
        found += await changes(after: "new folder")
        let source = url(folders[3].path)
        #expect(try await operations.run(operations.planMove(
            folder: source, to: folder.appending(path: source.lastPathComponent),
        )).isFinished)
        found += await changes(after: "folder moved")

        for step in ["folder moved", "new folder", "trash", "move", "rename"] {
            #expect(try await operations.undo().isFinished, "\(step)'s Undo")
            found += await changes(after: "\(step)'s Undo")
        }
        #expect(found.isEmpty, "\(found)")
        let after = try await LibraryIndexerTests.rows(sandbox)
        #expect(after.mapValues(\.id) == before.mapValues(\.id), "every photo back where it was, under its ID")
    }
}
