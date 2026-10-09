import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// `is:damaged` (LIB-40): the files Library Health's Damaged Files check lists as a term of the query language, for
/// the filter bar, smart collections and `redlamp library search`: those that can't be read, which lists otherwise
/// leave out, those that are empty, start as no image does or end early, but not those still being written or kept
/// anyway.
struct QueryDamagedTests {
    /// Cards: a good JPEG, an empty one, one cut short, one whose read fails, and another cut short kept anyway;
    /// Copying: one cut short and still being written.
    struct Cards {
        let sandbox: HealthSandbox
        let health: LibraryHealth
        let ids: [String: Int64]

        static func make() async throws -> Cards {
            let sandbox = try await HealthSandbox.make([
                "Cards/Good.jpg": HealthImages.data(.jpeg, seed: 1),
                "Cards/Empty.jpg": Data(),
                "Cards/Cut.jpg": HealthImages.data(.jpeg, seed: 2).dropLast(40),
                "Cards/Unreadable.jpg": HealthImages.data(.jpeg, seed: 3),
                "Cards/Kept.jpg": HealthImages.data(.jpeg, seed: 5).dropLast(40),
            ])
            try sandbox.write(["Copying/Now.jpg": HealthImages.data(.jpeg, seed: 4).dropLast(40)], modified: Date())
            await sandbox.index(fileSystem: FailingReadFileSystem(failing: [sandbox.url("Cards/Unreadable.jpg")]))
            let ids = try await sandbox.rows().mapValues(\.id)
            let health = sandbox.library()
            let found = try await health.findings(.damaged)
            try await health.keepAnyway([#require(ids["Cards/Kept.jpg"])], in: found)
            return Cards(sandbox: sandbox, health: health, ids: ids)
        }

        /// The photos' paths below the root, sorted.
        func paths(_ ids: some Sequence<Int64>) -> [String] {
            ids.map { id in self.ids.first { $0.value == id }?.key ?? "?" }.sorted()
        }

        /// The root and every folder below it.
        var root: PhotoSource {
            .folder(
                URL(fileURLWithPath: LibraryIndexer.path(sandbox.root), isDirectory: true),
                includingSubfolders: true,
            )
        }

        func remove() {
            sandbox.remove()
        }
    }

    static let found = ["Cards/Cut.jpg", "Cards/Empty.jpg", "Cards/Unreadable.jpg"]
    private static let damaged = LibraryQuery.filter(LibraryQuery.Filter(.trait, .equal, [.trait(.damaged)]))

    // MARK: - The term

    @Test func `the term is a trait the language reads and writes, standing for Library Health's check`() throws {
        #expect(try LibraryQuery(parsing: "is:damaged") == Self.damaged)
        #expect(try LibraryQuery(parsing: "IS:Damaged") == Self.damaged, "as other traits, any case")
        #expect(Self.damaged.description == "is:damaged")
        #expect(LibraryQuery.Trait.damaged.title == "Damaged Files" && LibraryQuery.Trait.damaged.query == nil)
        for text in [
            "is:damaged",
            "is:damaged rating>=3",
            "(is:panorama,damaged OR kw:x) a",
            "is:damaged -is:damaged",
        ] {
            let query = try LibraryQuery(parsing: text)
            #expect(query.findsUnreadable, "\(text) finds photos that can't be read")
            #expect(query.needsStore && !query.findsMoments)
            #expect(try LibraryQuery(parsing: query.description) == query)
            #expect(LibraryQuery(QueryRules(query)) == query)
        }
        for text in ["-is:damaged", "is!=damaged", "-(is:damaged OR rating:5)", "is:panorama"] {
            #expect(try !LibraryQuery(parsing: text).findsUnreadable, "\(text) leaves them out, as lists do")
        }
        #expect(LibraryQuery.not(.not(Self.damaged)).findsUnreadable, "under two `-`, it keeps them")
    }

    // MARK: - Searches and lists

    @Test func `a search finds the files the check lists, those that can't be read among them`() async throws {
        let cards = try await Cards.make()
        defer { cards.remove() }
        let engine = QueryEngine(index: cards.sandbox.index)
        try await engine.load()
        let checked = try await cards.health.findings(.damaged)
        #expect(cards.paths(checked.photos) == Self.found, "the check leaves out the photo kept and the one written")
        #expect(try await cards.paths(engine.ids("is:damaged")) == Self.found)
        #expect(try await cards.paths(engine.ids("is:damaged name:cut")) == ["Cards/Cut.jpg"])
        #expect(
            try await cards.paths(engine.ids("-is:damaged")) == ["Cards/Good.jpg", "Cards/Kept.jpg", "Copying/Now.jpg"],
            "what can't be read stays out, as lists leave it",
        )
        for source in [PhotoSource.allPhotographs, cards.root, .query(.all)] {
            let list = try await engine.list(source, matching: Self.damaged)
            #expect(cards.paths(list) == Self.found, "\(source)")
            #expect(try await engine.list(source).count == 5, "without the term, the photo that can't be read is out")
        }
        let search = try await LibrarySearch.run(Self.damaged, index: cards.sandbox.index)
        #expect(search.count == 3 && search.summary.hasPrefix("3 photos for is:damaged"))
    }

