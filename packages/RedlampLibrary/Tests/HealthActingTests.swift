import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Acting on Library Health's findings (LIB-40): one batch through the file operations, checked just
/// before it runs, to the Trash or a rename, which one Undo reverses.
struct HealthActingTests {
    @Test func `a wrong extension is renamed with its sidecar and other apps' xmp`() async throws {
        let sandbox = try await HealthSandbox.make([
            "Shoot/IMG_1.JPG": HealthImages.data(.heic, seed: 1),
            "Shoot/IMG_1.JPG.xmp": Data("darktable's".utf8),
            "Shoot/IMG_1.xmp": Data("Lightroom's".utf8),
            "Shoot/IMG_2.cr3": HealthImages.data(.jpeg, seed: 2),
            "Shoot/IMG_3.jpg": HealthImages.data(.jpeg, seed: 3),
        ])
        defer { sandbox.remove() }
        try sandbox.sidecar("Shoot/IMG_1.JPG", PhotoMetadata(keywords: ["Places/Lisbon"]))
        await sandbox.index()
        let health = sandbox.library()
        let found = try await health.findings(.extensions)

        let plan = try await health.plan(found)
        #expect(plan.batch.kind == .rename && Set(plan.photos) == Set(found.photos))
        try await health.run(plan)
        let files = sandbox.files()
        for renamed in [
            "Shoot/IMG_1.HEIC", "Shoot/IMG_1.HEIC.redlamp/edit.json", "Shoot/IMG_1.HEIC.xmp", "Shoot/IMG_2.jpg",
        ] {
            #expect(files.contains(renamed), "\(renamed) in \(files)")
        }
        #expect(files.contains("Shoot/IMG_1.xmp"), "the .xmp named after the name both extensions share stays")
        #expect(!files.contains("Shoot/IMG_1.JPG") && !files.contains("Shoot/IMG_2.cr3"))
        let rows = try await sandbox.rows()
        #expect(rows["Shoot/IMG_1.HEIC"]?.kind == .heic && rows["Shoot/IMG_2.jpg"]?.kind == .jpeg)
        #expect(rows["Shoot/IMG_1.HEIC"]?.id == found.photos[0], "the row keeps its ID")
        #expect(try await health.findings(.extensions).isEmpty, "nothing is offered once they're renamed")
        #expect(await sandbox.index().summary?.headsRead == 0, "indexing again reads none of them")

        try await health.operations.undo()
        #expect(sandbox.files().isSuperset(of: [
            "Shoot/IMG_1.JPG", "Shoot/IMG_1.JPG.redlamp/edit.json", "Shoot/IMG_1.JPG.xmp", "Shoot/IMG_2.cr3",
        ]))
        try await health.engine.updateNames()
        #expect(try await health.findings(.extensions).photos == found.photos)
    }

    @Test func `a dropped half goes to the Trash with its own sidecars, the pair's xmp staying with the raw`(
    ) async throws {
        let sandbox = try await HealthPairTests.pairs()
        defer { sandbox.remove() }
        let health = sandbox.library()
        let plan = try await health.plan(health.findings(.pairs(.keepRaw)))
        #expect(try await Set(sandbox.paths(plan.photos)) == ["Pairs/A.JPG", "Pairs/D.HEIC"])
        #expect(plan.leftOut.count == 3, "the halves listed apart")
        try await health.run(plan)
        let left = sandbox.files()
        #expect(!left.contains("Pairs/A.JPG") && !left.contains("Pairs/A.JPG.xmp") && !left.contains("Pairs/D.HEIC"))
        #expect(left.contains("Pairs/A.ARW") && left.contains("Pairs/A.xmp"), "the .xmp the pair shares stays")
        #expect(left.contains("Pairs/B.JPG") && left.contains("Pairs/C.JPG") && left.contains("Pairs/H.JPG"))
        let trashed = try Set(FileManager.default.contentsOfDirectory(atPath: sandbox.trash.path))
        #expect(trashed.isSuperset(of: ["A.JPG", "A.JPG.xmp", "D.HEIC"]), "\(trashed)")
    }

    @Test func `a photo the user decided is never acted on because a proposal said so`() async throws {
        let sandbox = try await HealthSandbox.make([
            "Cards/Empty.jpg": Data(), "Cards/Rated.jpg": Data(),
            "Cards/Cut.jpg": HealthImages.data(.jpeg).dropLast(50),
        ])
        defer { sandbox.remove() }
        try sandbox.sidecar("Cards/Rated.jpg", PhotoMetadata(rating: 4))
        await sandbox.index()
        let health = sandbox.library()
        let found = try await health.findings(.damaged)
        #expect(try await sandbox.paths(found.photos) == ["Cards/Cut.jpg", "Cards/Empty.jpg", "Cards/Rated.jpg"])
        let rated = try #require(found.findings.first { $0.apart == .decided })
        #expect(try await sandbox.paths([rated.photo]) == ["Cards/Rated.jpg"])

        let plan = try await health.plan(found)
        #expect(!plan.photos.contains(rated.photo) && plan.leftOut.map(\.photo) == [rated.photo])
        let chosen = try await health.plan(found, choosing: [rated.photo])
        #expect(chosen.photos.contains(rated.photo), "the user chose it")

        // Flagged once the batch was planned: it stops before anything moves.
        let cut = try #require(found.findings.first { $0.apart == nil }?.photo)
        try await sandbox.index.write { try $0.setOrganising([.flag(.pick)], forPhotos: [cut]) }
        await #expect(throws: HealthError.self) { try await health.run(plan) }
        #expect(sandbox.files().isSuperset(of: ["Cards/Cut.jpg", "Cards/Empty.jpg", "Cards/Rated.jpg"]))
    }

    @Test func `health rows and hashes stay while a batch can bring their photo back, and go once none can`(
    ) async throws {
        let sandbox = try await HealthSandbox.make([
            "Cards/One.jpg": Data(), "Cards/Two.jpg": Data(), "Cards/Gone.jpg": Data(),
            "Cards/Good.jpg": HealthImages.data(.jpeg),
        ])
        defer { sandbox.remove() }
        await sandbox.index()
        let rows = try await sandbox.rows()
        let (one, two, gone) = try (
            #require(rows["Cards/One.jpg"]?.id), #require(rows["Cards/Two.jpg"]?.id),
            #require(rows["Cards/Gone.jpg"]?.id),
        )
        try await sandbox.index.write { writer in
            try writer.setPhotoHashes([one, two, gone].map {
                PhotoHash(photo: $0, size: 0, modified: HealthSandbox.written, contentKey: Data([1]), sha256: Data([2]))
            })
        }
        func kept() async throws -> (health: Set<Int64>, hashes: Set<Int64>) {
            try await sandbox.index.read { reader in
                var found: (health: Set<Int64>, hashes: Set<Int64>) = ([], [])
                try reader.database.prepare("SELECT photo FROM photo_health").forEachRow {
                    found.health.insert($0.int64(at: 0))
                }
                try reader.database.prepare("SELECT photo FROM photo_hashes").forEachRow {
                    found.hashes.insert($0.int64(at: 0))
                }
                return found
            }
        }
        #expect(try await kept() == ([one, two, gone], [one, two, gone]))

        // Gone from its folder: missing, its row keeps them, and Remove leaves them while Undo can put it back.
        try FileManager.default.removeItem(at: sandbox.url("Cards/Gone.jpg"))
        await sandbox.index()
        let health = sandbox.library()
        try await health.run(health.plan(health.findings(.damaged)))
        #expect(try await health.operations.removeUnrestorable() == 0)
        #expect(
            try await kept() == ([one, two, gone], [one, two, gone]),
            "the Trash journal can bring One and Two back",
        )
        try await health.engine.updateNames()
        try await health.run(health.planRemoval([gone], in: health.findings(.missing)))
        #expect(try await health.operations.removeUnrestorable() == 0)

        try await health.operations.undo()
        try await health.operations.undo()
        try await health.engine.updateNames()
        #expect(try await Set(health.findings(.damaged).photos) == [one, two], "with their health")
        #expect(try await health.findings(.missing).photos == [gone])

        try await health.run(health.plan(health.findings(.damaged)))
        try await health.run(health.planRemoval([gone], in: health.findings(.missing)))
        try FileManager.default.removeItem(at: sandbox.paths.root.appending(path: "File Operations"))
        try await health.operations.recover()
        #expect(try await kept() == ([], []), "no journal is left to bring them back")
    }

    @Test func `one Undo takes back a batch`() async throws {
        let sandbox = try await HealthSandbox.make([
            "Cards/One.jpg": Data(), "Cards/Two.jpg": Data(), "Cards/Good.jpg": HealthImages.data(.jpeg),
        ])
        defer { sandbox.remove() }
        await sandbox.index()
        let rows = try await sandbox.rows()
        let health = sandbox.library()
        let found = try await health.findings(.damaged)
        #expect(found.findings.count == 2)
        let outcome = try await health.run(health.plan(found))
        #expect(outcome.photos == 2 && sandbox.files() == ["Cards/Good.jpg"])
        #expect(try await health.findings(.damaged).isEmpty)

        let undone = try await health.operations.undo()
        #expect(undone.isFinished && sandbox.files() == ["Cards/Good.jpg", "Cards/One.jpg", "Cards/Two.jpg"])
        #expect(try await sandbox.rows() == rows, "the rows came back under their IDs")
        try await health.engine.updateNames()
        #expect(try await health.findings(.damaged).photos == found.photos, "with their health")
    }
}
