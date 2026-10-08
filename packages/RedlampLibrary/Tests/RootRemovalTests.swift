import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Roots taken out of the library (LIB-05, LIB-10): a root Folders no longer has leaves every list, count and
/// search at once, then the index, a batch at a time; a quit partway shows none of it, and the next launch sweeps
/// the rest; indexing the folder again brings it back from its sidecars; and the roots still followed keep
/// their photos, whichever holds the other.
struct RootRemovalTests {
    /// Two roots, Trip (two photos, one below) and Home (one), indexed; a photo of each in Lisbon's
    /// collection with its keyword, Trip's first rated.
    static func library(batchSize: Int = 100) async throws -> (sandbox: KeywordSandbox, indexer: LibraryIndexer) {
        let sandbox = try await KeywordSandbox.make()
        for path in ["Trip/IMG_0001.JPG", "Trip/Day 2/IMG_0002.JPG", "Home/IMG_0003.JPG"] {
            try sandbox.photo(path)
        }
        try sandbox.sidecar("Trip/IMG_0001.JPG", PhotoMetadata(
            rating: 3, keywords: ["Places/Lisbon"], collections: ["Trips/Lisbon"],
        ))
        try sandbox.sidecar(
            "Home/IMG_0003.JPG",
            PhotoMetadata(keywords: ["Places/Lisbon"], collections: ["Trips/Lisbon"]),
        )
        let indexer = LibraryIndexer(index: sandbox.index, configuration: .testing(batchSize: batchSize))
        let run = await IndexerRun.collect(indexer.index([sandbox.url("Trip"), sandbox.url("Home")]))
        #expect(run.failures.isEmpty, "\(run.failures)")
        return (sandbox, indexer)
    }

    static let lisbon = CollectionPath("Trips/Lisbon")!

    /// The counts made from the index: the collection's photos and the keyword's.
    static func counts(_ sandbox: KeywordSandbox) async throws -> (collection: Int?, keyword: Int?) {
        let collections = try await LibraryMetadata(index: sandbox.index, paths: sandbox.paths).collections.list()
        let keywords = try await LibraryKeywords(index: sandbox.index, paths: sandbox.paths).list()
        return (collections.collections[lisbon]?.photos, keywords.keywords[KeywordPath("Places/Lisbon")!]?.photos)
    }

    @Test func `a root taken out leaves every list, count and search at once, then the index`() async throws {
        let (sandbox, indexer) = try await Self.library(batchSize: 1)
        defer { sandbox.remove() }
        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()
        let live = LibraryLive(engine: engine, configuration: .init(latency: .seconds(60)))
        let home = try await sandbox.id("Home/IMG_0003.JPG")
        let trip = try await sandbox.ids(["Trip/IMG_0001.JPG", "Trip/Day 2/IMG_0002.JPG"])
        var all = live.open(.allPhotographs).makeAsyncIterator()
        var collection = live.open(.collection(Self.lisbon)).makeAsyncIterator()
        #expect(try #require(await all.next()).list.count == 3)
        #expect(try Set(#require(await collection.next()).list) == Set([home, trip[0]]))
        #expect(try await Self.counts(sandbox) == (2, 2))

        let roots = LibraryRoots(index: sandbox.index, indexer: indexer, live: live)
        let removal = try #require(try await roots.remove(sandbox.url("Trip"), keeping: [sandbox.url("Home")]))
        #expect(removal.photos == trip.sorted())
        // As `remove` returns, however far the sweep has gone, the lists, searches and counts leave Trip out.
        let left = try #require(await all.next())
        #expect(Array(left.list) == [home])
        #expect(left.diff.removed.count == 2)
        #expect(try Array(#require(await collection.next()).list) == [home])
        #expect(try await engine.ids("kw:Lisbon") == [home])
        #expect(try await engine.ids("rating>=3").isEmpty)
        #expect(try await engine.ids("folder:\"Day 2\"").isEmpty, "its folders leave the small tables")
        #expect(try await engine.photos(named: "IMG_0001").count == 0, "the palette finds none of its photos")
        let folders = try #require(engine.snapshot()).1.names.folders.values
        #expect(!folders.contains { $0.hasPrefix(LibraryIndexer.path(sandbox.url("Trip"))) }, "nor its folders")
        #expect(try await Self.counts(sandbox) == (1, 1))

        await roots.swept()
        let (photos, paths, marked) = try await sandbox.index.read { reader in
            try (reader.photoCount(), reader.roots().map(\.path), reader.removedRoots())
        }
        #expect(photos == 1)
        #expect(paths == [LibraryIndexer.path(sandbox.url("Home"))])
        #expect(marked.isEmpty)
        let folder = LibraryIndexer.path(sandbox.url("Trip"))
        #expect(try await sandbox.index.read { try $0.folder(path: folder) } == nil)
        #expect(try await engine.list(.allPhotographs).ids == [home])
        #expect(FileManager.default.fileExists(atPath: sandbox.url("Trip/IMG_0001.JPG.redlamp").path))
    }

    @Test func `indexing a folder taken out again brings back its ratings, keywords and collections`() async throws {
        let (sandbox, indexer) = try await Self.library()
        defer { sandbox.remove() }
        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()
        let live = LibraryLive(engine: engine)
        let roots = LibraryRoots(index: sandbox.index, indexer: indexer, live: live)
        try await roots.remove(sandbox.url("Trip"), keeping: [sandbox.url("Home")])
        // Asked for before the sweep has run: it's indexed once Trip's rows are gone.
        let events = indexer.index([sandbox.url("Trip")])
        await roots.swept()
        for await event in events {
            live.receive(event)
        }
        await live.settle()
        let first = try await sandbox.id("Trip/IMG_0001.JPG")
        #expect(try await engine.ids("rating>=3") == [first])
        #expect(try await sandbox.indexed("Trip/IMG_0001.JPG") == ["Places/Lisbon"])
        #expect(try await engine.list(.allPhotographs).count == 3)
        #expect(try await Self.counts(sandbox) == (2, 2))
        #expect(try await sandbox.index.read { try $0.removedRoots() }.isEmpty)
    }

