import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// What the filter bar asks of the query engine (LIB-18): missing and offline photos, sorts by the
/// file's date and size, facets by day, ISO, focal length and aperture, the metadata columns' counts,
/// the rule form, a source's photos matching a query, and completions.
struct QueryFilterBarTests {
    /// `QueryTestLibrary` with sizes, file dates and states: photo n is n MB and modified 9 - n days
    /// into 2020, photos 2 and 7 are offline and photo 4 is missing.
    static func library() async throws -> QueryTestLibrary {
        let library = try await QueryTestLibrary.make()
        let ids = library.ids
        try await library.index.write { writer in
            for (offset, id) in ids.enumerated() {
                let number = offset + 1
                let state = [2: 2, 7: 2, 4: 1][number] ?? 0
                try writer.database.execute("""
                UPDATE photos SET size = \(number * 1_000_000), modified = \(1_577_836_800 + (9 - number) * 86400),
                  state = \(state) WHERE id = \(id)
                """)
            }
        }
        return library
    }

    private static func folder(_ path: String) -> URL {
        URL(fileURLWithPath: IndexSandbox.rootPath + "/" + path, isDirectory: true)
    }

    private static func counts(_ column: FacetColumnCounts?) -> [String?: Int] {
        Dictionary(uniqueKeysWithValues: (column?.values ?? []).map { ($0.name, $0.count) })
    }

    @Test func `missing and offline photos are filters, in the column store and in SQL alike`() async throws {
        let library = try await Self.library()
        defer { library.remove() }
        for loaded in [true, false] {
            let engine = try await library.engine(loaded: loaded)
            #expect(try await library.numbers(engine.ids("offline:yes")).sorted() == [2, 7], "\(loaded)")
            #expect(try await library.numbers(engine.ids("missing:yes")) == [4])
            #expect(try await library.numbers(engine.ids("-offline:yes -missing:yes")).sorted() == [1, 3, 5, 6, 8])
            #expect(try await library.numbers(engine.ids("missing:yes OR offline:yes")).sorted() == [2, 4, 7])
            #expect(try await engine.ids("offline:no").count == 6)
        }
        #expect(try LibraryQuery(parsing: "missing:yes -offline:yes").description == "missing:yes -offline:yes")
        #expect(throws: LibraryQueryError.self) { try LibraryQuery(parsing: "offline:maybe") }
    }

    @Test func `photos sort by their file's date and size both ways, and the order kept follows changes`() async throws {
        let library = try await Self.library()
        defer { library.remove() }
        let columns = try await library.engine(loaded: true)
        let sql = try await library.engine(loaded: false)
        #expect(columns.store?.keepsOrder(.size) == false, "no order by size until a search asks for one")
        for key in [QuerySort.Key.modified, .size] {
            for ascending in [true, false] {
                let sort = QuerySort(key, ascending: ascending)
                let ids = try await columns.ids("", sort: sort)
                #expect(try await sql.ids("", sort: sort) == ids, "\(key) \(ascending)")
                let expected = key == .size ? Array(1 ... 8) : Array((1 ... 8).reversed())
                #expect(library.numbers(ids) == (ascending ? expected : expected.reversed()), "\(key) \(ascending)")
            }
        }
        #expect(columns.store?.keepsOrder(.size) == true && columns.store?.keepsOrder(.modified) == true)

        let first = library.ids[0]
        try await library.index
            .write { try $0.database.execute("UPDATE photos SET size = 100000000 WHERE id = \(first)") }
        try await columns.update(photos: [first])
        #expect(try await library.numbers(columns.ids("", sort: QuerySort(.size))) == [2, 3, 4, 5, 6, 7, 8, 1])
        let list = try await columns.list(.allPhotographs, sort: QuerySort(.modified))
        #expect(library.numbers(list) == [8, 7, 6, 5, 4, 3, 2, 1])
    }

