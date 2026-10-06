import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Removal plans carried out (LIB-39, LIB-26): their copies to the Trash of the sandbox's simulated
/// volume, a folder of the sandbox's, as one journaled batch, and back with Undo. What stops a batch
/// is `DuplicateTrashCheckTests`'.
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
            let left = before.filter { !moved.contains($0.key) && !$0.key.contains("B/X.JPG.redlamp") }
            #expect(sandbox.files() == left)
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
        let shared = Difference(path: sandbox.path("Pair/IMG_0001.xmp"), reason: .notInPlan)
        await #expect(throws: Refusal.differs([shared])) {
            try await finder.trash(plan, taking, operations: operations)
        }
        #expect(sandbox.fileSystem.writes.isEmpty && sandbox.trashed().isEmpty)
        try FileManager.default.moveItem(at: aside, to: sandbox.url("Pair/IMG_0001.ARW"))

        let batch = try await finder.trashBatch(for: plan, operations: operations)
        #expect(try await finder.trash(plan, batch, operations: operations).isFinished)
        let moved: Set = ["Copies/X.JPG", "Copies/X.JPG.xmp", "Pair/IMG_0001.JPG"]
        let left = before.filter { !moved.contains($0.key) && !$0.key.hasPrefix("Copies/X.JPG.redlamp/") }
        #expect(sandbox.files() == left)
        let writes = sandbox.fileSystem.writes
        #expect(writes.allSatisfy { $0.hasPrefix("trash ") }, "\(writes)")
        #expect(Set(writes.map { String($0.dropFirst("trash ".count).prefix { $0 != " " }) }) == Set(
            ["Copies/X.JPG", "Copies/X.JPG.redlamp", "Copies/X.JPG.xmp", "Pair/IMG_0001.JPG"].map(sandbox.path),
        ))
        #expect(writes.count == 4 && sandbox.trashed().count == 4)
        #expect(try await sandbox.rows() == rows.filter { $0.value != copy && $0.value != pair })
    }
}
