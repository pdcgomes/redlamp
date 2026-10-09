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
        try await metadata.run(metadata.plan(.remove([ids[1]]), in: stacks()))
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

    @Test func `moving, splitting, removing and unstacking reach every photo's sidecar, a rebuilt index keeps the order, and Undo takes them back`(
    ) async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        let paths = ["Day 1/A.NEF", "Day 1/A.JPG", "Day 2/B.NEF", "Day 3/C.NEF", "Day 4/D.NEF"]
        for path in paths {
            try sandbox.photo(path)
        }
        try sandbox.sidecar("Day 2/B.NEF", PhotoMetadata(rating: 3))
        try await sandbox.indexAll()
        let ids = try await sandbox.ids(paths)
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths)
        func stacks(in index: LibraryIndex) async throws -> Stacks {
            let engine = QueryEngine(index: index)
            try await engine.load()
            return try await StackFinder.find(in: index, store: engine.store ?? ColumnStore())
        }
        func stacks() async throws -> Stacks {
            try await stacks(in: sandbox.index)
        }
        /// Each manual stack's photos by name, in order.
        func order(in index: LibraryIndex? = nil) async throws -> [[String]] {
            let index = index ?? sandbox.index
            let manual = try await stacks(in: index).filter { $0.kind == .manual }.map(\.photos)
            return try await index.read { reader in
                try manual.map { stack in try stack.compactMap { try reader.photo(id: $0)?.name } }
            }
        }
        func stored(_ path: String) -> PhotoStack? {
            sandbox.sidecar(path)?.metadata?.stack
        }

        try await metadata.run(metadata.plan(.stack(Array(ids[2...]) + [ids[0]], top: ids[0]), in: stacks()))
        let stacked = try await order()
        #expect(stacked.count == 1 && stacked.first?.first == "A.NEF" && stacked.first?.count == 4)
        let last = try #require(stacked.first?.last)
        let lastID = try ids[#require(paths.firstIndex { $0.hasSuffix("/" + last) })]

        // Up to the top: every photo's place written, the JPEG with its raw.
        let moved = try await metadata.run(metadata.plan(.move(lastID, by: -3), in: stacks()))
        #expect(moved.title == "Move a photo up its stack" && moved.written == 5)
        let shown = try await order()
        #expect(shown.first?.first == last && shown.first?.dropFirst().first == "A.NEF")
        for (position, name) in (shown.first ?? []).enumerated() {
            let path = try #require(paths.first { $0.hasSuffix("/" + name) })
            #expect(stored(path)?.position == position && stored(path)?.top == (position == 0), "\(name)")
        }
        #expect(stored("Day 1/A.JPG") == stored("Day 1/A.NEF"))
        #expect(sandbox.sidecar("Day 2/B.NEF")?.metadata?.rating == 3)

        // An index built afresh from the sidecars finds the stack in the same order.
        let rebuilt = try await LibraryIndex.open(at: sandbox.library.url.appending(path: "Rebuilt.sqlite"), readers: 2)
        defer { rebuilt.closeAndWait() }
        let run = await IndexerRun
            .collect(LibraryIndexer(index: rebuilt, configuration: .testing()).index([sandbox.root]))
        #expect(run.failures.isEmpty)
        #expect(try await order(in: rebuilt) == shown)

        // Split before A: the moved photo alone, A and the rest a stack with A on top; then A's JPEG removed.
        let split = try await metadata.run(metadata.plan(.split(before: ids[1]), in: stacks()))
        #expect(split.title == "Split a stack")
        #expect(try await order() == [Array((shown.first ?? []).dropFirst())])
        let removed = try await metadata.run(metadata.plan(.remove([ids[1]]), in: stacks()))
        #expect(removed.title == "Remove a photo from its stack" && removed.written == 2)
        #expect(try await order().first?.count == 2 && stored("Day 1/A.JPG") == stored("Day 1/A.NEF"))
        let left = try #require(try await order().first?.last)
        let leftID = try ids[#require(paths.firstIndex { $0.hasSuffix("/" + left) })]
        let unstacked = try await metadata.run(metadata.plan(.unstack([leftID]), in: stacks()))
        #expect(unstacked.written == 2, "both photos left in the stack stand alone")
        #expect(try await order().isEmpty)

        for _ in 0 ..< 5 {
            try await metadata.undo()
        }
        #expect(paths.allSatisfy { stored($0) == nil })
        #expect(try await order().isEmpty)
        #expect(sandbox.sidecar("Day 2/B.NEF")?.metadata == PhotoMetadata(rating: 3))
    }
}
