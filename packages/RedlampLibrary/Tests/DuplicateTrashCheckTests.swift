import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// What stops a removal plan's batch before anything moves (LIB-39, LIB-26): files that changed or
/// went since the review, and plans that would leave a group without a copy, however they were made.
/// The Trash is the sandbox's simulated volume's, a folder of the sandbox's.
struct DuplicateTrashCheckTests {
    typealias Difference = DuplicateRemovalPlan.Difference
    typealias Refusal = DuplicateRemovalPlan.Refusal

    @Test func `a copy or the copy kept changed or gone since the review stops the batch before anything moves`(
    ) async throws {
        let sandbox = try await DuplicateSandbox.make()
        defer { sandbox.remove() }
        var contents: [Data] = []
        for number in 1 ... 6 {
            let data = duplicateBytes(100_000 + number * 1000, seed: UInt64(50 + number))
            try sandbox.write("Kept\(number)/X.JPG", data, modified: 0)
            try sandbox.write("Copy\(number)/X.JPG", data, modified: 10)
            contents.append(data)
        }
        try sandbox.sidecar("Copy5/X.JPG", PhotoMetadata(flag: .reject))
        try await sandbox.indexAll()
        let finder = sandbox.finder(sandbox.fileSystem)
        let review = try await finder.review(finder.confirm(finder.candidates()))
        let plan = try DuplicateRemovalPlan(review, removing: review.allButProposed)
        #expect(plan.removals.count == 6 && plan.removals.allSatisfy { $0.kept.file.path.contains("/Kept") })
        let operations = sandbox.operations()
        let batch = try await finder.trashBatch(for: plan, operations: operations)

        // Copy 1 changed in place, its size and date as they were, which only its full hash tells.
        var changed = contents[0]
        changed[50000] ^= 0xFF
        try sandbox.write("Copy1/X.JPG", changed, modified: 10)
        try FileManager.default.removeItem(at: sandbox.url("Copy2/X.JPG"))
        try sandbox.write("Kept3/X.JPG", contents[2] + [0], modified: 0)
        try FileManager.default.removeItem(at: sandbox.url("Kept4/X.JPG"))
        try sandbox.sidecar("Copy5/X.JPG", PhotoMetadata(flag: .pick))
        let before = sandbox.files()

        let expected = [
            Difference(path: sandbox.path("Copy1/X.JPG"), reason: .changed),
            Difference(path: sandbox.path("Copy2/X.JPG"), reason: .gone),
            Difference(path: sandbox.path("Copy5/X.JPG"), reason: .sidecarChanged),
            Difference(path: sandbox.path("Kept3/X.JPG"), reason: .changed, isKept: true),
            Difference(path: sandbox.path("Kept4/X.JPG"), reason: .gone, isKept: true),
        ]
        await #expect(throws: Refusal.differs(expected)) {
            try await finder.trash(plan, batch, operations: operations)
        }
        #expect(sandbox.files() == before && sandbox.trashed().isEmpty && sandbox.fileSystem.writes.isEmpty)
        #expect(try await operations.entries().isEmpty, "nothing was written to the journal")
        #expect(expected[4].description == sandbox.path("Kept4/X.JPG") + ", the copy kept, isn't there any more")