    @Test func `completion offers it by its name, its title and unreadable, counting the source's photos`(
    ) async throws {
        let cards = try await Cards.make()
        defer { cards.remove() }
        let engine = QueryEngine(index: cards.sandbox.index)
        try await engine.load()
        for typed in ["dama", "Damaged Fi", "unread"] {
            let offered = await engine.completions(typed, field: .trait)
            #expect(offered.first?.term == "is:damaged", "\(typed)")
        }
        let all = await engine.completions("dama", field: nil)
        #expect(all.first == QueryCompletion(field: .trait, value: "damaged", count: 2), "the source's own photos")
        let health = await engine.completions("dama", field: .trait, in: .health(.damaged))
        #expect(health.first?.count == 3, "Damaged Files' photos, the one that can't be read among them")
    }

    @Test func `every trait, orientation and colour label is offered with nothing typed, as the palette lists them`(
    ) async throws {
        let cards = try await Cards.make()
        defer { cards.remove() }
        let engine = QueryEngine(index: cards.sandbox.index)
        try await engine.load()
        let traits = await engine.values(of: .trait)
        #expect(traits.map(\.term) == LibraryQuery.Trait.allCases.map { "is:\($0.rawValue)" })
        #expect(traits.first { $0.value == "damaged" }?.count == 2, "the source's own photos, as completion counts")
        let health = await engine.values(of: .trait, in: .health(.damaged))
        #expect(health.first { $0.value == "damaged" }?.count == 3)
        let orientations = await engine.values(of: .orientation)
        #expect(orientations.map(\.value) == PhotoOrientation.allCases.map(\.rawValue))
        #expect(orientations.allSatisfy { $0.count != nil })
        #expect(await engine.values(of: .label).map(\.value) == ColorLabel.allCases.map(\.rawValue))
        #expect(await engine.values(of: .keyword).isEmpty, "keywords are the library's names, completed as typed")
    }

