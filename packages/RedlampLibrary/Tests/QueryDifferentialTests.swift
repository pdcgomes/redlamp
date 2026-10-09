import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// The column engine and SQL alone must find the same photos in the same order (the design's
/// differential checks), for random queries over a fixture's own values.
struct QueryDifferentialTests {
    /// Queries from the grammar, with values the fixture's photos have or nearly have.
    struct Generator {
        var random: SeededRandom
        let words: [String]
        let names: QueryNames

        mutating func query(depth: Int = 3) -> LibraryQuery {
            guard depth > 0, random.chance(0.6) else { return term() }
            let parts = (0 ..< random.int(in: 2 ... 3)).map { _ in query(depth: depth - 1) }
            switch random.int(below: 3) {
            case 0: return .and(parts)
            case 1: return .or(parts)
            default: return .not(parts[0])
            }
        }

        private mutating func term() -> LibraryQuery {
            if random.chance(0.15) {
                return .text(random.pick(words))
            }
            let field = random.pick(LibraryQuery.Field.allCases)
            var comparison = random.chance(0.2) ? LibraryQuery.Comparison.notEqual : .equal
            if field.isOrdered, random.chance(0.4) {
                comparison = random.pick([.less, .lessOrEqual, .greater, .greaterOrEqual])
            }
            let count = comparison.isOrdering || random.chance(0.75) ? 1 : 2
            let values = (0 ..< count).map { _ in value(for: field, ranges: !comparison.isOrdering) }
            return .filter(LibraryQuery.Filter(field, comparison, values))
        }

        private mutating func value(for field: LibraryQuery.Field, ranges: Bool) -> LibraryQuery.Value {
            switch field {
            case .rating, .iso, .aperture, .focal, .shutter, .megapixels, .aspect:
                number(Self.numbers[field] ?? [], ranges: ranges)
            case .date: date(ranges: ranges)
            case .flag: .flag(random.pick([.pick, .reject, nil]))
            case .label:
                random.chance(0.3) ? .text(random.pick(Self.customLabels))
                    : .label(random.pick([nil] + ColorLabel.allCases))
            case .marked, .edited, .missing, .offline, .unreadable: .bool(random.chance(0.5))
            case .keyword: .text(random.pick(Array(names.keywords.values) + ["Places", "nothing"]))
            case .camera: .text(part(of: random.pick(Array(names.cameras.values))))
            case .lens: .text(part(of: random.pick(Array(names.lenses.values))))
            case .folder: .text(part(of: random.pick(Array(names.folders.values))))
            case .collection: .text(random.pick(Self.collections))
            case .has: .detail(random.pick(LibraryQuery.Detail.allCases))
            case .ext:
                random.pick([.kind(.raw), .kind(.jpeg), .kind(.heic), .kind(.png), .text("jpg"), .text("heic")])
            case .name, .title, .caption: .text(random.pick(words))
            case .creator: .text(part(of: random.pick(Self.creators)))
            case .copyright: .text(random.pick(["©", "2019", "Silva", "Agency"]))
            case .sublocation, .city, .state, .country, .countryCode:
                .text(part(of: random.pick(Self.places.flatMap(\.self).filter { !$0.isEmpty } + ["Nowhere"])))
            case .orientation: .orientation(random.pick([nil] + PhotoOrientation.allCases))
            case .trait: .trait(random.pick(LibraryQuery.Trait.allCases.filter { $0.query != nil }))
            }
        }

