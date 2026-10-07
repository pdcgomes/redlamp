import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import RedlampLibrary

struct DuplicateConfirmationTests {
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    @Test func `a full hash that differs splits a candidate group, and the other copies stay duplicates`(
    ) async throws {
        let sandbox = try await DuplicateSandbox.make()
        defer { sandbox.remove() }
        let original = duplicateBytes(2_500_000, seed: 3)
        var changed = original
        // Past the content key's first 64 KiB, so the key and size still agree.
        changed[2_000_000] ^= 0xFF
        try sandbox.write("A/IMG_0001.JPG", original)
        try sandbox.write("B/IMG_0001.JPG", original)
        try sandbox.write("C/IMG_0001.JPG", changed)
        try await sandbox.indexAll()
        let (a, b, c) = try await (
            sandbox.id("A/IMG_0001.JPG"),
            sandbox.id("B/IMG_0001.JPG"),
            sandbox.id("C/IMG_0001.JPG"),
        )

        let finder = sandbox.finder()
        let candidates = try await finder.candidates()
        #expect(candidates.groups.map(\.photos) == [[a, b, c].sorted()])
        let reports = Mutex<[DuplicateFinder.Progress]>([])
        let confirmation = try await finder.confirm(candidates) { progress in
            reports.withLock { $0.append(progress) }
        }
        let key = try #require(candidates.groups.first?.contentKey)
        #expect(confirmation.duplicates == [
            DuplicateGroup(sha256: Self.sha256(original), contentKey: key, size: 2_500_000, photos: [a, b].sorted()),
        ])
        #expect(confirmation.different == [c] && confirmation.unconfirmed.isEmpty)
        let statuses = confirmation.groups.first?.candidates.first { $0.photo == c }?.status
        #expect(statuses == .different(sha256: Self.sha256(changed)))
        #expect(confirmation.hashed == 3 && confirmation.reused == 0 && confirmation.bytesRead == 7_500_000)
        let last = try #require(reports.withLock { $0.last })
        #expect(last.candidates == 3 && last.done == 3 && last.bytes == 7_500_000 && last.bytesRead == 7_500_000)

        let review = try await finder.review(confirmation)
        #expect(review.groups.map { $0.copies.map(\.photo) } == [[a, b]])
        #expect(review.different.map(\.photo) == [c] && review.reclaimable == 2_500_000)
        #expect(review.groups.first?.copies.map(\.url.path) == [
            sandbox.url("A/IMG_0001.JPG").path,
            sandbox.url("B/IMG_0001.JPG").path,
        ])
    }

    @Test func `an unchanged file isn't hashed again, and a changed one is`() async throws {
        let sandbox = try await DuplicateSandbox.make()
        defer { sandbox.remove() }
        let x = duplicateBytes(1_200_000, seed: 4)
        let y = duplicateBytes(90000, seed: 5)
        for folder in ["A", "B", "C"] {
            try sandbox.write("\(folder)/X.JPG", x)
        }
        for folder in ["A", "B"] {
            try sandbox.write("\(folder)/Y.JPG", y)
        }
        try await sandbox.indexAll()
        let counting = CountingFileSystem()
        let finder = sandbox.finder(counting)

        let first = try await finder.confirm(finder.candidates())
        #expect(first.hashed == 5 && first.reused == 0 && first.duplicates.count == 2)
        #expect(try await sandbox.index.read { try $0.photoHashCount() } == 5)

        counting.reset()
        let second = try await finder.confirm(finder.candidates())
        #expect(second.hashed == 0 && second.reused == 5 && second.bytesRead == 0)
        #expect(second.duplicates == first.duplicates)
        #expect(counting.counts.read == 0 && counting.counts.attributes == 5)

        // C's X changes past its first 64 KiB: the same content key and size, a later date.
        var changed = x
        changed[1_000_000] ^= 0xFF
        try sandbox.write("C/X.JPG", changed, modified: 3600)
        // B's Y is only touched.
        try sandbox.setModified("B/Y.JPG", 7200)
        try await sandbox.indexAll()
        counting.reset()
        let third = try await finder.confirm(finder.candidates())
        #expect(third.hashed == 2 && third.reused == 3)
        #expect(Set(counting.counts.reads.keys) == [sandbox.url("C/X.JPG").path, sandbox.url("B/Y.JPG").path])
        #expect(try await third.different == [sandbox.id("C/X.JPG")])
        let xs = try await [sandbox.id("A/X.JPG"), sandbox.id("B/X.JPG")].sorted()
        let ys = try await [sandbox.id("A/Y.JPG"), sandbox.id("B/Y.JPG")].sorted()
        #expect(third.duplicates.map(\.photos) == [xs, ys])
    }

    @Test func `offline copies are left unconfirmed rather than dropped, and never read`() async throws {
        let sandbox = try await DuplicateSandbox.make()
        defer { sandbox.remove() }
        let x = duplicateBytes(150_000, seed: 6)
        for folder in ["A", "B", "C"] {
            try sandbox.write("\(folder)/X.JPG", x)
        }
        try await sandbox.indexAll()
        let (a, b, c) = try await (sandbox.id("A/X.JPG"), sandbox.id("B/X.JPG"), sandbox.id("C/X.JPG"))
        func markOffline(_ photo: Int64) async throws {
            try await sandbox.index.write { writer in
                var row = try #require(try writer.photo(id: photo))
                row.state = .offline
                try writer.upsertPhotos([row])
            }
        }

        try await markOffline(c)
        let counting = CountingFileSystem()
        let finder = sandbox.finder(counting)
        let candidates = try await finder.candidates()
        #expect(candidates.groups.map(\.photos) == [[a, b, c].sorted()])
        let confirmation = try await finder.confirm(candidates)
        #expect(confirmation.duplicates.map(\.photos) == [[a, b].sorted()])
        #expect(confirmation.unconfirmed == [.init(photo: c, status: .unconfirmed(.offline))])
        #expect(counting.counts.reads[sandbox.url("C/X.JPG").path] == nil)
        let review = try await finder.review(confirmation)
        #expect(review.unconfirmed.map(\.photo) == [c] && review.groups.first?.copies.count == 2)

        // With only one copy left that can be read, there's nothing to compare it with.
        try await markOffline(a)
        counting.reset()
        let alone = try await finder.confirm(finder.candidates())
        #expect(alone.duplicates.isEmpty && counting.counts.read == 0 && counting.counts.attributes == 0)
        let statuses = [a, b, c].map { photo in alone.groups.first?.candidates.first { $0.photo == photo }?.status }
        #expect(statuses == [.unconfirmed(.offline), .unconfirmed(.alone), .unconfirmed(.offline)])
    }

    @Test func `a volume that doesn't answer leaves its copies unconfirmed`() async throws {
        let sandbox = try await DuplicateSandbox.make()
        defer { sandbox.remove() }
        let x = duplicateBytes(150_000, seed: 7)
        try sandbox.write("A/X.JPG", x)
        try sandbox.write("B/X.JPG", x)
        try await sandbox.indexAll()
        let gone = SimulatedFileSystem(profile: VolumeProfile.ssd.disconnecting(.init(.afterOperations(0))))
        let finder = sandbox.finder(gone)
        let confirmation = try await finder.confirm(finder.candidates())
        #expect(confirmation.duplicates.isEmpty && confirmation.hashed == 0)
        #expect(confirmation.unconfirmed.map(\.status) == [.unconfirmed(.offline), .unconfirmed(.offline)])
    }

    @Test func `confirming stops when its task is cancelled, keeping the hashes it finished`() async throws {
        let sandbox = try await DuplicateSandbox.make()
        defer { sandbox.remove() }
        for (index, folder) in ["1", "2", "3", "4"].enumerated() {
            let data = duplicateBytes(300_000, seed: UInt64(10 + index))
            try sandbox.write("\(folder)/A.JPG", data)
            try sandbox.write("\(folder)/B.JPG", data)
        }
        try await sandbox.indexAll()
        // One file at a time, in folder order, as on an external disk.
        let holding = HoldingFileSystem(holding: "/3/A.JPG")
        let external = SimulatedFileSystem(
            base: holding, profile: VolumeProfile(name: "external", isLocal: true, isInternal: false),
        )
        let finder = sandbox.finder(external)
        let candidates = try await finder.candidates()
        let task = Task { try await finder.confirm(candidates) }
        while !holding.reached {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        holding.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        // The four before it, and the one being read when the task was cancelled.
        #expect(try await sandbox.index.read { try $0.photoHashCount() } == 5)

        let again = try await sandbox.finder().confirm(candidates)
        #expect(again.hashed == 3 && again.reused == 5 && again.duplicates.count == 4)
    }

    @Test func `a copy a batch can bring back keeps its hash, and loses it once none can`() async throws {
        let sandbox = try await DuplicateSandbox.make()
        defer { sandbox.remove() }
        let x = duplicateBytes(150_000, seed: 90)
        try sandbox.write("A/X.JPG", x, modified: 0)
        try sandbox.write("B/X.JPG", x, modified: 10)
        try await sandbox.indexAll()
        let (a, b) = try await (sandbox.id("A/X.JPG"), sandbox.id("B/X.JPG"))
        func hashed() async throws -> Set<Int64> {
            try await sandbox.index.read { reader in
                try Set(reader.database.prepare("SELECT photo FROM photo_hashes").map { $0.int64(at: 0) })
            }
        }
        let operations = sandbox.operations()
        let finder = sandbox.finder(sandbox.fileSystem)
        let review = try await finder.review(finder.confirm(finder.candidates(), operations: operations))
        #expect(try await hashed() == [a, b])
        let plan = try DuplicateRemovalPlan(review, removing: [b])

        #expect(try await finder.trash(
            plan,
            finder.trashBatch(for: plan, operations: operations),
            operations: operations,
        )
        .isFinished)
        let alone = try await finder.confirm(finder.candidates(), operations: operations)
        #expect(alone.groups.isEmpty)
        #expect(try await hashed() == [a, b], "Undo can bring B back under its ID")

        try await operations.undo()
        let counting = CountingFileSystem()
        let back = try await sandbox.finder(counting).confirm(finder.candidates(), operations: operations)
        #expect(back.hashed == 0 && back.reused == 2 && counting.counts.read == 0, "B's hash stood, so B wasn't read")
        #expect(back.duplicates.map(\.photos) == [[a, b].sorted()])

        #expect(try await finder.trash(
            plan,
            finder.trashBatch(for: plan, operations: operations),
            operations: operations,
        )
        .isFinished)
        _ = try await finder.confirm(finder.candidates())
        #expect(try await hashed() == [a, b], "without the file operations, no hash goes")
        try FileManager.default.removeItem(at: sandbox.indexFolder.appending(path: "File Operations"))
        _ = try await finder.confirm(finder.candidates(), operations: operations)
        #expect(try await hashed() == [a], "with no journal, nothing can bring B back")
    }
}
