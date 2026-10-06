import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// What `redlamp library duplicates` prints: the review's text and JSON, on a small fixture.
struct DuplicateReportTests {
    @Test func `on a small fixture it shows the groups, the space they'd free, the proposals and why, and removes nothing`(
    ) async throws {
        let sandbox = try await IndexerSandbox.make(.init(photos: 240, seed: 31, duplicateShare: 0.05))
        defer { sandbox.remove() }
        let run = await IndexerRun.collect(
            LibraryIndexer(index: sandbox.index, configuration: .testing()).index([sandbox.root]),
        )
        #expect(run.failures.isEmpty)
        let files = try FixtureTests.files(in: sandbox.root)
        let copies = try #require(sandbox.manifest.totals.duplicates)
        let finder = DuplicateFinder(index: sandbox.index)
        let candidates = try await finder.candidates()

        // Without --confirm: no file is read, and nothing is confirmed yet.
        let unread = try await finder.review(finder.confirm(candidates, readingFiles: false))
        #expect(unread.groups.isEmpty && unread.unconfirmed.count == candidates.photoCount)
        #expect(Array(unread.lines.prefix(2)) == [
            "No duplicates", "Only hashes recorded earlier were compared: --confirm reads the files",
        ])
        #expect(unread.lines.contains { $0.hasSuffix("(not read: --confirm reads it)") })

        let review = try await finder.review(finder.confirm(candidates))
        let photos = review.groups.reduce(0) { $0 + $1.copies.count }
        #expect(photos - review.groups.count == copies)
        let lines = review.lines
        #expect(lines.first == "\(review.groups.count) groups of duplicates, \(photos) photos: removing all but the "
            + "proposed copies would free \(DuplicateReview.bytes(review.reclaimable))")
        #expect(lines.count { $0.hasPrefix("  keep  ") } == review.groups.count)
        #expect(lines.count { $0.hasPrefix("  copy  ") } == copies)
        for group in review.groups {
            let kept = try #require(group.kept)
            #expect(lines.contains { $0.hasPrefix("  keep  \(kept.url.path)  (\(group.keeper.description)") })
        }
        #expect(lines.last == "Nothing was removed." && !lines.contains { $0.contains("couldn't be compared") })

        let json = try #require(try JSONSerialization.jsonObject(with: review.json()) as? [String: Any])
        let groups = try #require(json["groups"] as? [[String: Any]])
        #expect(json["tool"] as? String == "redlamp library duplicates" && json["removed"] as? Int == 0)
        #expect(json["checkedFiles"] as? Bool == true && json["reclaimable"] as? Int64 == review.reclaimable)
        #expect(groups.count == review.groups.count)
        #expect(groups.allSatisfy { ($0["keep"] as? [String: Any])?["reason"] is String })
        #expect(groups.reduce(0) { $0 + (($1["copies"] as? [Any])?.count ?? 0) } == photos)

        // The hashes recorded confirm them again without reading a file.
        let recorded = try await finder.review(finder.confirm(candidates, readingFiles: false))
        #expect(recorded.groups.map(\.sha256) == review.groups.map(\.sha256) && !recorded.checkedFiles)
        #expect(try FixtureTests.files(in: sandbox.root) == files)
    }

    @Test func `with --trash it lists every file that moves, each copy with what goes with it, then what became of it`(
    ) async throws {
        let sandbox = try await DuplicateSandbox.make()
        defer { sandbox.remove() }
        let x = duplicateBytes(150_000, seed: 90)
        try sandbox.write("A/X.JPG", x, modified: 0)
        try sandbox.write("B/X.JPG", x, modified: 10)
        try sandbox.write("B/X.JPG.xmp", otherAppXMP)
        try sandbox.sidecar("B/X.JPG", PhotoMetadata(flag: .reject))
        try await sandbox.indexAll()
        let finder = sandbox.finder(sandbox.fileSystem)
        let review = try await finder.review(finder.confirm(finder.candidates()))
        #expect(review.lines == review.findings + ["", "Nothing was removed."])
        let plan = try DuplicateRemovalPlan(review, removing: review.allButProposed)
        let operations = sandbox.operations()
        let batch = try await finder.trashBatch(for: plan, operations: operations)
        #expect(plan.lines(batch) == [
            "Move 1 duplicate to the Trash, 3 files, 150 KB:",
            "  " + sandbox.path("B/X.JPG"),
            "    " + sandbox.path("B/X.JPG.redlamp"),
            "    " + sandbox.path("B/X.JPG.xmp"),
        ])
        #expect(DuplicateRemovalPlan.lines(.shown(dryRun: false, stopping: [])) == [
            "Nothing was moved: --confirm moves them to the Trash, and redlamp library undo puts them back.",
        ])
        #expect(DuplicateRemovalPlan.lines(.shown(dryRun: true, stopping: [])) == ["Nothing was moved: a dry run."])
        let gone = DuplicateRemovalPlan.Difference(path: sandbox.path("A/X.JPG"), reason: .gone, isKept: true)
        #expect(DuplicateRemovalPlan.lines(.stopped([gone.description])) == [
            "Nothing was moved, since:", "  \(sandbox.path("A/X.JPG")), the copy kept, isn't there any more",
        ])

        let stopped = try #require(try JSONSerialization.jsonObject(
            with: review.json(plan, batch: batch, outcome: .stopped([gone.description])),
        ) as? [String: Any])
        let notMoved = try #require(stopped["trash"] as? [String: Any])
        #expect(stopped["removed"] as? Int == 0 && notMoved["moved"] as? Bool == false)
        #expect(notMoved["stopped"] as? [String] == [gone.description] && notMoved["batch"] == nil)
        #expect((notMoved["files"] as? [[String: Any]])?.compactMap { $0["role"] as? String } == [
            "photo", "sidecar", "otherApp",
        ])

        let outcome = try await finder.trash(plan, batch, operations: operations)
        let moved = DuplicateRemovalPlan.Outcome.moved(outcome, seconds: 1.5)
        #expect(DuplicateRemovalPlan.lines(moved) == [
            "Move 1 duplicate to the Trash: done, 1 photo in 1.5 s. redlamp library undo puts them back.",
        ])
        let json = try #require(try JSONSerialization.jsonObject(
            with: review.json(plan, batch: batch, outcome: moved),
        ) as? [String: Any])
        let trash = try #require(json["trash"] as? [String: Any])
        #expect(json["removed"] as? Int == 1 && trash["moved"] as? Bool == true)
        #expect(trash["batch"] as? String == outcome.batch.uuidString && trash["state"] as? String == "finished")
        #expect(trash["title"] as? String == "Move 1 duplicate to the Trash" && trash["bytes"] as? Int64 == 150_000)
    }
}