        /// The values the numeric fields are compared with.
        static let numbers: [LibraryQuery.Field: [Double]] = [
            .rating: [0, 1, 2, 3, 4, 5],
            .iso: [64, 100, 200, 250, 800, 1600, 3200, 6400, 12800],
            .aperture: [1.2, 1.4, 1.6, 1.7, 1.78, 2, 2.8, 4, 5.6, 8, 16],
            .focal: [5.1, 6.765, 18.3, 23, 24, 35, 50, 70, 85, 200, 400],
            .shutter: [1.0 / 8000, 1.0 / 1000, 1.0 / 250, 1.0 / 30, 0.25, 1, 2, 30],
            .megapixels: [0.1, 1, 12.2, 24, 40, 44.8, 48, 61],
            .aspect: [1, 4.0 / 3, 1.5, 16.0 / 9, 2, 3],
        ]
        static let creators = ["Ana Silva", "Ana Silva; João Costa", "Élodie Tremblay", "Nobody"]
        static let customLabels = ["Approved", "second", "Client", "To Do"]
        static let collections = ["Trips", "Lisbon", "Trips/Lisbon", "Portfolio", "AC/DC", "Selects", "nothing"]
        /// Sublocations, cities, states, countries and their codes.
        static let places = [
            ["Alfama", "Lisboa", "Lisboa", "Portugal", "PT"], ["", "Porto", "", "Portugal", "PT"],
            ["Plateau", "Montréal", "Québec", "Canada", "CA"], ["", "", "", "Japan", ""],
        ]

        /// Gives some of the photos in `index` creators, copyrights, places, custom labels and
        /// collections, as the sidecars' organising fields would, and some panoramas' and larger
        /// sensors' sizes.
        static func organise(_ index: LibraryIndex) async throws {
            try await index.write { writer in
                let ids = try writer.database.cached("SELECT id FROM photos ORDER BY id").map { $0.int64(at: 0) }
                let update = try writer.database.prepare("""
                UPDATE photos SET creator = ?, copyright = ?, sublocation = ?, city = ?, province = ?, country = ?,
                  country_code = ?, custom_label = CASE WHEN label = 0 THEN ? END WHERE id = ?
                """)
                let resize = try writer.database.prepare("UPDATE photos SET width = ?, height = ? WHERE id = ?")
                let sizes = [(12000, 4000), (8192, 5464), (4000, 6000), (3024, 4032)]
                for (number, id) in ids.enumerated() where number % 3 == 0 {
                    let (width, height) = sizes[number / 3 % sizes.count]
                    try resize.bind(width, at: 1)
                    try resize.bind(height, at: 2)
                    try resize.bind(id, at: 3)
                    try resize.run()
                }
                for (number, id) in ids.enumerated() {
                    var values: [String?] = []
                    values.append(number % 4 == 3 ? nil : Self.creators[number % Self.creators.count])
                    values.append(number % 5 == 0 ? "© \(2010 + number % 12) Ana Silva" : nil)
                    let place = number % 3 == 0 ? [] : Self.places[number % Self.places.count]
                    for part in 0 ..< 5 {
                        values.append(part < place.count && !place[part].isEmpty ? place[part] : nil)
                    }
                    values.append(number % 7 < 2 ? Self.customLabels[number % Self.customLabels.count] : nil)
                    for (offset, value) in values.enumerated() {
                        try update.bind(value, at: Int32(offset + 1))
                    }
                    try update.bind(id, at: 9)
                    try update.run()
                    let collections = [number % 6 == 0 ? "Trips/Lisbon" : nil, number % 10 == 1 ? "AC%2FDC" : nil]
                    try writer.setCollections(collections.compactMap(\.self), forPhoto: id)
                }
            }
        }

        private mutating func number(_ values: [Double], ranges: Bool) -> LibraryQuery.Value {
            guard ranges, random.chance(0.3) else { return .number(random.pick(values)) }
            let ends = [random.pick(values), random.pick(values)].sorted()
            let open = random.int(below: 5)
            return .numberRange(open == 0 ? nil : ends[0], open == 1 ? nil : ends[1])
        }

