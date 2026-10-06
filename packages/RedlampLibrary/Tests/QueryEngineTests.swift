import Foundation
import Testing
@testable import RedlampLibrary

struct QueryEngineTests {
    /// Each query and the photos it finds, by number.
    static let cases: [(String, Set<Int>)] = [
        ("", Set(1 ... 8)),
        ("rating>=3", [1, 2, 5]),
        ("rating:0", [3, 7, 8]),
        ("stars:4,5", [1, 5]),
        ("rating:1..2", [4, 6]),
        ("rating!=0", [1, 2, 4, 5, 6]),
        ("flag:pick", [1]),
        ("flag:reject", [3]),
        ("-flag:reject", [1, 2, 4, 5, 6, 7, 8]),
        ("flag:none", [2, 4, 5, 6, 7, 8]),
        ("label:red,blue", [1, 2]),
        ("label:none", [3]),
        ("-label:none", [1, 2, 4, 5, 6, 7, 8]),
        ("label:orange", []),
        ("label:approved", [4]),
        ("label:Client,red", [1, 7]),
        ("label!=client", [1, 2, 3, 4, 5, 6, 8]),
        ("marked:yes", [4]),
        ("edited:yes", [1, 2]),
        ("edited:no", [3, 4, 5, 6, 7, 8]),
        ("kw:portugal", [1]),
        ("kw:Lisbon", [1]),
        ("kw:\"Places/Portugal\"", [1]),
        ("kw:animals", [1]),
        ("kw:port", []),
        ("kw:sunset", [5]),
        ("camera:\"X-T5\"", [1, 2, 6]),
        ("camera:canon", [3]),
        ("-camera:x-t5", [3, 4, 5, 7, 8]),
        ("lens:35", [1, 2, 6]),
        ("lens:rf", [3]),
        ("iso<=800", [1, 3, 4, 6]),
        ("iso>=3200", [2, 8]),
        ("iso:100..200", [1, 3]),
        ("f:1.4..2.8", [1, 2, 4]),
        ("f<2", [1, 4]),
        ("focal:24..70", [1, 2, 3]),
        ("focal<10", [4]),
        ("shutter>=1", [3]),
        ("shutter:1/250", [1]),
        ("shutter<1/100", [1, 4, 6]),
        ("date:2024", [1, 2, 3]),
        ("date:2024-06", [1, 2]),
        ("date:2024-06-14", [1, 2]),
        ("date:2019-08..2024-06", [1, 2, 5, 8]),
        ("date<2015", [6]),
        ("-date:2024", [4, 5, 6, 7, 8]),
        ("date:today", [8]),
        ("date:yesterday", [5]),
        ("date:last:2d", [5, 8]),
        ("in:Studio", [3, 4, 7]),
        ("folder:\"2024/\"", [1, 2, 3, 4, 7]),
        ("in:MONTRÉAL", [6]),
        ("name:DSCF", [1, 2]),
        ("name:img_00", [3, 4, 7]),
        ("ext:raw", [1, 2, 3, 8]),
        ("type:heic", [4]),
        ("ext:png", [7]),
        ("ext:nef", [8]),
        ("collection:Portfolio", [1, 3]),
        ("collection:2024", [1, 3]),
        ("collection:\"portfolio/2024\"", [1, 3]),
        ("collection:Clients", [5]),
        ("collection:Orphan", []),
        ("collection:\"AC/DC\"", [8]),
        ("collection:AC", []),
        ("has:gps", [1, 5]),
        ("has:keywords", [1, 5]),
        ("has:caption", [1, 3, 5]),
        ("has:title", [1]),
        ("has:xmp", [2]),
        ("has:creator", [1, 2, 3, 6]),
        ("has:copyright", [1, 3]),
        ("has:location", [1, 2, 3, 5, 6]),
        ("-has:location", [4, 7, 8]),
        ("creator:ana", [1, 2]),
        ("creator:\"joão\"", [2]),
        ("creator:élodie", [6]),
        ("copyright:acme", [3]),
        ("copyright:©", [1]),
        ("city:lisboa", [1, 2]),
        ("city:Porto,Lagoa", [3, 5]),
        ("state:faro", [5]),
        ("province:QUÉBEC", [6]),
        ("country:portugal", [1, 2, 3, 5]),
        ("-country:portugal", [4, 6, 7, 8]),
        ("countrycode:pt", [1, 2, 5]),
        ("sublocation:alfama", [1]),
        ("lisboa", [1, 2]),
        ("marinha", [5]),
        ("tremblay", [6]),
        ("canada", [6]),
        ("megapixels>=40", [3, 5]),
        ("mp:12..13", [4]),
        ("megapixels:1", [7]),
        ("aspect:3:2", [1, 3, 6]),
        ("aspect:4:3", [4]),
        ("aspect>=2", [5, 7]),
        ("is:long-exposure", [3]),
        ("is:panorama", [5, 7]),
        ("is:high-resolution", [3, 5]),
        ("is:low-light", [2, 8]),
        ("is:no-location", [2, 3, 4, 6, 7, 8]),
        ("is:panorama,low-light", [2, 5, 7, 8]),
        ("-is:no-location", [1, 5]),
        ("is!=panorama", [1, 2, 3, 4, 6, 8]),
        ("title:tram", [1]),
        ("caption:sunset", [5]),
        ("lisbon", [1, 2]),
        ("x-t5", [1, 2, 6]),
        ("35mm", [1, 2, 6]),
        ("alfama", [1]),
        ("birds", [1]),
        ("acme", [3]),
        ("sunset", [5]),
        ("rating>=3 flag:pick", [1]),
        ("label:red OR label:green", [1, 5]),
        ("(rating>=4 OR flag:pick) -label:none", [1, 5]),
        ("camera:x-t5 iso<=800", [1, 6]),
        ("-(rating:0 OR has:gps)", [2, 4, 6]),
        ("ab rating>=3", [1, 2, 5]),
    ]

