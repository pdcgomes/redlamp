import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Library Health's exact duplicates (LIB-40): LIB-39's groups, confirmed by the full hashes the index
/// records, as the first check.
struct HealthDuplicateTests {
    @Test func `exact duplicates are the first check, the copy kept proposed and the decided copies apart`(
    ) async throws {
        let copy = HealthImages.data(.jpeg, seed: 4)
        let sandbox = try await HealthSandbox.make([
            "A/IMG_1.jpg": copy, "B/IMG_1.jpg": copy, "C/IMG_1.jpg": copy, "Cards/Empty.jpg": Data(),
        ])
        defer { sandbox.remove() }
        try sandbox.sidecar("A/IMG_1.jpg", PhotoMetadata(rating: 2))
        try sandbox.sidecar("B/IMG_1.jpg", PhotoMetadata(rating: 3))
        await sandbox.index()
        let health = sandbox.library()
        let unhashed = try await health.findings(.duplicates)
        #expect(unhashed.isEmpty && unhashed.unconfirmed == 3, "candidates count once their hashes are recorded")

        try await health.confirmDuplicates()
        let offered = try await health.offered()
        #expect(offered.map(\.check) == [.duplicates, .damaged])
        let found = try #require(offered.first)
        let byPath = try await Dictionary(uniqueKeysWithValues: zip(sandbox.paths(found.photos), found.findings))
        #expect(byPath["A/IMG_1.jpg"]?.proposal == .keep)
        #expect(byPath["A/IMG_1.jpg"]?.reason
            .description == "the copy kept: the shortest path of the oldest of the 2 edited or rated copies")
        #expect(byPath["B/IMG_1.jpg"]?.apart == .decided, "rated, so it's left unless chosen")
        #expect(byPath["C/IMG_1.jpg"]?.proposal == .trash && byPath["C/IMG_1.jpg"]?.apart == nil)
        #expect(byPath["C/IMG_1.jpg"]?.reason
            .description == "byte-identical to \(LibraryIndexer.path(sandbox.url("A/IMG_1.jpg")))")
        #expect(Set(found.findings.map(\.group)).count == 1)
        #expect(try await sandbox.paths(found.proposed) == ["C/IMG_1.jpg"])
    }

    @Test func `confirming sweeps the hashes of copies nothing can bring back, and keeps those Undo can`(
    ) async throws {
        let copy = HealthImages.data(.jpeg, seed: 5)
        let sandbox = try await HealthSandbox.make(["A/IMG_1.jpg": copy, "B/Copy/IMG_1.jpg": copy])
        defer { sandbox.remove() }
        await sandbox.index()
        let health = sandbox.library()
        func hashed() async throws -> Set<Int64> {
            try await sandbox.index.read { reader in
                try Set(reader.database.prepare("SELECT photo FROM photo_hashes").map { $0.int64(at: 0) })
            }
        }
        try await health.confirmDuplicates()
        let rows = try await sandbox.rows()
        let (kept, copied) = try (#require(rows["A/IMG_1.jpg"]?.id), #require(rows["B/Copy/IMG_1.jpg"]?.id))
        #expect(try await hashed() == [kept, copied])

        let plan = try await health.plan(health.findings(.duplicates))
        #expect(plan.photos == [copied])
        try await health.run(plan)
        try await health.confirmDuplicates()
        #expect(try await hashed() == [kept, copied], "Undo can bring the copy back under its ID")

        try FileManager.default.removeItem(at: sandbox.paths.root.appending(path: "File Operations"))
        try await health.confirmDuplicates()
        #expect(try await hashed() == [kept], "with no journal, nothing can bring the copy back")
    }
}
