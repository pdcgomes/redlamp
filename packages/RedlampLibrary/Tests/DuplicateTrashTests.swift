import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Removal plans carried out (LIB-39, LIB-26): their copies to the Trash of the sandbox's simulated
/// volume, a folder of the sandbox's, as one journaled batch checked just before it runs.
struct DuplicateTrashTests {
    typealias Difference = DuplicateRemovalPlan.Difference
    typealias Refusal = DuplicateRemovalPlan.Refusal

    @Test func `a plan's copies go to the Trash in one batch with their sidecars and .xmp, and Undo brings them back`(
    ) async throws {
        for onThisMac in [false, true] {
            let sandbox = try await DuplicateSandbox.make()
            defer { sandbox.remove() }
            let x = duplicateBytes(150_000, seed: 40)
            try sandbox.write("A/X.JPG", x, modified: 0)
            try sandbox.write("B/X.JPG", x, modified: 10)
            try sandbox.write("C/X.JPG", x, modified: 20)
            let y = duplicateBytes(90000, seed: 41)
            try sandbox.write("A/Y.JPG", y, modified: 0)
            try sandbox.write("D/Y.JPG", y, modified: 30)
            try sandbox.write("D/Z.JPG", duplicateBytes(60000, seed: 42))
            // B's .xmp is named after its name, C's after its name without the extension.
            try sandbox.write("B/X.JPG.xmp", otherAppXMP)
            try sandbox.write("C/X.xmp", otherAppXMP)
            try await sandbox.indexAll()
            if onThisMac {
                let root = try #require(try await sandbox.index.read { try $0.roots() }.first)
                try await LibrarySidecars(index: sandbox.index).setPlacement(.onThisMac, forRoot: root.id)
            }
            let store = try await sandbox.sidecars()
            try sandbox.sidecar("A/X.JPG", PhotoMetadata(label: .green), store: store)
            try sandbox.sidecar("B/X.JPG", PhotoMetadata(flag: .reject, keywords: ["copy"]), store: store)
            let finder = sandbox.finder(sandbox.fileSystem, sidecars: store)
            let review = try await finder.review(finder.confirm(finder.candidates()))
            let plan = try DuplicateRemovalPlan(review, removing: review.allButProposed)
            let (b, c, dy) = try await (sandbox.id("B/X.JPG"), sandbox.id("C/X.JPG"), sandbox.id("D/Y.JPG"))
            #expect(plan.removals.map(\.photo) == [b, c, dy])
            let sidecar = try #require(plan.removals.first?.sidecar)
            #expect(sidecar.path.contains("/Sidecars/") == onThisMac)
            let before = sandbox.files()
            let rows = try await sandbox.rows()
            let operations = sandbox.operations()

            let batch = try await finder.trashBatch(for: plan, operations: operations)
            #expect(batch.kind == .trash && batch.title == "Move 3 duplicates to the Trash")
            #expect(batch.steps.map { $0.removed.map(\.photo.id) } == [[b], [c], [dy]])
            #expect(batch.steps.map { $0.items.map(\.source) } == [
                [sandbox.path("B/X.JPG"), LibraryIndexer.path(sidecar), sandbox.path("B/X.JPG.xmp")],
                [sandbox.path("C/X.JPG"), sandbox.path("C/X.xmp")],
                [sandbox.path("D/Y.JPG")],
            ])
            #expect(try await finder.check(plan, batch, operations: operations).isEmpty)

            let outcome = try await finder.trash(plan, batch, operations: operations)
            #expect(outcome.isFinished && outcome.photos == 3)
            let moved: Set = ["B/X.JPG", "B/X.JPG.xmp", "C/X.JPG", "C/X.xmp", "D/Y.JPG"]
            #expect(sandbox.files() == before.filter { !moved.contains($0.key) && !$0.key.contains("B/X.JPG.redlamp") })
            #expect(sandbox.trashed().count == 6, "the copies, B's sidecar and the two .xmp: \(sandbox.trashed())")
            #expect(try await sandbox.rows() == rows.filter { ![b, c, dy].contains($0.value) })
            let entries = try await operations.entries()
            #expect(entries.map(\.title) == ["Move 3 duplicates to the Trash"] && entries.first?.state == .finished)