    @Test func `a smart collection of damaged files holds those that can't be read, as other collections don't`(
    ) async throws {
        let cards = try await Cards.make()
        defer { cards.remove() }
        let (set, damaged, jpegs) = try (
            #require(CollectionPath("Health")), #require(CollectionPath("Health/Damaged")),
            #require(CollectionPath("Health/JPEGs")),
        )
        try CollectionDefinitions(collections: [set: .set, damaged: .smart("is:damaged"), jpegs: .smart("type:jpeg")])
            .save(to: CollectionDefinitions.url(in: cards.sandbox.paths))
        let engine = QueryEngine(index: cards.sandbox.index)
        try await engine.load()
        #expect(try await cards.paths(engine.list(.collection(damaged))) == Self.found)
        let readable = ["Cards/Cut.jpg", "Cards/Empty.jpg", "Cards/Good.jpg", "Cards/Kept.jpg", "Copying/Now.jpg"]
        #expect(try await cards.paths(engine.list(.collection(jpegs))) == readable)
        #expect(
            try await cards.paths(engine.list(.collection(set))) == (readable + ["Cards/Unreadable.jpg"]).sorted(),
            "the set: the JPEGs that can be read, and the damaged files",
        )
        let unreadable = try LibraryQuery(parsing: "unreadable:yes")
        #expect(try await cards.paths(engine.list(.collection(jpegs), matching: unreadable)) == [
            "Cards/Unreadable.jpg",
        ], "a filter naming unreadable finds them among a collection's photos, as among a folder's")
        let search = try await LibrarySearch.run(.all, in: damaged, index: cards.sandbox.index)
        #expect(search.count == 3)
    }

    @Test func `keeping a photo anyway takes it out of the term's photos, and taking it back brings it in again`(
    ) async throws {
        let cards = try await Cards.make()
        defer { cards.remove() }
        let engine = cards.health.engine
        #expect(try await cards.paths(engine.ids("is:damaged")) == Self.found)
        let found = try await cards.health.findings(.damaged)
        try await cards.health.keepAnyway([#require(cards.ids["Cards/Cut.jpg"])], in: found)
        #expect(try await cards.paths(engine.ids("is:damaged")) == ["Cards/Empty.jpg", "Cards/Unreadable.jpg"])
        let kept = try await cards.health.keptAnyway().map(\.kept)
        try await cards.health.takeBack(kept)
        #expect(try await cards.paths(engine.ids("is:damaged")) == (Self.found + ["Cards/Kept.jpg"]).sorted())
    }

    @Test func `the term's photos are the check's, found without its findings' rows, paths or order`() async throws {
        let cards = try await Cards.make()
        defer { cards.remove() }
        let engine = cards.health.engine
        try await engine.load()
        // The file that can't be read has no content key: Keep Anyway keeps it by its path, size and date.
        let found = try await cards.health.findings(.damaged)
        try await cards.health.keepAnyway([#require(cards.ids["Cards/Unreadable.jpg"])], in: found)
        #expect(try await cards.paths(engine.ids("is:damaged")) == ["Cards/Cut.jpg", "Cards/Empty.jpg"])
        let checker = HealthChecker(index: cards.sandbox.index, paths: cards.sandbox.paths)
        let store = try #require(engine.snapshot()?.0)
        for store in [store, nil] {
            let checked = try await checker.damaged(store: store).photos.sorted()
            #expect(try await checker.damagedPhotos(store: store).photos == checked, "with a store: \(store != nil)")
            let among = try await checker.damagedPhotos(store: store, among: Array(cards.ids.values)).photos
            #expect(among == checked, "among every photo, with a store: \(store != nil)")
        }
        // And with nothing kept anyway, the photos still being written left out.
        let kept = try await cards.health.keptAnyway().map(\.kept)
        try await cards.health.takeBack(kept)
        let checked = try await checker.damaged(store: nil).photos.sorted()
        #expect(cards.paths(checked) == (Self.found + ["Cards/Kept.jpg"]).sorted())
        let lean = try await checker.damagedPhotos(store: nil)
        #expect(lean.photos == checked && lean.keptAnyway.isEmpty)
        let now = Date()
        #expect(
            lean.settles.map { $0 > now && $0 <= now + HealthChecker.settling } == true,
            "Copying/Now.jpg's minute",
        )
    }

    @Test func `the term's photos are kept across changes to the store, the photos changed looked at again`(
    ) async throws {
        let cards = try await Cards.make()
        defer { cards.remove() }
        let (engine, index) = (cards.health.engine, cards.sandbox.index)
        try await engine.load()
        #expect(try await cards.paths(engine.ids("is:damaged")) == Self.found)
        let good = try #require(cards.ids["Cards/Good.jpg"])
        func health(_ damage: PhotoHealth.Damage?) async throws {
            try await index.write { writer in
                let row = try #require(try writer.photo(id: good))
                try writer.setHealth(
                    damage.map { PhotoHealth(size: row.size, modified: row.modified, damage: $0) }, forPhoto: good,
                    name: row.name,
                )
            }
            try await engine.update(photos: [good])
        }
        // A rating on a photo it doesn't find leaves them as they were; the photo found empty when it's read again is
        // among them, and once it's whole again it isn't.
        try await index.write { try $0.setOrganising([.rating(3)], forPhotos: [good]) }
        try await engine.update(photos: [good])
        #expect(try await cards.paths(engine.ids("is:damaged")) == Self.found)
        try await health(.empty)
        #expect(try await cards.paths(engine.ids("is:damaged")) == (Self.found + ["Cards/Good.jpg"]).sorted())
        try await health(nil)
        #expect(try await cards.paths(engine.ids("is:damaged")) == Self.found)
        // Keep Anyway changes no photo's row: the term finds its photos again.
        let found = try await cards.health.findings(.damaged)
        try await cards.health.keepAnyway([#require(cards.ids["Cards/Cut.jpg"])], in: found)
        #expect(try await cards.paths(engine.ids("is:damaged")) == ["Cards/Empty.jpg", "Cards/Unreadable.jpg"])
    }

    @Test func `before the store is ready, a search with the term waits for it rather than ask SQL`() async throws {
        let cards = try await Cards.make()
        defer { cards.remove() }
        let engine = QueryEngine(index: cards.sandbox.index)
        #expect(!engine.isLoaded)
        #expect(try await cards.paths(engine.ids("is:damaged")) == Self.found)
        #expect(engine.isLoaded)
    }
}
