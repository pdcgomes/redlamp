import Foundation
import Testing
@testable import RedlampLibrary

/// The root sweep's writes (LIB-05, LIB-10): a batch holds the writer only as long as its own deletions take, without
/// the text index's merging, which FTS5 had done in the batch's commit, 3,000 pages and 1.3 s at a million photos;
/// the merges follow the batches a step at a time (`IndexTextMerges`), and the sweep finishes once they're done.
struct RootSweepTests {
    /// The text index's segments, from FTS5's structure record.
    static func textSegments(_ index: LibraryIndex) async throws -> Int {
        try #require(try await index.textStructure()).segments
    }

    /// A root of 100 photos to take out, Gone, its photos' text written five transactions at a time, so the text
    /// index holds a segment for each that isn't merged yet when the merges don't follow writes; and Kept's 10 photos.
    static func library(merging: Bool = true) async throws -> (sandbox: IndexSandbox, gone: [Int64], kept: [Int64]) {
        let sandbox = try await IndexSandbox.make(textMerges: IndexTextMerges.Limits(following: merging))
        let kept = try #require(try await sandbox.addFolders(["Kept"])["Kept"])
        let keptIDs = try await sandbox.upsert((0 ..< 10).map { PhotoRecord(folder: kept, name: "Kept \($0).JPG") })
        let volume = sandbox.volume
        let folder = try await sandbox.index.write { writer in
            let root = try writer.upsertRoot(RootRecord(volume: volume, path: "/Volumes/Test/Gone"))
            return try writer.upsertFolder(FolderRecord(root: root, path: "/Volumes/Test/Gone/Shoot"))
        }
        var gone: [Int64] = []
        for part in 0 ..< 5 {
            try await gone += sandbox.upsert((0 ..< 20).map {
                PhotoRecord(folder: folder, name: "Gone \(part * 20 + $0).JPG")
            })
        }
        _ = try await sandbox.index.write { try $0.markRemoved("/Volumes/Test/Gone", keeping: [IndexSandbox.rootPath]) }
        return (sandbox, gone, keptIDs)
    }

    @Test func `a sweep's batch takes its photos' text out without merging the text index`() async throws {
        let (sandbox, gone, kept) = try await Self.library(merging: false)
        defer { sandbox.remove() }
        let segments = try await Self.textSegments(sandbox.index)
        #expect(segments >= 6, "a segment for each of the six transactions that wrote text")

        let sweep = try await sandbox.index.write { try $0.sweepRemoved(limit: 1000) }
        #expect(sweep.photos.sorted() == gone)
        // FTS5 took each of the 100 rows deleted for a page written, and merged the six segments in the commit.
        #expect(try await Self.textSegments(sandbox.index) == segments)
        let (found, automerge) = try await sandbox.index.read { reader in
            try (
                reader.photoIDs(matching: "gone").count + reader.photoIDs(matching: "kept").count,
                reader.database.prepare("SELECT v FROM photo_text_config WHERE k = 'automerge'")
                    .first { $0.int(at: 0) },
            )
        }
        #expect(found == kept.count)
        #expect(automerge == 0, "FTS5's merging off for every writer")
    }

    @Test func `the sweep finishes once the text index has nothing left to merge`() async throws {
        let (sandbox, _, kept) = try await Self.library()
        defer { sandbox.remove() }
        let indexer = LibraryIndexer(index: sandbox.index, configuration: .testing(batchSize: 30))
        let run = await IndexerRun.collect(indexer.sweepRemovedRoots())
        #expect(run.summary?.photosRemoved == 100)
        #expect(try await Self.textSegments(sandbox.index) < 6)
        let (merged, found) = try await sandbox.index.write { writer in
            try (writer.mergeText(pages: 16), writer.photoIDs(matching: "kept"))
        }
        #expect(!merged)
        #expect(found.sorted() == kept)
    }

    @Test func `a batch of the sweep stops at its budget's end, and the next takes the rest`() async throws {
        let (sandbox, gone, _) = try await Self.library()
        defer { sandbox.remove() }
        let first = try await sandbox.index.write { try $0.sweepRemoved(limit: 1000, budget: .zero) }
        #expect(first.photos.count == LibraryIndex.Writer.sweepPart && first.more)
        let rest = try await sandbox.index.write { try $0.sweepRemoved(limit: 1000) }
        #expect(Set(rest.photos).union(first.photos) == Set(gone))
    }
}