            let undone = try await operations.undo()
            #expect(undone.isFinished && undone.photos == 3)
            #expect(sandbox.files() == before)
            #expect(try await sandbox.rows() == rows, "the rows came back under their IDs")
            #expect(sandbox.trashed().isEmpty)
            #expect(try await operations.entries().first?.state == .undone)
            #expect(try await finder.review(finder.confirm(finder.candidates())).groups == review.groups)
        }
    }

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
        #expect(try await finder.trash(
            first,
            finder.trashBatch(for: first, operations: operations),
            operations: operations,
        )
        .isFinished)
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
    }

    @Test func `a raw and its JPEG are never duplicates, and the JPEG's copy goes to the Trash without them`(
    ) async throws {
        let sandbox = try await DuplicateSandbox.make()
        defer { sandbox.remove() }
        let jpeg = duplicateBytes(120_000, seed: 70)
        // A raw and its JPEG with one name, one size and one date, and the .xmp they share; and the
        // JPEG copied elsewhere first.
        try sandbox.write("Shoot/DSCF0001.RAF", duplicateBytes(120_000, seed: 71), modified: 60)
        try sandbox.write("Shoot/DSCF0001.JPG", jpeg, modified: 60)
        try sandbox.write("Shoot/DSCF0001.xmp", otherAppXMP, modified: 60)
        try sandbox.write("Backup/DSCF0001.JPG", jpeg, modified: 0)
        try await sandbox.indexAll()
        let finder = sandbox.finder(sandbox.fileSystem)
        let review = try await finder.review(finder.confirm(finder.candidates()))
        let raw = try await sandbox.id("Shoot/DSCF0001.RAF")
        let (backup, beside) = try await (sandbox.id("Backup/DSCF0001.JPG"), sandbox.id("Shoot/DSCF0001.JPG"))
        #expect(review.groups.map { $0.copies.map(\.photo) } == [[backup, beside]])
        #expect(review.different.isEmpty && review.unconfirmed.isEmpty)
        #expect(review.groups.first?.keeper.photo == backup && review.groups.first?.copies.last?.sharesOtherXMP == true)
        #expect(throws: Refusal.notADuplicate(photo: raw)) { try DuplicateRemovalPlan(review, removing: [raw]) }

        let plan = try DuplicateRemovalPlan(review, removing: review.allButProposed)
        #expect(plan.removals.map(\.photo) == [beside] && plan.removals.first?.otherXMP == nil)
        let before = sandbox.files()
        let operations = sandbox.operations()
        let batch = try await finder.trashBatch(for: plan, operations: operations)
        #expect(batch.steps.flatMap(\.items).map(\.source) == [sandbox.path("Shoot/DSCF0001.JPG")])
        #expect(try await finder.trash(plan, batch, operations: operations).isFinished)
        #expect(sandbox.files() == before.filter { $0.key != "Shoot/DSCF0001.JPG" })
        #expect(sandbox.trashed() == ["DSCF0001.JPG"])
        #expect(try await sandbox.rows()["Shoot/DSCF0001.RAF"] == raw)
    }

    @Test func `nothing outside the plan is touched: the copies kept, their sidecars, other photos and a shared .xmp`(
    ) async throws {
        let sandbox = try await DuplicateSandbox.make()
        defer { sandbox.remove() }
        let x = duplicateBytes(150_000, seed: 80)
        try sandbox.write("Keep/X.JPG", x, modified: 0)
        try sandbox.write("Keep/X.JPG.xmp", otherAppXMP)
        try sandbox.write("Copies/X.JPG", x, modified: 10)
        try sandbox.write("Copies/X.JPG.xmp", otherAppXMP)
        try sandbox.write("Copies/Other.JPG", duplicateBytes(70000, seed: 81))
        try sandbox.write("Copies/Other.xmp", otherAppXMP)
        // A JPEG's copy beside its raw, with the .xmp they share.
        let jpeg = duplicateBytes(110_000, seed: 82)
        try sandbox.write("Keep/IMG_0001.JPG", jpeg, modified: 0)
        try sandbox.write("Pair/IMG_0001.JPG", jpeg, modified: 10)
        try sandbox.write("Pair/IMG_0001.ARW", duplicateBytes(210_000, seed: 83), modified: 10)
        try sandbox.write("Pair/IMG_0001.xmp", otherAppXMP)
        // A group the plan leaves alone.
        let z = duplicateBytes(50000, seed: 84)
        try sandbox.write("Z1/Z.JPG", z, modified: 0)
        try sandbox.write("Z2/Z.JPG", z, modified: 10)
        try sandbox.sidecar("Keep/X.JPG", PhotoMetadata(label: .green))
        try sandbox.sidecar("Copies/X.JPG", PhotoMetadata(flag: .reject))
        try sandbox.sidecar("Copies/Other.JPG", PhotoMetadata(flag: .pick))
        try await sandbox.indexAll()
        let finder = sandbox.finder(sandbox.fileSystem)
        let review = try await finder.review(finder.confirm(finder.candidates()))
        let (copy, pair) = try await (sandbox.id("Copies/X.JPG"), sandbox.id("Pair/IMG_0001.JPG"))
        let plan = try DuplicateRemovalPlan(review, removing: [copy, pair])
        let before = sandbox.files()
        let rows = try await sandbox.rows()
        let operations = sandbox.operations()

        // With the raw gone from its folder, though the index still has it, the batch would take the
        // .xmp it shares with the JPEG.
        let aside = sandbox.indexFolder.appending(path: "IMG_0001.ARW")
        try FileManager.default.moveItem(at: sandbox.url("Pair/IMG_0001.ARW"), to: aside)
        let taking = try await finder.trashBatch(for: plan, operations: operations)
        #expect(taking.steps.flatMap(\.items).map(\.source).contains(sandbox.path("Pair/IMG_0001.xmp")))
        await #expect(throws: Refusal.differs([Difference(
            path: sandbox.path("Pair/IMG_0001.xmp"),
            reason: .notInPlan,
        )])) {
            try await finder.trash(plan, taking, operations: operations)
        }
        #expect(sandbox.fileSystem.writes.isEmpty && sandbox.trashed().isEmpty)
        try FileManager.default.moveItem(at: aside, to: sandbox.url("Pair/IMG_0001.ARW"))

        let batch = try await finder.trashBatch(for: plan, operations: operations)
        #expect(try await finder.trash(plan, batch, operations: operations).isFinished)
        let moved: Set = ["Copies/X.JPG", "Copies/X.JPG.xmp", "Pair/IMG_0001.JPG"]
        #expect(sandbox.files() == before
            .filter { !moved.contains($0.key) && !$0.key.hasPrefix("Copies/X.JPG.redlamp/") })
        let writes = sandbox.fileSystem.writes
        #expect(writes.allSatisfy { $0.hasPrefix("trash ") }, "\(writes)")
        #expect(Set(writes.map { String($0.dropFirst("trash ".count).prefix { $0 != " " }) }) == Set(
            ["Copies/X.JPG", "Copies/X.JPG.redlamp", "Copies/X.JPG.xmp", "Pair/IMG_0001.JPG"].map(sandbox.path),
        ))
        #expect(writes.count == 4 && sandbox.trashed().count == 4)
        #expect(try await sandbox.rows() == rows.filter { $0.value != copy && $0.value != pair })
    }
}
