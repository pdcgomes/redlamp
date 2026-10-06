import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

struct DuplicatePlanTests {
    @Test func `a plan never holds every copy of a group, nor a photo that isn't a confirmed copy`() async throws {
        let sandbox = try await DuplicateSandbox.make()
        defer { sandbox.remove() }
        let x = duplicateBytes(150_000, seed: 30)
        for (index, folder) in ["A", "B", "C"].enumerated() {
            try sandbox.write("\(folder)/X.JPG", x, modified: Double(index * 10))
        }
        let y = duplicateBytes(90000, seed: 31)
        try sandbox.write("A/Y.JPG", y)
        try sandbox.write("B/Y.JPG", y)
        var different = x
        different[100_000] ^= 1
        try sandbox.write("D/X.JPG", different)
        try await sandbox.indexAll()
        let finder = sandbox.finder()
        let review = try await finder.review(finder.confirm(finder.candidates()))
        let (a, b, c) = try await (sandbox.id("A/X.JPG"), sandbox.id("B/X.JPG"), sandbox.id("C/X.JPG"))
        let (ay, by, d) = try await (sandbox.id("A/Y.JPG"), sandbox.id("B/Y.JPG"), sandbox.id("D/X.JPG"))
        let group = try #require(review.groups.first { $0.size == 150_000 })
        #expect(group.keeper.photo == a && review.different.map(\.photo) == [d])

        #expect(throws: DuplicateRemovalPlan.Refusal.everyCopy(sha256: group.sha256)) {
            try DuplicateRemovalPlan(review, removing: [a, b, c])
        }
        #expect(throws: DuplicateRemovalPlan.Refusal.everyCopy(sha256: group.sha256)) {
            try DuplicateRemovalPlan(review, removing: [a, b, c, ay])
        }
        #expect(throws: DuplicateRemovalPlan.Refusal.notADuplicate(photo: d)) {
            try DuplicateRemovalPlan(review, removing: [b, d])
        }
        let unchecked = try await finder.review(finder.confirm(finder.candidates(), readingFiles: false))
        #expect(unchecked.groups.count == 2)
        #expect(throws: DuplicateRemovalPlan.Refusal.unchecked) { try DuplicateRemovalPlan(unchecked, removing: [b]) }

        let proposed = try DuplicateRemovalPlan(review, removing: [b, c, by])
        #expect(proposed.removals.map(\.photo) == [b, c, by])
        #expect(proposed.removals.map(\.kept.photo) == [a, a, ay])
        #expect(proposed.bytes == 390_000)
        // Without the keeper, the copy kept is the one that would have been proposed of those left.
        let keeperGone = try DuplicateRemovalPlan(review, removing: [a, c])
        #expect(keeperGone.removals.map(\.kept.photo) == [b, b])
        #expect(try DuplicateRemovalPlan(review, removing: []).removals.isEmpty)

        let decoded = try JSONDecoder().decode(DuplicateRemovalPlan.self, from: JSONEncoder().encode(proposed))
        #expect(decoded == proposed)
        for path in ["A/X.JPG", "B/X.JPG", "C/X.JPG", "A/Y.JPG", "B/Y.JPG", "D/X.JPG"] {
            #expect(FileManager.default.fileExists(atPath: sandbox.url(path).path))
        }
    }

    @Test func `a removal carries its sidecar, what that holds, and its other app's .xmp unless another photo shares it`(
    ) async throws {
        let sandbox = try await DuplicateSandbox.make()
        defer { sandbox.remove() }
        let x = duplicateBytes(150_000, seed: 32)
        try sandbox.write("A/IMG_0001.JPG", x, modified: 0)
        try sandbox.write("B/IMG_0001.JPG", x, modified: 10)
        try sandbox.write("C/IMG_0001.JPG", x, modified: 20)
        try sandbox.sidecar("B/IMG_0001.JPG", PhotoMetadata(rating: 0, flag: .reject))
        let unrated = Data(FixtureWriter.xmp(.init(rating: 0, label: nil, keywords: ["birds"])).utf8)
        let rated = Data(FixtureWriter.xmp(.init(rating: 2, label: nil, keywords: ["birds"])).utf8)
        // B's .xmp is named after the name it shares with its raw; C's after its own.
        try sandbox.write("B/IMG_0001.xmp", unrated)
        try sandbox.write("B/IMG_0001.ARW", duplicateBytes(300_000, seed: 33))
        try sandbox.write("C/IMG_0001.JPG.xmp", rated)
        try await sandbox.indexAll()
        let finder = sandbox.finder()
        let review = try await finder.review(finder.confirm(finder.candidates()))
        let group = try #require(review.groups.first)
        let (a, b, c) = try await (
            sandbox.id("A/IMG_0001.JPG"), sandbox.id("B/IMG_0001.JPG"), sandbox.id("C/IMG_0001.JPG"),
        )
        #expect(group.copies.map(\.photo) == [a, b, c])
        #expect(group.copies.map { $0.otherXMP?.lastPathComponent } == [nil, "IMG_0001.xmp", "IMG_0001.JPG.xmp"])
        #expect(group.copies.map(\.sharesOtherXMP) == [false, true, false])
        // B has no stars in its sidecar or its .xmp; C's .xmp is all it has.
        #expect(group.keeper == .init(photo: c, reason: .onlyEditedOrRated, editedOrRated: 1))

        let plan = try DuplicateRemovalPlan(review, removing: [a, b])
        let removals = Dictionary(uniqueKeysWithValues: plan.removals.map { ($0.photo, $0) })
        let removedB = try #require(removals[b])
        #expect(removedB.sidecar?.path == SidecarStore().url(for: sandbox.url("B/IMG_0001.JPG")).path)
        #expect(removedB.sidecarContents == .init(flag: .reject))
        #expect(removedB.otherXMP == nil)
        #expect(removals[a]?.sidecar == nil && removals[a]?.otherXMP == nil)
        #expect(removedB.kept.photo == c && removedB.kept.file.path == sandbox.url("C/IMG_0001.JPG").path)
        #expect(removedB.sha256 == group.sha256 && removedB.size == 150_000)

        let keeperRemoved = try DuplicateRemovalPlan(review, removing: [c])
        #expect(keeperRemoved.removals.first?.otherXMP?.path == sandbox.url("C/IMG_0001.JPG.xmp").path)
        #expect(keeperRemoved.removals.first?.kept.photo == a)
    }
}