    @Test func `facets count photos by day, ISO, focal length and aperture`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        var facets: [Facet: [String?: Int]] = [:]
        for try await counts in engine.facets([.day, .iso, .focal, .aperture], for: .all) {
            #expect(counts.total == 8, "\(counts.facet)")
            facets[counts.facet] = Dictionary(uniqueKeysWithValues: counts.values.map { ($0.name, $0.count) })
        }
        #expect(facets[.day] == [
            "2014-07-04": 1, "2019-08-20": 1, "2019-08-21": 1, "2024-06-14": 2, "2024-07-01": 1, nil: 2,
        ])
        #expect(facets[.iso] == ["64": 1, "100": 1, "200": 1, "800": 1, "3200": 1, "6400": 1, nil: 2])
        #expect(facets[.focal] == ["6.8": 1, "23": 1, "35": 2, "50": 1, nil: 3])
        #expect(facets[.aperture] == ["1.4": 1, "1.78": 1, "2.8": 1, "4": 1, "8": 1, nil: 3])

        // A search cancels the facets in progress, so they're all counted before any filter is searched.
        var counted: [FacetCounts] = []
        for try await counts in engine.facets([.focal, .day], for: .all) {
            counted.append(counts)
        }
        #expect(counted.map(\.facet) == [.focal, .day])
        for counts in counted {
            for value in counts.values {
                guard let filter = value.filter else { continue }
                #expect(
                    try await engine.ids(filter.description).count == value.count,
                    "\(filter) finds the photos it counts",
                )
            }
        }
    }

    @Test func `columns count a source's photos each over its own query, a keyword with those inside it`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        let source = PhotoSource.folder(Self.folder("2024"), includingSubfolders: true)
        let requests = try [
            FacetColumnRequest(.camera, query: .all),
            FacetColumnRequest(.keyword, query: LibraryQuery(parsing: "camera:X-T5")),
            FacetColumnRequest(.date, query: LibraryQuery(parsing: "camera:X-T5 rating>=4")),
        ]
        var columns: [Int: FacetColumnCounts] = [:]
        for try await counts in engine.columns(requests, in: source) {
            columns[counts.index] = counts
        }
        #expect(columns[0]?.total == 5 && columns[0]?.column == .camera)
        #expect(Self.counts(columns[0]) == ["Apple iPhone 15 Pro": 1, "Canon EOS R5": 1, "Fujifilm X-T5": 2, nil: 1])
        #expect(columns[1]?.total == 2)
        #expect(Self.counts(columns[1]) == [
            "Animals": 1, "Animals/Birds": 1, "Places": 1, "Places/Portugal": 1, "Places/Portugal/Lisbon": 1, nil: 1,
        ])
        #expect(columns[1]?.values.compactMap(\.name).first == "Animals", "keywords in the Finder's order")
        #expect(columns[2]?.total == 1 && Self.counts(columns[2]) == ["2024-06-14": 1])

        let second = library.ids[1]
        try await library.index.write { try $0.setKeywords(["Places/Portugal/Porto"], forPhoto: second) }
        try await engine.update(photos: [second])
        for try await counts in engine.columns([requests[1]], in: source) {
            #expect(Self.counts(counts)["Places/Portugal"] == 2, "a parent counts each photo once")
            #expect(Self.counts(counts)["Places"] == 2 && Self.counts(counts)[nil] == nil)
        }
    }

    @Test func `columns count creators, cities, countries, collections and labels, custom ones included`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        let kinds: [FacetColumn] = [.creator, .city, .country, .collection, .customLabel, .label]
        var columns: [FacetColumn: FacetColumnCounts] = [:]
        for try await counts in engine.columns(kinds.map { FacetColumnRequest($0, query: .all) }, in: .allPhotographs) {
            columns[counts.column] = counts
        }
        #expect(Self.counts(columns[.creator]) == [
            "Ana Silva": 1, "Ana Silva; João Costa": 1, "Studio Acme": 1, "Élodie Tremblay": 1, nil: 4,
        ])
        #expect(Self.counts(columns[.city]) == ["Lisboa": 2, "Porto": 1, "Lagoa": 1, "Montréal": 1, nil: 3])
        #expect(Self.counts(columns[.country]) == ["Portugal": 4, "Canada": 1, nil: 3])
        #expect(Self.counts(columns[.collection]) == [
            "Portfolio": 2, "Portfolio/2024": 2, "Clients": 1, "AC%2FDC": 1, nil: 3,
        ])
        #expect(Self.counts(columns[.customLabel]) == ["Hero": 1, "Client": 1, nil: 6])
        #expect(Self.counts(columns[.label]) == [
            "none": 1, "red": 1, "yellow": 1, "green": 1, "blue": 1, "purple": 1, "Hero": 1, "Client": 1,
        ])
        #expect(columns[.label]?.values.suffix(2).compactMap(\.name) == ["Client", "Hero"], "after the colours")
        for (column, counts) in columns {
            for value in counts.values {
                guard let filter = value.filter else { continue }
                let found = try await engine.ids(filter.description).count
                let exact = column != .creator
                #expect(exact ? found == value.count : found >= value.count, "\(filter) finds the photos it counts")
            }
        }

        let ana = library.ids[1]
        try await library.index.write { try $0.setCollections(["Clients"], forPhoto: ana) }
        try await engine.update(photos: [ana])
        for try await counts in engine.columns([FacetColumnRequest(.collection, query: .all)], in: .allPhotographs) {
            #expect(Self.counts(counts)["Clients"] == 2 && Self.counts(counts)[nil] == 2, "a photo put in one")
        }
    }

    @Test func `completions offer collections by path, and custom labels after the colours`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        let collections = await engine.completions("port", field: .collection)
        #expect(collections.map(\.term) == ["collection:Portfolio", "collection:Portfolio/2024"])
        #expect(await engine.completions("ac/", field: .collection).map(\.value) == ["AC%2FDC"])
        #expect(await engine.completions("her", field: .label).map(\.term) == ["label:Hero"])
        let clients = await engine.completions("cli", field: nil)
        #expect(clients.map(\.term).starts(with: ["label:Client", "collection:Clients"]))
    }

    @Test func `traits are offered as names are typed, each with the photos of the source it finds`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        let pano = await engine.completions("pano", field: nil)
        #expect(pano.first == QueryCompletion(field: .trait, value: "panorama", count: 2))
        #expect(pano.first?.term == "is:panorama")
        let light = await engine.completions("l", field: .trait)
        #expect(light.map(\.value) == ["low-light", "long-exposure", "no-location", "high-resolution"])
        #expect(light.map(\.count) == [2, 1, 6, 2], "names starting, the shorter first, then words, then inside a word")
        let studio = PhotoSource.folder(Self.folder("2024/Studio"), includingSubfolders: false)
        let inStudio = await engine.completions("res", field: .trait, in: studio)
        #expect(inStudio.map(\.term) == ["is:high-resolution"] && inStudio.first?.count == 1)
        #expect(await engine.completions("loca", field: nil).map(\.term) == ["is:no-location"])
        for trait in LibraryQuery.Trait.allCases {
            guard let query = trait.query else { continue }
            let expanded = try await engine.ids(query.description)
            #expect(try await engine.ids("is:\(trait.rawValue)") == expanded, "\(trait) is \(query)")
        }
    }

    @Test func `a query's rules give it back, and rules give back their query`() throws {
        let texts = [
            "", "sunset", "-sunset", "rating>=3 flag:pick", "label:red OR label:blue", "-(a OR b)", "-(a b)",
            "(rating>=4 OR flag:pick) -label:none", "--x", "a (b OR (c -d))", "kw:\"Places/Portugal\" -flag:reject",
        ]
        for text in texts {
            let query = try LibraryQuery(parsing: text)
            let rules = QueryRules(query)
            #expect(LibraryQuery(rules) == query, "\(text)")
            #expect(rules.description == query.description)
            #expect(QueryRules(LibraryQuery(rules)) == rules)
        }
        #expect(try QueryRules(parsing: "rating>=3 flag:pick").rules.count == 2)
        #expect(try QueryRules(parsing: "-(a OR b)").match == .none)
        #expect(try QueryRules(parsing: "label:red OR label:blue").match == .any)
        #expect(LibraryQuery(QueryRules(match: .none)) == .all && LibraryQuery(QueryRules(match: .any)) == .all)

        let names = QueryNames(
            folders: [1: "/Volumes/Test/2024/Lisbon"], cameras: [1: "Fujifilm X-T5"], lenses: [1: "XF35mmF1.4 R"],
            keywords: [1: "Places/Portugal"],
        )
        var generator = QueryDifferentialTests.Generator(
            random: SeededRandom(seed: 41), words: ["sunset", "wedding", "DSCF", "Café"], names: names,
        )
        for _ in 0 ..< 300 {
            let query = try LibraryQuery(parsing: generator.query().description)
            #expect(LibraryQuery(QueryRules(query)) == query, "\(query)")
        }
    }

    @Test func `a field's filters are replaced where the first was, narrowing rules that don't all match`() throws {
        let rules = try QueryRules(parsing: "sunset flag:pick rating>=2 flag:reject")
        #expect(rules.filters(on: .flag).map(\.index) == [1, 3])
        let unflagged = LibraryQuery.Filter(.flag, .equal, [.flag(nil)])
        #expect(rules.replacingFilters(on: .flag, with: unflagged).description == "sunset flag:none rating>=2")
        #expect(rules.replacingFilters(on: .flag, with: nil).description == "sunset rating>=2")
        let red = LibraryQuery.Filter(.label, .equal, [.label(.red)])
        #expect(rules.replacingFilters(on: .label, with: red)
            .description == "sunset flag:pick rating>=2 flag:reject label:red")
        let either = try QueryRules(parsing: "a OR b")
        let rated = LibraryQuery.Filter(.rating, .greaterOrEqual, [.number(3)])
        #expect(either.replacingFilters(on: .rating, with: rated).description == "(a OR b) rating>=3")
        #expect(try QueryRules(parsing: "-flag:pick").filters(on: .flag).isEmpty, "a filter leaving photos out")
        #expect(QueryRules().replacingFilters(on: .flag, with: unflagged).description == "flag:none")
    }

    @Test func `a source's photos matching a query come in the sort's order`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        let studio = PhotoSource.folder(Self.folder("2024/Studio"), includingSubfolders: false)
        let list = try await engine.list(studio, matching: LibraryQuery(parsing: "-type:png"), sort: QuerySort(.name))
        #expect(library.numbers(list) == [4, 3] && list.source == studio)
        let year = PhotoSource.folder(Self.folder("2024"), includingSubfolders: true)
        let rated = try await engine.list(year, matching: .all, sort: QuerySort(.rating, ascending: false))
        #expect(library.numbers(rated) == [1, 2, 4, 3, 7])
        #expect(try await engine.list(year, matching: LibraryQuery(parsing: "sunset")).isEmpty)
    }

    @Test func `photos a volume marks offline at once are found, to bring the store up to date`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        #expect(try await engine.photosWithChangedState().isEmpty)
        let volume = library.sandbox.volume
        let marked = try await library.index.write { try $0.setOffline(true, onVolume: volume, uuid: "TEST-VOLUME") }
        #expect(marked == 8)
        let changed = try await engine.photosWithChangedState()
        #expect(changed.count == 8)
        try await engine.update(photos: changed)
        #expect(try await engine.ids("offline:yes").count == 8)
        #expect(try await engine.photosWithChangedState().isEmpty)
        try await library.index.write { try $0.setOffline(false, onVolume: volume, uuid: "TEST-VOLUME") }
        try await engine.update(photos: engine.photosWithChangedState())
        #expect(try await engine.ids("offline:yes").isEmpty)
    }

    @Test func `completions offer keywords, cameras, lenses, folders and labels from the index, best first`(
    ) async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        let birds = await engine.completions("bir", field: nil)
        #expect(birds.first == QueryCompletion(field: .keyword, value: "Animals/Birds"))
        #expect(birds.first?.term == "kw:Animals/Birds")
        let cameras = await engine.completions("x-t", field: .camera)
        #expect(cameras.map(\.term) == ["camera:\"Fujifilm X-T5\""])
        let lenses = await engine.completions("rf", field: .lens)
        #expect(lenses.map(\.value) == ["RF50mm F1.8 STM"])
        let folders = await engine.completions("lisbon", field: .folder)
        #expect(folders.map(\.value) == [IndexSandbox.rootPath + "/2024/Lisbon Trip"])
        let labels = await engine.completions("re", field: .label)
        #expect(labels.first?.term == "label:red")
        let any = await engine.completions("ca", field: nil)
        #expect(any.map(\.value).contains("Canon EOS R5"))
        let nothing = await engine.completions("zzz", field: nil)
        let blank = await engine.completions(" ", field: nil)
        #expect(nothing.isEmpty && blank.isEmpty)
    }
}