    /// Each sort and the photos' numbers in its ascending order.
    static let orders: [(QuerySort.Key, [Int])] = [
        (.captured, [4, 7, 6, 5, 8, 1, 2, 3]),
        (.name, [6, 8, 1, 2, 4, 3, 7, 5]),
        (.rating, [7, 8, 3, 4, 6, 2, 5, 1]),
        (.edited, [4, 7, 6, 5, 8, 3, 1, 2]),
    ]

    @Test func `every field, operator and free text finds its photos, with the column store and with SQL`(
    ) async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let sql = try await library.engine(loaded: false)
        let columns = try await library.engine(loaded: true)
        #expect(!sql.isLoaded && columns.isLoaded)
        for (text, expected) in Self.cases {
            let fromSQL = try await sql.ids(text)
            let fromColumns = try await columns.ids(text)
            #expect(Set(library.numbers(fromColumns)) == expected, "\(text) with the column store")
            #expect(fromSQL == fromColumns, "\(text): SQL \(library.numbers(fromSQL))")
        }
    }

    @Test func `sorts order photos by capture time, name, rating and edit time, either way`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let sql = try await library.engine(loaded: false)
        let columns = try await library.engine(loaded: true)
        for (key, ascending) in Self.orders {
            for sort in [QuerySort(key), QuerySort(key, ascending: false)] {
                let expected = sort.ascending ? ascending : ascending.reversed()
                #expect(try await library.numbers(columns.ids("", sort: sort)) == expected, "\(sort)")
                #expect(try await library.numbers(sql.ids("", sort: sort)) == expected, "\(sort) with SQL")
            }
        }
        #expect(try await library.numbers(columns.ids("rating>=3", sort: QuerySort(.name))) == [1, 2, 5])
    }

    @Test func `the first page comes as soon as it's found, with the count, then every photo`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let query = try LibraryQuery(parsing: "-flag:reject")
        let columns = try await library.engine(loaded: true).results(query, pageSize: 3)
        #expect(columns.map(\.ids.count) == [3, 7] && columns.map(\.count) == [7, 7])
        #expect(columns.map(\.isComplete) == [false, true])
        #expect(Array(columns[1].ids.prefix(3)) == Array(columns[0].ids))

        let sql = try await library.engine(loaded: false).results(query, pageSize: 3)
        #expect(sql.map(\.ids.count) == [3, 7] && sql.map(\.count) == [nil, 7])
        #expect(sql.map(\.ids) == columns.map(\.ids))

        let small = try await library.engine(loaded: true).results(LibraryQuery(parsing: "flag:pick"))
        #expect(small.count == 1 && small[0].isComplete && small[0].count == 1)
    }

    @Test func `facets count the photos a query finds, a pass each`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        var facets: [Facet: [String?: Int]] = [:]
        for try await counts in try engine.facets(for: LibraryQuery(parsing: "date:2024")) {
            #expect(counts.total == 3, "\(counts.facet)")
            facets[counts.facet] = Dictionary(uniqueKeysWithValues: counts.values.map { ($0.name, $0.count) })
        }
        #expect(Set(facets.keys) == Set(Facet.allCases))
        #expect(facets[.camera] == ["Canon EOS R5": 1, "Fujifilm X-T5": 2])
        #expect(facets[.lens] == ["RF50mm F1.8 STM": 1, "XF35mmF1.4 R": 2])
        #expect(facets[.rating] == ["0": 1, "3": 1, "5": 1])
        #expect(facets[.flag] == ["none": 1, "pick": 1, "reject": 1])
        #expect(facets[.label] == ["none": 1, "red": 1, "blue": 1])
        #expect(facets[.year] == ["2024": 3] && facets[.month] == ["2024-06": 2, "2024-07": 1])
        #expect(facets[.folder] == [
            IndexSandbox.rootPath + "/2024/Lisbon Trip": 2, IndexSandbox.rootPath + "/2024/Studio": 1,
        ])
        #expect(facets[.kind] == ["raw": 3])

        var years: [FacetValue] = []
        for try await counts in engine.facets([.year, .flag], for: .all) where counts.facet == .year {
            years = counts.values
        }
        #expect(years.map(\.name) == ["2014", "2019", "2024", nil] && years.map(\.count) == [1, 2, 3, 2])
        let filter = try #require(years.first?.filter)
        #expect(try await library.numbers(engine.ids(filter.description)) == [6], "a value's filter finds its photos")
    }

    @Test func `a newer search cancels the one before it, and facets in progress`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let gate = QueryGate()
        let source = GatedQuerySource(base: IndexQuerySource(index: library.index), gate: gate)
        let engine = QueryEngine(source: source, timeZone: .gmt, now: { QueryTestLibrary.now })
        try await engine.load()

        let first = try engine.search(LibraryQuery(parsing: "lisbon"))
        let facets = try engine.facets(for: LibraryQuery(parsing: "alfama"))
        try await gate.waitForWaiters(2)
        let newer = try await engine.results(LibraryQuery(parsing: "rating>=3"))
        gate.open()
        await #expect(throws: CancellationError.self) {
            for try await _ in first {}
        }
        await #expect(throws: CancellationError.self) {
            for try await _ in facets {}
        }
        #expect(library.numbers(newer.last?.ids ?? []) == [5, 1, 2])
        #expect(try await library.numbers(engine.ids("lisbon")) == [1, 2], "a search after it runs")
    }

    @Test func `updates bring the column store up to date with the index`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: true)
        let ids = library.ids
        let studio = try #require(library.folders["2024/Studio"])
        let added = try await library.index.write { writer in
            try writer.setOrganising([.rating(5)], forPhotos: [ids[6]])
            try writer.deletePhotos([ids[7]])
            try writer.movePhoto(ids[2], toFolder: studio, name: "AAA_0001.CR3")
            return try writer.upsertPhotos([PhotoRecord(
                folder: studio, name: "New.JPG", captured: QueryTestLibrary.date(2024, 8, 1), rating: 2,
            )])[0]
        }
        try await engine.update(photos: [ids[6], ids[7], ids[2], added])
        #expect(try await library.numbers(engine.ids("rating:5")) == [7, 1])
        #expect(try await engine.ids("name:new") == [added])
        #expect(try await library.numbers(engine.ids("ext:raw")) == [1, 2, 3])
        #expect(try await engine.ids("", sort: QuerySort(.name)).first == ids[2])

        let algarve = try #require(library.folders["2019/Algarve"])
        try await library.index.write { writer in
            try writer.moveFolder(algarve, to: IndexSandbox.rootPath + "/2019/Faro", parent: library.folders["2019"])
        }
        try await engine.updateNames()
        #expect(try await library.numbers(engine.ids("in:faro")) == [5])
        #expect(try await engine.ids("in:algarve").isEmpty)

        let sql = try await library.engine(loaded: false)
        for (text, _) in Self.cases {
            for sort in [QuerySort(.captured), QuerySort(.name, ascending: false), QuerySort(.rating)] {
                #expect(try await engine.ids(text, sort: sort) == sql.ids(text, sort: sort), "\(text), \(sort)")
            }
        }
    }

    @Test func `an update before the store is loaded changes nothing, and loading reads every photo`() async throws {
        let library = try await QueryTestLibrary.make()
        defer { library.remove() }
        let engine = try await library.engine(loaded: false)
        try await engine.update(photos: [library.ids[0]])
        #expect(!engine.isLoaded)
        async let loading: Void = engine.load()
        try await engine.update(photos: [library.ids[0]])
        try await loading
        #expect(engine.store?.count == 8)
    }
}