    @Test func `a root taken out never shows in a store built or mapped before its sweep is over`() async throws {
        let (sandbox, indexer) = try await Self.library()
        defer { sandbox.remove() }
        let home = try await sandbox.id("Home/IMG_0003.JPG")
        // Marked, one photo swept, and quit: no list, search or table shows the rest.
        let trip = LibraryIndexer.path(sandbox.url("Trip"))
        let removal = try #require(try await sandbox.index.write { try $0.markRemoved(trip, keeping: []) })
        _ = try await sandbox.index.write { try $0.sweepRemoved(limit: 1) }
        let built = QueryEngine(index: sandbox.index)
        try await built.load()
        #expect(try await built.list(.allPhotographs).ids == [home])
        #expect(try await built.ids("kw:Lisbon") == [home])
        #expect(try await built.ids("folder:Trip").isEmpty)
        try await built.saveSnapshot()
        let mapped = QueryEngine(index: sandbox.index)
        try await mapped.load()
        #expect(mapped.isMapped)
        #expect(try await mapped.list(.allPhotographs).ids == [home])

        // The next launch sweeps the rest.
        let roots = LibraryRoots(index: sandbox.index, indexer: indexer, live: LibraryLive(engine: mapped))
        await roots.resume()
        await roots.swept()
        let left = try await sandbox.index.read { reader in
            try (
                reader.photoCount(),
                reader.root(path: trip),
                reader.removedRoots(),
                reader.folders(inRoot: removal.root),
            )
        }
        #expect(left.0 == 1 && left.1 == nil && left.2.isEmpty && left.3.isEmpty)
        #expect(try await mapped.list(.allPhotographs).ids == [home])
    }

    @Test func `roots none followed is, holds or is inside leave, but an import's destination stays`() async throws {
        let (sandbox, indexer) = try await Self.library()
        defer { sandbox.remove() }
        for path in ["Imports/IMG_0004.JPG", "Work/Client/IMG_0005.JPG"] {
            try sandbox.photo(path)
        }
        let run = await IndexerRun.collect(indexer.index([sandbox.url("Imports"), sandbox.url("Work/Client")]))
        #expect(run.failures.isEmpty, "\(run.failures)")
        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()
        let roots = LibraryRoots(index: sandbox.index, indexer: indexer, live: LibraryLive(engine: engine))

        let removed = try await roots.removeUnfollowed(
            [sandbox.url("Home"), sandbox.url("Work")], keeping: [sandbox.url("Imports")],
        )
        #expect(removed.map(\.path) == [LibraryIndexer.path(sandbox.url("Trip"))])
        await roots.swept()
        let left = try await sandbox.index.read { try $0.roots().map(\.path) }
        #expect(Set(left) == Set(["Home", "Imports", "Work/Client"].map { LibraryIndexer.path(sandbox.url($0)) }))
        #expect(try await engine.list(.allPhotographs).count == 3)
    }

    @Test func `a root still followed inside one taken out keeps its photos, and one holding it takes its folders`(
    ) async throws {
        let sandbox = try await KeywordSandbox.make()
        defer { sandbox.remove() }
        for path in ["Work/IMG_0001.JPG", "Work/Client/IMG_0002.JPG", "Work/Client/Job/IMG_0003.JPG"] {
            try sandbox.photo(path)
        }
        // Client first, then Work around it, as Folders adds a folder holding one it has.
        let indexer = LibraryIndexer(index: sandbox.index, configuration: .testing())
        for root in ["Work/Client", "Work"] {
            let run = await IndexerRun.collect(indexer.index([sandbox.url(root)]))
            #expect(run.failures.isEmpty, "\(run.failures)")
        }
        let engine = QueryEngine(index: sandbox.index)
        try await engine.load()
        let live = LibraryLive(engine: engine)
        let roots = LibraryRoots(index: sandbox.index, indexer: indexer, live: live)
        let (work, client) = (sandbox.url("Work"), sandbox.url("Work/Client"))
        let inside = try await sandbox.ids(["Work/Client/IMG_0002.JPG", "Work/Client/Job/IMG_0003.JPG"])

        // Client taken out while Work holds it: nothing leaves.
        #expect(try await roots.remove(client, keeping: [work]) == nil)
        #expect(try await engine.list(.allPhotographs).count == 3)
        #expect(try await sandbox.index.read { try $0.root(path: LibraryIndexer.path(client)) } == nil)

        // Client followed again, and Work taken out: Client's photos stay, with their rows.
        let again = await IndexerRun.collect(indexer.index([client]))
        #expect(again.failures.isEmpty, "\(again.failures)")
        #expect(try await sandbox.ids(["Work/Client/IMG_0002.JPG", "Work/Client/Job/IMG_0003.JPG"]) == inside)
        let removal = try #require(try await roots.remove(work, keeping: [client]))
        #expect(try await removal.photos == [sandbox.id("Work/IMG_0001.JPG")])
        await roots.swept()
        #expect(try await Set(engine.list(.allPhotographs).ids) == Set(inside))
        let (owner, top) = try await sandbox.index.read { reader in
            try (reader.root(path: LibraryIndexer.path(client)), reader.folder(path: LibraryIndexer.path(client)))
        }
        #expect(top?.root == owner?.id && top?.parent == nil)
        #expect(try await sandbox.ids(["Work/Client/IMG_0002.JPG", "Work/Client/Job/IMG_0003.JPG"]) == inside)
    }
}
