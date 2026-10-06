import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Manual stacks (LIB-28) made, opened and given another top as batches with Undo: each photo's sidecar
/// keeps its place, a raw and its JPEG together, so the stacks are found again from the sidecars alone.
struct StackChangeTests {
    @Test func `stacking, choosing the top and unstacking reach every photo's sidecar, and Undo takes them back`(
    ) async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        let paths = ["Day 1/A.NEF", "Day 1/A.JPG", "Day 2/B.NEF", "Day 3/C.NEF"]
        for path in paths {
            try sandbox.photo(path)
        }
        try sandbox.sidecar("Day 2/B.NEF", PhotoMetadata(rating: 3))
        try await sandbox.indexAll()
        let ids = try await sandbox.ids(paths)
        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()
        let store = try #require(engine.store)
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        func stacks() async throws -> Stacks {
            try await StackFinder.find(in: sandbox.index, store: store)
        }
        /// Each manual stack's top photo and all its photos, by name: the others' order follows their IDs.
        func names() async throws -> [(top: String, photos: Set<String>)] {
            let stacks = try await stacks().photos(.manual)
            return try await sandbox.index.read { reader in
                try stacks.map { stack in
                    let names = try stack.compactMap { try reader.photo(id: $0)?.name }
                    return (names[0], Set(names))
                }
            }
        }
        func stored() -> [PhotoStack?] {
            paths.map { sandbox.sidecar($0)?.metadata?.stack }
        }

        let stacked = try await metadata.run(metadata.plan(.stack([ids[0], ids[2], ids[3]], top: ids[2]), in: stacks()))
        #expect(stacked.title == "Stack 3 photos" && stacked.written == 4)
        #expect(try await names().map(\.top) == ["B.NEF"])
        #expect(try await names().map(\.photos) == [["A.NEF", "B.NEF", "C.NEF"]])
        let id = try #require(stored()[0]?.id)
        #expect(stored() == [PhotoStack(id: id), PhotoStack(id: id), PhotoStack(id: id, top: true), PhotoStack(id: id)])
        #expect(sandbox.sidecar("Day 2/B.NEF")?.metadata?.rating == 3)

        try await metadata.run(metadata.plan(.top(ids[3]), in: stacks()))
        #expect(try await names().map(\.top) == ["C.NEF"])
        #expect(try await names().map(\.photos) == [["A.NEF", "B.NEF", "C.NEF"]])
        try await metadata.run(metadata.plan(.unstack([ids[1]]), in: stacks()))
        #expect(try await names().map(\.top) == ["C.NEF"])
        #expect(try await names().map(\.photos) == [["B.NEF", "C.NEF"]])
        let alone = try #require(stored()[0]?.id)
        #expect(alone != id && stored()[1] == PhotoStack(id: alone))

        for _ in 0 ..< 3 {
            try await metadata.undo()
        }
        #expect(stored() == [nil, nil, nil, nil])
        #expect(try await names().isEmpty)
        #expect(sandbox.sidecar("Day 2/B.NEF")?.metadata == PhotoMetadata(rating: 3))
    }
}
