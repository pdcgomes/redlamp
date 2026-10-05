import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampLibrary

struct DuplicateReviewTests {
    static func copy(
        _ photo: Int64, _ path: String, modified: TimeInterval, rating: Int = 0,
        sidecar: DuplicateReview.SidecarContents? = nil,
    ) -> DuplicateReview.Copy {
        DuplicateReview.Copy(
            photo: photo, url: URL(fileURLWithPath: path), folder: (path as NSString).deletingLastPathComponent,
            size: 1000, captured: nil, modified: Date(timeIntervalSince1970: modified), rating: rating,
            sidecar: sidecar, sidecarURL: nil, otherXMP: nil, sharesOtherXMP: false,
            status: .duplicate(sha256: Data([1])),
        )
    }

    @Test func `the copy proposed to keep is an edited or rated one, then the oldest, then the one with the shortest path`() {
        func keeper(_ copies: [DuplicateReview.Copy]) -> DuplicateReview.Keeper {
            DuplicateReview.keeper(of: copies)
        }
        let plain = [
            Self.copy(1, "/P/Imports/IMG_1.JPG", modified: 200),
            Self.copy(2, "/P/2019/IMG_1.JPG", modified: 100),
        ]
        #expect(keeper(plain) == .init(photo: 2, reason: .oldest, editedOrRated: 0))
        #expect(keeper(plain).description == "the oldest")

        let edited = [
            Self.copy(1, "/P/A/IMG_1.JPG", modified: 100),
            Self.copy(2, "/P/B/IMG_1.JPG", modified: 200, sidecar: .init(hasEdits: true)),
        ]
        #expect(keeper(edited) == .init(photo: 2, reason: .onlyEditedOrRated, editedOrRated: 1))
        #expect(keeper(edited).description == "the only copy edited or rated")

        // A rating another app wrote counts.
        let rated = [
            Self.copy(1, "/P/A/IMG_1.JPG", modified: 100),
            Self.copy(2, "/P/B/IMG_1.JPG", modified: 200, rating: 3),
        ]
        #expect(keeper(rated).photo == 2)

        let several = [
            Self.copy(1, "/P/A/IMG_1.JPG", modified: 50),
            Self.copy(2, "/P/B/IMG_1.JPG", modified: 300, sidecar: .init(rating: 2)),
            Self.copy(3, "/P/C/IMG_1.JPG", modified: 200, sidecar: .init(hasEdits: true, flag: .pick)),
        ]
        #expect(keeper(several) == .init(photo: 3, reason: .oldest, editedOrRated: 2))
        #expect(keeper(several).description == "the oldest of the 2 edited or rated copies")

        // Dates within 2 seconds, as FAT and exFAT keep them, are as old as each other.
        let asOld = [
            Self.copy(1, "/P/Imports/2024/IMG_1.JPG", modified: 100),
            Self.copy(2, "/P/B/IMG_1.JPG", modified: 101.5),
            Self.copy(3, "/P/A/IMG_1.JPG", modified: 100),
        ]
        #expect(keeper(asOld) == .init(photo: 3, reason: .shortestPath, editedOrRated: 0))
        #expect(keeper(asOld).description == "the shortest path of the oldest")
        let apart = [
            Self.copy(1, "/P/A Longer Folder/IMG_1.JPG", modified: 100),
            Self.copy(2, "/P/A/IMG_1.JPG", modified: 103),
        ]
        #expect(keeper(apart) == .init(photo: 1, reason: .oldest, editedOrRated: 0))
    }

    @Test func `copies whose sidecars differ are duplicates still, and the review says what each sidecar holds`(
    ) async throws {
        let sandbox = try await DuplicateSandbox.make()
        defer { sandbox.remove() }
        let x = duplicateBytes(120_000, seed: 20)
        try sandbox.write("A/X.JPG", x, modified: 0)
        try sandbox.write("B/X.JPG", x, modified: 10)
        try sandbox.write("C/X.JPG", x, modified: 20)
        try sandbox.sidecar("A/X.JPG", PhotoMetadata(rating: 3, flag: .pick))
        var keywords = PhotoMetadata()
        keywords.unknownFields["keywords"] = .array([.string("birds"), .string("Places/Portugal")])
        try sandbox.sidecar("C/X.JPG", keywords, edited: true)
        let y = duplicateBytes(80000, seed: 21)
        try sandbox.write("A/Y.JPG", y)
        try sandbox.write("B/Y.JPG", y)
        try sandbox.sidecar("A/Y.JPG", PhotoMetadata(label: .red))
        try sandbox.sidecar("B/Y.JPG", PhotoMetadata(label: .red))
        try await sandbox.indexAll()

        let finder = sandbox.finder()
        let review = try await finder.review(finder.confirm(finder.candidates()))
        #expect(review.checkedFiles && review.groups.count == 2)
        let group = try #require(review.groups.first { $0.size == 120_000 })
        #expect(group.copies.map(\.url.lastPathComponent) == ["X.JPG", "X.JPG", "X.JPG"])
        #expect(group.copies.map(\.sidecar) == [
            .init(rating: 3, flag: .pick), nil, .init(hasEdits: true, keywords: ["birds", "Places/Portugal"]),
        ])
        #expect(group.copies.map(\.sidecarURL?.path) == [
            SidecarStore().url(for: sandbox.url("A/X.JPG")).path, nil,
            SidecarStore().url(for: sandbox.url("C/X.JPG")).path,
        ])
        #expect(group.sidecarsDiffer)
        #expect(try await group.keeper == .init(photo: sandbox.id("A/X.JPG"), reason: .oldest, editedOrRated: 2))
        #expect(group.copies.map(\.size) == [120_000, 120_000, 120_000] && group.reclaimable == 240_000)

        let same = try #require(review.groups.first { $0.size == 80000 })
        #expect(!same.sidecarsDiffer && same.copies.allSatisfy { $0.sidecar == .init(label: .red) })
        #expect(review.reclaimable == 320_000)
    }
}