        private mutating func date(ranges: Bool) -> LibraryQuery.Value {
            func one(_ random: inout SeededRandom, relative: Bool) -> QueryDate {
                let year = random.int(in: 2005 ... 2026)
                switch random.int(below: relative ? 6 : 4) {
                case 0: return .year(year)
                case 1: return .month(year, random.int(in: 1 ... 12))
                case 2: return .day(year, random.int(in: 1 ... 12), random.int(in: 1 ... 28))
                case 3: return .time(year, random.int(in: 1 ... 12), random.int(in: 1 ... 28), time(&random))
                case 4: return random.pick([.today, .yesterday])
                default: return .last(random.int(in: 1 ... 400), random.pick(QueryDate.Unit.allCases))
                }
            }
            func time(_ random: inout SeededRandom) -> QueryTime {
                let (hour, minute) = (random.int(below: 24), random.int(below: 60))
                switch random.int(below: 3) {
                case 0: return .hour(hour)
                case 1: return .minute(hour, minute)
                default: return .second(hour, minute, random.int(below: 60))
                }
            }
            guard ranges, random.chance(0.3) else { return .date(one(&random, relative: true)) }
            let first = random.int(in: 2005 ... 2025)
            if random.chance(0.3) {
                let start = QueryDate.time(first, 6, 14, .minute(random.int(below: 12), random.int(below: 60)))
                return .dateRange(start, .time(first, 6, 14, .second(12 + random.int(below: 12), 30, 15)))
            }
            return .dateRange(.year(first), random.chance(0.2) ? nil : .month(random.int(in: first ... 2026), 6))
        }

        /// Three to eight characters of `text`.
        private mutating func part(of text: String) -> String {
            let characters = Array(text)
            guard characters.count > 3 else { return text }
            let length = random.int(in: 3 ... min(8, characters.count))
            let start = random.int(below: characters.count - length + 1)
            return String(characters[start ..< start + length])
        }
    }

    @Test func `random queries find the same photos in the same order with the column store as with SQL`() async throws {
        let fixture = try TemporaryFolder()
        let summary = try LibraryFixture(spec: .init(photos: 800, seed: 21)).write(to: fixture.url)
        let folder = try TemporaryFolder()
        let index = try await LibraryIndex.open(at: folder.url.appending(path: "Index.sqlite"))
        defer { index.closeAndWait() }
        for await _ in LibraryIndexer(index: index).index([fixture.url]) {}
        let today = QueryCalendar.days(2025, 12, 31)
        let engine = QueryEngine(
            index: index,
            timeZone: .gmt,
            now: { Date(timeIntervalSince1970: Double(today) * 86400) },
        )
        try await engine.load()
        #expect(engine.store?.count == summary.manifest.totals.photos)
        for query in summary.manifest.queries {
            let results = try await engine.results(LibraryQuery(parsing: query.query))
            #expect(results.last?.count == query.count, "\(query.query)")
        }

        try await Generator.organise(index)
        try await engine.load()
        let names = try await index.read { try $0.queryNames() }
        let words = FixtureCatalog.captions.flatMap { $0.split(separator: " ").map(String.init) }
            .filter { $0.count >= 3 }
            + FixtureCatalog.keywords + [
                "DSCF",
                "IMG_",
                "DSC0",
                "Card Dump",
                "Level 1",
                "Clients",
                "Café-0",
                "東京-00",
                "ab",
            ]
        var generator = Generator(random: SeededRandom(seed: 22), words: words, names: names)
        var nonEmpty = 0
        for round in 0 ..< 600 {
            let query = try LibraryQuery(parsing: generator.query().description)
            #expect(try LibraryQuery(parsing: query.description) == query)
            let sort = QuerySort(QuerySort.Key.allCases[round % 4], ascending: round % 3 != 0)
            let columns = try await engine.ids(query.description, sort: sort)
            let sql = try await index.read { reader in
                var ids: [Int64] = []
                try reader
                    .run(QuerySQL(query.searchable, sort: sort, today: today), cancellation: QueryCancellation()) {
                        ids.append($0)
                    }
                return ids
            }
            #expect(
                columns == sql,
                "\(query) by \(sort): \(columns.count) with the column store, \(sql.count) with SQL",
            )
            nonEmpty += columns.isEmpty ? 0 : 1
        }
        #expect(nonEmpty > 100, "most random queries find photos")
    }
}
