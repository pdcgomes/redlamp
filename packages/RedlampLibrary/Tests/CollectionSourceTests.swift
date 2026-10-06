import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Collections as sources (LIB-10, LIB-23): a smart collection's query from the definitions, a
/// collection's photos and a set's, each a list `LibraryLive` keeps current, with its stacks; and the
/// collections' names read again after a batch changes them.
struct CollectionSourceTests {
    /// A raw and its JPEG, two raws on their own in the same folder, and a raw in another, indexed.
    static func library() async throws -> (sandbox: KeywordSandbox, ids: [String: Int64]) {
        let sandbox = try await KeywordSandbox.make()
        let paths = [
            "Shoot/IMG_0001.ARW",
            "Shoot/IMG_0001.JPG",
            "Shoot/IMG_0002.ARW",
            "Shoot/IMG_0003.ARW",
            "Other/IMG_0100.ARW",
        ]
        for path in paths {
            try sandbox.photo(path)
        }
        try await sandbox.indexAll()
        var ids: [String: Int64] = [:]
        for path in paths {
            ids[(path as NSString).lastPathComponent] = try await sandbox.id(path)
        }
        return (sandbox, ids)
    }

    static func path(_ text: String) -> CollectionPath {
        CollectionPath(text)!
    }

    /// The photos' names, in the list's order.
    static func names(_ list: some Sequence<Int64>, _ ids: [String: Int64]) -> [String] {
        list.map { id in ids.first { $0.value == id }?.key ?? "?" }
    }

    @Test func `a smart collection is a list that follows its photos and its query, with its stacks`() async throws {
        let (sandbox, ids) = try await Self.library()
        defer { sandbox.remove() }
        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()
        let live = LibraryLive(engine: engine, configuration: .init(latency: .seconds(60)))
        let metadata = LibraryMetadata(index: sandbox.index, paths: sandbox.paths, live: live)
        let collections = metadata.collections
        try await collections.apply(.smart(Self.path("Picks/Five stars"), query: "rating=5"))
        try await collections.apply(.add([#require(ids["IMG_0003.ARW"])], to: Self.path("Picks/Selects")))
        await live.settle()

        var smart = live.open(.collection(Self.path("Picks/Five stars"))).makeAsyncIterator()
        var set = live.open(.collection(Self.path("Picks"))).makeAsyncIterator()
        let none = try #require(await smart.next())
        #expect(none.list.isEmpty && none.diff.reset)
        #expect(try Self.names(#require(await set.next()).list, ids) == ["IMG_0003.ARW"])

        let rated = try ["IMG_0001.ARW", "IMG_0001.JPG", "IMG_0002.ARW"].map { try #require(ids[$0]) }
        try await metadata.apply(.set([.rating(5)], on: rated))
        await live.settle()
        let found = try #require(await smart.next())
        #expect(Set(Self.names(found.list, ids)) == ["IMG_0001.ARW", "IMG_0001.JPG", "IMG_0002.ARW"])
        #expect(found.diff == PhotoListDiff(inserted: IndexSet(0 ..< 3)))
        let both = try #require(await set.next())
        #expect(Set(Self.names(both.list, ids)) == ["IMG_0001.ARW", "IMG_0001.JPG", "IMG_0002.ARW", "IMG_0003.ARW"])

        let stacks = try await StackFinder.find(in: sandbox.index, store: #require(engine.store))
        var selection = StackSelection()
        let stacked = StackedList(found.list, stacks: stacks)
        #expect(stacked.count == 2, "the raw and its JPEG are one cell")

        // Another query for it, from the definitions alone: the list follows, and Undo brings the first back.
        try await collections.apply(.smart(Self.path("Picks/Five stars"), query: "rating=5 name:0002"))
        await live.settle()
        let narrowed = try #require(await smart.next())
        #expect(Self.names(narrowed.list, ids) == ["IMG_0002.ARW"])
        let (fewer, diff) = stacked.updated(narrowed, selection: &selection)
        #expect(try Array(fewer) == [#require(ids["IMG_0002.ARW"])])
        #expect(diff.removed.count == 1 && diff.inserted.isEmpty, "the stack's cell goes")
        try await metadata.undo()
        await live.settle()
        #expect(try #require(await smart.next()).list.count == 3)
        #expect(try await engine.list(.collection(Self.path("Picks/Five stars"))).count == 3)
    }

    @Test func `collection terms and lists follow a rename, and a collection's own photos are its list`() async throws {
        let (sandbox, ids) = try await Self.library()
        defer { sandbox.remove() }
        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()
        let live = LibraryLive(engine: engine, configuration: .init(latency: .seconds(60)))
        let collections = LibraryMetadata(index: sandbox.index, paths: sandbox.paths, live: live).collections
        let trip = try ["IMG_0002.ARW", "IMG_0003.ARW", "IMG_0100.ARW"].map { try #require(ids[$0]) }
        try await collections.apply(.add(trip, to: Self.path("Trips/Lisbon")))
        await live.settle()
        #expect(try await Set(engine.ids("collection:lisbon")) == Set(trip))
        #expect(try await Set(engine.list(.collection(Self.path("Trips/Lisbon")))) == Set(trip))

        var renamed = live.open(.collection(Self.path("Trips/Lisboa"))).makeAsyncIterator()
        #expect(try #require(await renamed.next()).list.isEmpty)
        try await collections.apply(.rename(Self.path("Trips/Lisbon"), to: Self.path("Trips/Lisboa")))
        await live.settle()
        #expect(try Set(#require(await renamed.next()).list) == Set(trip))
        #expect(try await Set(engine.ids("collection:Lisboa")) == Set(trip))
        #expect(try await engine.ids("collection:Lisbon").isEmpty)
        #expect(try await Set(engine.ids("collection:Trips")) == Set(trip), "a set matches its collections")
        #expect(try await engine.list(.collection(Self.path("Trips/Lisbon"))).isEmpty)
    }
}
