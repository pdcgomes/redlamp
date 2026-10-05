import Foundation
import Testing
@testable import RedlampLibrary

struct IndexSnapshotTests {
    /// A sandbox whose folder holds `count` photos.
    private func makeSandbox(photos count: Int) async throws -> (IndexSandbox, folder: Int64) {
        let sandbox = try await IndexSandbox.make()
        let folder = try #require(try await sandbox.addFolders(["Shoot"])["Shoot"])
        try await sandbox.upsert((0 ..< count).map {
            PhotoRecord(folder: folder, name: "DSC_\($0).ARW", caption: "frame \($0) of the shoot")
        })
        return (sandbox, folder)
    }

    private func overwrite(_ url: URL, from offset: Int) throws {
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let garbage = Data((0 ..< max(size - offset, 4096)).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) })
        let file = try FileHandle(forWritingTo: url)
        try file.seek(toOffset: UInt64(offset))
        try file.write(contentsOf: garbage)
        try file.close()
    }

    @Test func `snapshots keep the newest three`() async throws {
        let (sandbox, folder) = try await makeSandbox(photos: 10)
        defer { sandbox.remove() }
        var taken: [URL] = []
        for number in 0 ..< 5 {
            try await sandbox.upsert([PhotoRecord(folder: folder, name: "Extra \(number).JPG")])
            try await taken.append(sandbox.index.snapshot(to: sandbox.snapshots))
        }
        let kept = try FileManager.default.contentsOfDirectory(atPath: sandbox.snapshots.path).sorted()
        #expect(kept == taken.suffix(3).map(\.lastPathComponent))
        #expect(LibraryIndex
            .snapshotFiles(in: sandbox.snapshots, for: sandbox.url) == Array(taken.suffix(3).reversed()))

        let newest = try SQLiteDatabase(path: #require(taken.last).path, flags: .readOnly)
        #expect(try newest.prepare("SELECT count(*) FROM photos").first { $0.int(at: 0) } == 15)
        #expect(try LibraryIndex.passesQuickCheck(newest))
    }

    @Test func `a sound index opens as it is`() async throws {
        let (sandbox, _) = try await makeSandbox(photos: 10)
        defer { sandbox.remove() }
        await sandbox.index.close()
        let (index, outcome) = try await LibraryIndex.openOrRestore(at: sandbox.url, snapshots: sandbox.snapshots)
        defer { index.closeAndWait() }
        #expect(outcome == .opened)
        #expect(try await index.quickCheck())
        #expect(try await index.read { try $0.photoCount() } == 10)
    }

    @Test func `an index overwritten with garbage is restored from its newest snapshot`() async throws {
        let (sandbox, folder) = try await makeSandbox(photos: 100)
        defer { sandbox.remove() }
        try await sandbox.index.snapshot(to: sandbox.snapshots)
        try await sandbox.upsert([PhotoRecord(folder: folder, name: "After the first.JPG")])
        let newest = try await sandbox.index.snapshot(to: sandbox.snapshots)
        try await sandbox.upsert([PhotoRecord(folder: folder, name: "After the last.JPG")])
        await sandbox.index.close()
        try overwrite(sandbox.url, from: 0)

        let (index, outcome) = try await LibraryIndex.openOrRestore(at: sandbox.url, snapshots: sandbox.snapshots)
        defer { index.closeAndWait() }
        #expect(outcome == .restored(from: newest))
        #expect(try await index.read { try $0.photoCount() } == 101, "as the snapshot had it")
        #expect(try await index.read { try $0.photoIDs(matching: "frame 42") }.count == 1)
        #expect(FileManager.default.fileExists(atPath: sandbox.url.path + ".damaged"))
        try await index.write { try $0.upsertPhotos([PhotoRecord(folder: folder, name: "Restored.JPG")]) }
        #expect(try await index.read { try $0.database.userVersion } == LibraryIndex.migrations.count)
    }

    @Test func `an index damaged past its header fails its check and is restored`() async throws {
        let (sandbox, _) = try await makeSandbox(photos: 3000)
        defer { sandbox.remove() }
        let snapshot = try await sandbox.index.snapshot(to: sandbox.snapshots)
        await sandbox.index.close()
        try overwrite(sandbox.url, from: 3 * 4096)

        let (index, outcome) = try await LibraryIndex.openOrRestore(at: sandbox.url, snapshots: sandbox.snapshots)
        defer { index.closeAndWait() }
        #expect(outcome == .restored(from: snapshot))
        #expect(try await index.read { try $0.photoCount() } == 3000)
    }

    @Test func `a damaged newest snapshot is passed over for an older good one`() async throws {
        let (sandbox, folder) = try await makeSandbox(photos: 10)
        defer { sandbox.remove() }
        let older = try await sandbox.index.snapshot(to: sandbox.snapshots)
        try await sandbox.upsert([PhotoRecord(folder: folder, name: "Later.JPG")])
        let damaged = try await sandbox.index.snapshot(to: sandbox.snapshots)
        await sandbox.index.close()
        try overwrite(damaged, from: 0)
        try overwrite(sandbox.url, from: 0)

        let (index, outcome) = try await LibraryIndex.openOrRestore(at: sandbox.url, snapshots: sandbox.snapshots)
        defer { index.closeAndWait() }
        #expect(outcome == .restored(from: older))
        #expect(try await index.read { try $0.photoCount() } == 10)
    }

    @Test func `with no good snapshot, a damaged index is replaced by an empty one to rebuild`() async throws {
        let (sandbox, _) = try await makeSandbox(photos: 10)
        defer { sandbox.remove() }
        await sandbox.index.close()
        try overwrite(sandbox.url, from: 0)

        let (index, outcome) = try await LibraryIndex.openOrRestore(at: sandbox.url, snapshots: sandbox.snapshots)
        defer { index.closeAndWait() }
        #expect(outcome == .rebuilt)
        #expect(try await index.read { try $0.photoCount() } == 0)
        #expect(try await index.quickCheck())
        #expect(try await index.read { try $0.database.userVersion } == LibraryIndex.migrations.count)
    }
}
