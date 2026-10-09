import Foundation
import Testing
@testable import RedlampLibrary

/// The XMP merge records of photos that leave the index other than by their root's removal (LIB-24): a photo deleted
/// on disk or moved outside the library takes its record with it as the indexer takes it out; a photo moved to the
/// Trash keeps its record while a batch of the file journal can put it back, and loses it once the journal lets the
/// batch go with the photo not back; as a root's sweep does.
struct XMPRecordSweepTests {
    static func keepRecords(of photos: [Int64], in index: LibraryIndex) async throws {
        try await index.write { writer in
            try XMPMergeRecord.save(
                Dictionary(uniqueKeysWithValues: photos.map {
                    ($0, XMPMergeRecord(other: XMPFields(), redlampFields: XMPFields()))
                }),
                dropping: [],
                in: writer,
            )
        }
    }

    static func records(of photos: [Int64], in index: LibraryIndex) async throws -> Set<Int64> {
        try await Set(index.read { try XMPMergeRecord.records(photos, in: $0) }.keys)
    }

    @Test func `a photo deleted on disk or moved out of the library takes its XMP record as it leaves the index`(
    ) async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        for path in ["Shoot/A.JPG", "Shoot/B.JPG", "Shoot/C.JPG"] {
            try sandbox.photo(path)
        }
        try await sandbox.indexAll()
        let ids = try await sandbox.ids(["Shoot/A.JPG", "Shoot/B.JPG", "Shoot/C.JPG"])
        try await Self.keepRecords(of: ids, in: sandbox.index)

        try FileManager.default.removeItem(at: sandbox.url("Shoot/A.JPG"))
        let outside = try TemporaryFolder()
        try FileManager.default.moveItem(at: sandbox.url("Shoot/B.JPG"), to: outside.url.appending(path: "B.JPG"))
        try await sandbox.indexAll()
        #expect(try await sandbox.index.read { try $0.photoCount() } == 1)
        #expect(try await Self.records(of: ids, in: sandbox.index) == [ids[2]])
    }

    @Test func `a trashed photo keeps its XMP record while Put Back can bring it back, and loses it after`(
    ) async throws {
        let (sandbox, trash) = try await FileTrashedTests.sandbox()
        defer { sandbox.remove() }
        let rows = try await sandbox.rows()
        let (emptied, putBack) = try (#require(rows["Shoot/IMG_0002.ARW"]), #require(rows["Shoot/Day 2/IMG_0003.ARW"]))
        try await Self.keepRecords(of: [emptied, putBack], in: sandbox.index)
        let operations = sandbox.operations()
        let trashed = try await operations.planTrash(photos: [emptied])
        #expect(try await operations.run(trashed).isFinished)
        let returned = try await operations.planTrash(photos: [putBack])
        #expect(try await operations.run(returned).isFinished)
        #expect(try await sandbox.index.read { try $0.photo(id: emptied) } == nil)
        #expect(try await LibraryXMP(index: sandbox.index, paths: sandbox.paths).removeOrphanedRecords() == 0)
        #expect(try await Self.records(of: [emptied, putBack], in: sandbox.index) == [emptied, putBack])

        // Past Undo's reach, the batches are kept for Put Back while their photos are in the Trash.
        for number in 0 ..< FileJournal.kept {
            try await operations.run(operations.planNewFolder(sandbox.url("Shoot/New \(number)")))
        }
        #expect(try await Self.records(of: [emptied, putBack], in: sandbox.index) == [emptied, putBack])

        // One emptied from the Trash, the other put back: the next batch lets both batches go.
        try FileManager.default.removeItem(at: trash.appending(path: "IMG_0002.ARW"))
        try await operations.run(operations.planPutBack(batch: returned.id))
        try await operations.run(operations.planNewFolder(sandbox.url("Shoot/New A")))
        let kept = try await Set(operations.entries().map(\.id))
        #expect(!kept.contains(trashed.id) && !kept.contains(returned.id))
        #expect(try await Self.records(of: [emptied, putBack], in: sandbox.index) == [putBack])
    }
}
