import Foundation
import Testing
@testable import RedlampLibrary

/// A search that finds nothing (LIB-18): the term whose removal brings back the most of the source's
/// photos, from a count for each term, cancelled with the task asking for it.
struct QueryRemovalTests {
    private static func removal(_ engine: QueryEngine, _ text: String, in source: PhotoSource = .allPhotographs)
        async throws -> QueryRemoval? {
        try await engine.removal(from: LibraryQuery(parsing: text), in: source)
    }

    @Test func `a search that finds nothing names the term whose removal brings back the most photos`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        let found = try await Self.removal(engine, "camera:x-t5 rating:4 sunset")
        #expect(found?.term == "camera:x-t5" && found?.index == 0 && found?.count == 1)
        #expect(try found?.query == LibraryQuery(parsing: "rating:4 sunset"))
        #expect(try await Self.removal(engine, "flag:pick flag:reject")?.term == "flag:reject", "the last of a tie")
        let alone = try await Self.removal(engine, "kw:nothing")
        #expect(alone?.count == 8 && alone?.query == .all)
        let none = try await Self.removal(engine, "-(rating>=0 OR kw:nothing)")
        #expect(none?.term == "rating>=0" && none?.count == 8, "every photo rated 0 or more, none without it")
        #expect(try await Self.removal(engine, "rating>=3 x-")?.term == nil, "a query that finds photos")
        #expect(try await Self.removal(engine, "kw:nothing OR camera:none") == nil, "taking out an OR finds fewer")
        #expect(try await Self.removal(engine, "kw:nothing camera:none") == nil, "no term alone is in the way")
        let short = try await Self.removal(engine, "kw:nothing r5")
        #expect(short?.term == "kw:nothing" && short?.count == 1, "r5, short as it is, finds the Canon EOS R5")
        #expect(try await Self.removal(engine, "kw:nothing ab") == nil, "ab finds no folder, camera or place either")
        #expect(try await Self.removal(engine, "rating:4 ab")?.term == "ab", "short text can be in the way")

        let studio = PhotoSource.folder(
            URL(fileURLWithPath: IndexSandbox.rootPath + "/2024/Studio", isDirectory: true), includingSubfolders: false,
        )
        let inStudio = try await Self.removal(engine, "camera:x-t5 -type:png", in: studio)
        #expect(inStudio?.term == "camera:x-t5" && inStudio?.count == 2, "the studio's photos but its PNG")
    }

    @Test func `the counts stop when the task asking for them is cancelled`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let gate = QueryGate()
        let source = GatedQuerySource(base: IndexQuerySource(index: library.index), gate: gate)
        let engine = QueryEngine(source: source, timeZone: .gmt, now: { QueryTestLibrary.now })
        try await engine.load()
        let query = try LibraryQuery(parsing: "rating>=3 caption:harbour kw:nothing")
        let task = Task { try await engine.removal(from: query, in: .allPhotographs) }
        try await gate.waitForWaiters(1)
        task.cancel()
        gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        let found = try await engine.removal(from: query, in: .allPhotographs)
        #expect(found?.term == "kw:nothing" && found?.count == 1, "the Sunset over the harbour, rated 4")
    }
}