        // Without reading the files whole, only copy 1's change goes unseen.
        #expect(try await finder.check(plan, batch, operations: operations, hashing: false) == expected.filter {
            $0.path != sandbox.path("Copy1/X.JPG")
        })
    }

    @Test func `a copy the index no longer has is left out of the batch, and the Trash says so, moving nothing`(
    ) async throws {
        let sandbox = try await DuplicateSandbox.make()
        defer { sandbox.remove() }
        let x = duplicateBytes(100_000, seed: 90)
        try sandbox.write("A/X.JPG", x, modified: 0)
        try sandbox.write("B/X.JPG", x, modified: 10)
        try sandbox.write("C/X.JPG", x, modified: 20)
        try await sandbox.indexAll()
        let finder = sandbox.finder(sandbox.fileSystem)
        let review = try await finder.review(finder.confirm(finder.candidates()))
        let plan = try DuplicateRemovalPlan(review, removing: review.allButProposed)
        let (b, c) = try await (sandbox.id("B/X.JPG"), sandbox.id("C/X.JPG"))
        #expect(plan.removals.map(\.photo) == [b, c])
        try await sandbox.index.write { try $0.deletePhotos([c]) }
        let operations = sandbox.operations()

        let batch = try await finder.trashBatch(for: plan, operations: operations)
        #expect(batch.notInIndex == [c] && batch.steps.flatMap(\.items).map(\.source) == [sandbox.path("B/X.JPG")])
        let before = sandbox.files()
        await #expect(throws: Refusal.differs([Difference(path: sandbox.path("C/X.JPG"), reason: .notInLibrary)])) {
            try await finder.trash(plan, batch, operations: operations)
        }
        #expect(sandbox.files() == before && sandbox.trashed().isEmpty && sandbox.fileSystem.writes.isEmpty)
        #expect(try await operations.entries().isEmpty, "nothing was written to the journal")
    }

    @Test func `every copy of a group stays, even when a plan asks the API to move them all`() async throws {
        let sandbox = try await DuplicateSandbox.make()
        defer { sandbox.remove() }
        let x = duplicateBytes(120_000, seed: 60)
        try sandbox.write("A/X.JPG", x, modified: 0)
        try sandbox.write("B/X.JPG", x, modified: 10)
        try sandbox.write("C/X.JPG", x, modified: 20)
        let y = duplicateBytes(80000, seed: 61)
        try sandbox.write("D/Y.JPG", y, modified: 0)
        try sandbox.write("E/Y.JPG", y, modified: 10)
        try await sandbox.indexAll()
        let finder = sandbox.finder(sandbox.fileSystem)
        let review = try await finder.review(finder.confirm(finder.candidates()))
        let (a, b, c) = try await (sandbox.id("A/X.JPG"), sandbox.id("B/X.JPG"), sandbox.id("C/X.JPG"))
        let (d, e) = try await (sandbox.id("D/Y.JPG"), sandbox.id("E/Y.JPG"))
        let group = try #require(review.groups.first { $0.size == 120_000 })
        #expect(throws: Refusal.everyCopy(sha256: group.sha256)) {
            try DuplicateRemovalPlan(review, removing: [a, b, c])
        }
        let operations = sandbox.operations()

        // Two plans from one review, each leaving a copy the other removes.
        let first = try DuplicateRemovalPlan(review, removing: [b, c])
        let second = try DuplicateRemovalPlan(review, removing: [a])
        #expect(first.removals.map(\.kept.photo) == [a, a] && second.removals.map(\.kept.photo) == [b])
        let firstBatch = try await finder.trashBatch(for: first, operations: operations)
        #expect(try await finder.trash(first, firstBatch, operations: operations).isFinished)
        let late = try await finder.trashBatch(for: second, operations: operations)
        await #expect(throws: Refusal.differs([
            Difference(path: sandbox.path("B/X.JPG"), reason: .notInLibrary, isKept: true),
        ])) {
            try await finder.trash(second, late, operations: operations)
        }
        #expect(FileManager.default.fileExists(atPath: sandbox.url("A/X.JPG").path))

        /// A plan whose copies keep each other, which no review makes: two plans' removals in one.
        func removals(_ plan: DuplicateRemovalPlan) throws -> [Any] {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any]
            return try #require(object?["removals"] as? [Any])
        }
        let keepingE = try DuplicateRemovalPlan(review, removing: [d])
        let keepingD = try DuplicateRemovalPlan(review, removing: [e])
        let both = try JSONDecoder().decode(DuplicateRemovalPlan.self, from: JSONSerialization.data(
            withJSONObject: ["removals": removals(keepingE) + removals(keepingD)],
        ))
        #expect(both.removals.map(\.photo) == [d, e] && both.removals.map(\.kept.photo) == [e, d])
        let trashed = sandbox.trashed()
        let batch = try await finder.trashBatch(for: both, operations: operations)
        await #expect(throws: Refusal.differs([
            Difference(path: sandbox.path("D/Y.JPG"), reason: .keptRemoved, isKept: true),
            Difference(path: sandbox.path("E/Y.JPG"), reason: .keptRemoved, isKept: true),
        ])) {
            try await finder.trash(both, batch, operations: operations)
        }
        #expect(["D/Y.JPG", "E/Y.JPG"].allSatisfy { FileManager.default.fileExists(atPath: sandbox.url($0).path) })
        #expect(sandbox.trashed() == trashed && trashed.count == 2)

        // A copy named twice moves once.
        let twice = try JSONDecoder().decode(DuplicateRemovalPlan.self, from: JSONSerialization.data(
            withJSONObject: ["removals": removals(keepingE) + removals(keepingE)],
        ))
        let once = try await finder.trashBatch(for: twice, operations: operations)
        #expect(twice.removals.count == 2 && once.steps.count == 1 && once.title == "Move 1 duplicate to the Trash")
        #expect(try await finder.trash(twice, once, operations: operations).isFinished)
        #expect(!FileManager.default.fileExists(atPath: sandbox.url("D/Y.JPG").path))
        #expect(FileManager.default.fileExists(atPath: sandbox.url("E/Y.JPG").path))
    }
}
