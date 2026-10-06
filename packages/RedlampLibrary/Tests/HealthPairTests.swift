import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Library Health's raw and JPEG pairs (LIB-40): LIB-28's pairs under the rule the user picks.
struct HealthPairTests {
    /// Pairs of a raw and a JPEG (A, B, C, H) or a HEIC (D), with a JPEG (E) and a raw (F) alone: B's
    /// JPEG rated where its raw isn't, C's halves both rated, H's JPEG with keywords of its own, and A
    /// with an `.xmp` the pair shares and one of its JPEG's own.
    static func pairs() async throws -> HealthSandbox {
        let raw = try HealthImages.rawHead
        var files: [String: Data] = [:]
        for name in ["A", "B", "C", "D", "F", "H"] {
            files["Pairs/\(name).ARW"] = raw
        }
        for (seed, name) in ["A", "B", "C", "H", "E"].enumerated() {
            files["Pairs/\(name).JPG"] = HealthImages.data(.jpeg, seed: UInt64(seed + 1))
        }
        files["Pairs/D.HEIC"] = HealthImages.data(.heic, seed: 9)
        files["Pairs/A.xmp"] = Data("shared".utf8)
        files["Pairs/A.JPG.xmp"] = Data("the JPEG's own".utf8)
        let sandbox = try await HealthSandbox.make(files)
        try sandbox.sidecar("Pairs/B.JPG", PhotoMetadata(rating: 3))
        try sandbox.sidecar("Pairs/C.ARW", PhotoMetadata(rating: 2))
        try sandbox.sidecar("Pairs/C.JPG", PhotoMetadata(rating: 2))
        try sandbox.sidecar("Pairs/H.JPG", PhotoMetadata(keywords: ["Places/Lisbon"]))
        await sandbox.index()
        return sandbox
    }

    @Test func `each pair rule proposes its halves, and a half with its own decisions is listed apart`() async throws {
        let sandbox = try await Self.pairs()
        defer { sandbox.remove() }
        let health = sandbox.library()
        #expect(try await health.findings(.pairs(.keepBoth)).isEmpty, "keeping both proposes nothing")
        #expect(try await health.offered().allSatisfy { $0.check.kind != .pairs })

        let raws = try await health.findings(.pairs(.keepRaw))
        let byPath = try await Dictionary(uniqueKeysWithValues: zip(sandbox.paths(raws.photos), raws.findings))
        #expect(Set(byPath.keys) == ["Pairs/A.JPG", "Pairs/B.JPG", "Pairs/C.JPG", "Pairs/D.HEIC", "Pairs/H.JPG"])
        #expect(byPath["Pairs/A.JPG"]?.apart == nil && byPath["Pairs/D.HEIC"]?.apart == nil)
        #expect(byPath["Pairs/A.JPG"]?.reason.description == "the JPEG beside A.ARW")
        #expect(byPath["Pairs/B.JPG"]?.apart == .own([.rating]))
        #expect(byPath["Pairs/H.JPG"]?.apart == .own([.keywords]))
        #expect(byPath["Pairs/H.JPG"]?.apart?.description == "has its own keywords")
        #expect(byPath["Pairs/C.JPG"]?.apart == .decided, "rated as its raw is, so the user decided about it")
        #expect(try await Set(sandbox.paths(raws.proposed)) == ["Pairs/A.JPG", "Pairs/D.HEIC"])

        let jpegs = try await health.findings(.pairs(.keepJPEG))
        let dropped = try await Dictionary(uniqueKeysWithValues: zip(sandbox.paths(jpegs.photos), jpegs.findings))
        #expect(Set(dropped.keys) == ["Pairs/A.ARW", "Pairs/B.ARW", "Pairs/C.ARW", "Pairs/D.ARW", "Pairs/H.ARW"])
        #expect(dropped["Pairs/C.ARW"]?.apart == .decided)
        #expect(dropped["Pairs/B.ARW"]?.apart == nil, "the raw has nothing its JPEG lacks")
        #expect(dropped["Pairs/D.ARW"]?.reason.description == "the raw beside D.HEIC", "the HEIC where there's no JPEG")
    }
}
