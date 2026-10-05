import Foundation
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
}
