import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// Library Health's changes in Library's one order for Undo (LIB-40, LIB-15): its batch, Keep Anyway and List Again
/// are taken back by ⌘Z and made again by ⇧⌘Z in turn with a rating, a keyword and a move, whichever came first.
///
/// The Trash is the real one: the photos are made on the external disk's scratch folder, and what the test leaves in
/// the Trash is removed with it.
@MainActor
@Suite(.serialized)
struct HealthUndoOrderTests {
    typealias Sandbox = LibraryUndoOrderTests.Sandbox

    /// What the files and the library show of the changes: Keep Anyway keeps the empty file, List Again lists it.
    struct Made: Equatable, CustomStringConvertible {
        var trashed = false
        var rated = false
        var kept = false
        var keyword = false
        var moved = false

        var description: String {
            [("trashed", trashed), ("rated", rated), ("kept", kept), ("keyword", keyword), ("moved", moved)]
                .filter(\.1).map(\.0).joined(separator: ", ")
        }
    }

    @Test func `⌘Z and ⇧⌘Z take back and make Health's batch, Keep Anyway and List Again in turn with other changes`(
    ) async throws {
        let sandbox = Sandbox()
        let copies = sandbox.root.appending(path: "Copies", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
            // A byte-for-byte copy of Shoot's B, and an empty file the damaged check lists.
            try SourcesSandbox.jpeg(number: 1).write(to: copies.appending(path: "B copy.JPG"))
            let empty = copies.appending(path: "Empty.JPG")
            try Data().write(to: empty)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: empty.path,
            )
            try await sandbox.open()
            try await Self.inTurn(sandbox, empty: empty)
        } catch {
            await sandbox.close()
            throw error
        }
        await sandbox.close()
    }

    private static func inTurn(_ sandbox: Sandbox, empty: URL) async throws {
        let model = try #require(sandbox.model)
        let sources = model.librarySources
        var expected = Made()
        var trashed: URL?

        func settled() async {
            await model.healthChangesMade()
            await sandbox.settled()
        }

        func counts(_ condition: (LibrarySources) -> Bool) async -> Bool {
            await sandbox.service.settled()
            sources.recount()
            await sources.counted()
            return condition(sources)
        }

        func made() async -> Made {
            let files = FileManager.default
            return await Made(
                trashed: trashed.map { !files.fileExists(atPath: $0.path) } ?? false,
                rated: SidecarStore().load(for: sandbox.photo("C.JPG"))?.metadata?.rating == 3,
                kept: counts { $0.count(of: .keptAnyway) == 1 && $0.count(of: .health(.damaged)) == nil },
                keyword: (SidecarStore().load(for: sandbox.photo("A.JPG"))?.metadata?.keywords ?? [])
                    .contains("Order"),
                moved: files.fileExists(atPath: sandbox.photo("D.JPG", in: sandbox.picked).path),
            )
        }

        func until(seconds: Double = 20, _ condition: () async -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while await !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        func showShoot() async throws {
            let photos = try FileManager.default.contentsOfDirectory(atPath: sandbox.shoot.path)
                .filter { $0.hasSuffix(".JPG") }
            try await sandbox.show(sandbox.shoot, count: photos.count)
        }

        // Health's batch: one of B's two copies to the Trash.
        try await until(seconds: 30) { await counts { $0.count(of: .health(.duplicates)) == 2 } }
        #expect(sources.show(.health(.duplicates)))
        try await sandbox.eventually { !sources.isListing && model.healthProposals.marked == 2 }
        let findings = try #require(model.healthProposals.findings)
        let core = try #require(sandbox.service.core)
        let sheet = HealthSheetModel(findings: findings, selectedApart: [], health: model.healthProposals.library(core))
        sheet.makePlan()
        try await sandbox.eventually(seconds: 20) { sheet.canAccept }
        let proposed = try #require(findings.findings.first { $0.proposal == .trash })
        trashed = try URL(fileURLWithPath: #require(sheet.plan?.path(of: proposed.photo)))
        #expect(await model.acceptHealthPlan(sheet))
        await settled()
        expected.trashed = true
        #expect(await made() == expected)

        // C rated.
        try await showShoot()
        model.select(sandbox.photo("C.JPG"))
        #expect(model.perform(.rating3))
        await settled()
        expected.rated = true
        #expect(await made() == expected)

        // The empty file kept anyway, from the damaged check's list.
        try await until { await counts { $0.count(of: .health(.damaged)) == 1 } }
        #expect(sources.show(.health(.damaged)))
        try await sandbox.eventually {
            !sources.isListing && model.items.count == 1 && model.healthProposals.marked == 1
        }
        model.select(empty)
        #expect(model.perform(.keepAnyway))
        await settled()
        expected.kept = true
        try await until { await made() == expected }
        #expect(await made() == expected)

        // A keyword on A.
        try await showShoot()
        try await sandbox.select("A.JPG")
        #expect(model.libraryPanels.add([KeywordPath("Order")!]))
        await settled()
        expected.keyword = true
        #expect(await made() == expected)

        // The empty file listed again, from Kept Anyway.
        #expect(sources.show(.keptAnyway))
        try await sandbox.eventually { !sources.isListing && model.items.count == 1 }
        model.select(empty)
        #expect(model.perform(.listAgain))
        await settled()
        expected.kept = false
        try await until { await made() == expected }
        #expect(await made() == expected)

        // D moved to Picked.
        try await showShoot()
        #expect(await model.movePhotos([sandbox.photo("D.JPG")], to: sandbox.picked) == nil)
        await settled()
        expected.moved = true
        #expect(await made() == expected)

        // What each change shows once taken back; made again, the opposite.
        let steps: [(String, WritableKeyPath<Made, Bool>, Bool)] = [
            ("the move", \.moved, false), ("List Again", \.kept, true), ("the keyword", \.keyword, false),
            ("Keep Anyway", \.kept, false), ("the rating", \.rated, false), ("Health's batch", \.trashed, false),
        ]
        for (name, change, undone) in steps {
            #expect(model.canPerform(.undo) && model.perform(.undo), "⌘Z for \(name)")
            await settled()
            expected[keyPath: change] = undone
            try await until { await made() == expected }
            #expect(await made() == expected, "⌘Z took back \(name), newest first")
        }
        #expect(!model.canPerform(.undo), "nothing left to take back")

        for (name, change, undone) in steps.reversed() {
            #expect(model.canPerform(.redo) && model.perform(.redo), "⇧⌘Z for \(name)")
            await settled()
            expected[keyPath: change] = !undone
            try await until { await made() == expected }
            #expect(await made() == expected, "⇧⌘Z made \(name) again, in the order they were made")
        }
        #expect(!model.canPerform(.redo), "nothing left to make again")
    }
}
