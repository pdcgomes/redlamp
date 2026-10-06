import Foundation
import RedlampDocument
import Synchronization
import Testing
@testable import RedlampLibrary

/// The column engine at a million photos, in memory: a fixture's photos as the index would hold
/// them, and the manifest's queries typed a character at a time, then their facets. The index's
/// text lookups are answered from memory, worked out before the timed pass, so the times are the
/// engine's own. Skipped unless `REDLAMP_QUERY_BENCH=1`, which xcodebuild hands to the tests from
/// `TEST_RUNNER_REDLAMP_QUERY_BENCH=1`.
struct QueryMillionTests {
    static let photoCount = 1_000_000

    /// Three raws, so a fifth of the photos are raws as in a fixture made with sources.
    static let raws = [
        RawSource(
            url: URL(fileURLWithPath: "/raws/AFXT2720.RAF"), size: 1, make: "FUJIFILM", model: "X-T2",
            lens: "XF16-55mmF2.8 R LM WR", iso: 400, aperture: 2.8, exposureTime: 1.0 / 250, focalLength: 23,
            location: nil, dateOffsets: [0],
        ),
        RawSource(
            url: URL(fileURLWithPath: "/raws/IMG_1361.CR3"), size: 1, make: "Canon", model: "Canon EOS R6",
            lens: "RF24-105mm F4 L IS USM", iso: 100, aperture: 4, exposureTime: 1.0 / 125, focalLength: 50,
            location: nil, dateOffsets: [0],
        ),
        RawSource(
            url: URL(fileURLWithPath: "/raws/DSC_0750.NEF"), size: 1, make: "NIKON CORPORATION", model: "NIKON D750",
            lens: "AF-S NIKKOR 24-70mm f/2.8E ED VR", iso: 3200, aperture: 2.8, exposureTime: 1.0 / 60,
            focalLength: 35, location: FixturePhoto.Location(latitude: 38.7, longitude: -9.1), dateOffsets: [0],
        ),
    ]

    private static func report(_ line: String) {
        print("QUERY-BENCH \(line)")
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        duration / .milliseconds(1)
    }

    /// The `fraction` percentile, in milliseconds.
    private static func percentile(_ durations: [Duration], _ fraction: Double) -> Double {
        let sorted = durations.sorted()
        return milliseconds(sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_QUERY_BENCH"] == "1"))
    func `a million photos: the first page and the count as each character is typed, and facets`() async throws {
        let clock = ContinuousClock()
        let fixture = LibraryFixture(spec: .init(photos: Self.photoCount, seed: 1), rawSources: Self.raws)
        var library = SyntheticLibrary(fixture)
        var builder = ColumnStore.Builder(capacity: Self.photoCount)
        for index in 0 ..< Self.photoCount {
            builder.add(library.add(fixture.photo(at: index)))
        }
        let sorting = clock.now
        let store = builder.finish()
        let sorted = clock.now - sorting
        let bytes = Double(store.memoryFootprint) / Double(store.count)
        Self.report(String(
            format: "store: %ld photos, %.1f bytes a photo (%.0f MB), orders sorted in %.0f ms",
            store.count, bytes, Double(store.memoryFootprint) / 1_000_000, Self.milliseconds(sorted),
        ))

        let manifest = fixture.manifest()
        let source = SyntheticSource(store: store, names: library.names, text: library.text)
        let warm = QueryEngine(source: source, timeZone: .gmt)
        try await warm.load()
        for query in FixtureQuery.corpus {
            for text in Self.typed(query.text) {
                _ = try await warm.results(LibraryQuery(parsing: text, asYouType: true))
            }
        }

        for run in 1 ... 2 {
            let engine = QueryEngine(source: source, timeZone: .gmt)
            try await engine.load()
            var firsts: [Duration] = []
            var completes: [Duration] = []
            var slowest: [(Duration, String)] = []
            var miscounted: [String] = []
            for query in FixtureQuery.corpus {
                for text in Self.typed(query.text) {
                    let started = clock.now
                    let parsed = try LibraryQuery(parsing: text, asYouType: true)
                    var first: Duration?
                    var last: QueryResult?
                    for try await result in engine.search(parsed) {
                        first = first ?? clock.now - started
                        last = result
                    }
                    let firstPage = try #require(first)
                    firsts.append(firstPage)
                    completes.append(clock.now - started)
                    slowest.append((firstPage, text))
                    if text == query.text, last?.count != manifest.count(of: query.text) {
                        miscounted.append("\(text): \(last?.count ?? -1), not \(manifest.count(of: query.text) ?? -1)")
                    }
                }
            }
            #expect(miscounted.isEmpty, "\(miscounted)")
            let worst = slowest.sorted { $0.0 > $1.0 }.prefix(5)
                .map { String(format: "%@ %.1f ms", $0.1, Self.milliseconds($0.0)) }.joined(separator: ", ")
            Self.report(String(
                format: "run %ld, %ld keystrokes: first page of 100 and the count p50 %.2f ms, p95 %.2f ms; "
                    + "every photo in order p50 %.2f ms, p95 %.2f ms; slowest: %@",
                run, firsts.count, Self.percentile(firsts, 0.5), Self.percentile(firsts, 0.95),
                Self.percentile(completes, 0.5), Self.percentile(completes, 0.95), worst,
            ))
            #expect(Self.percentile(firsts, 0.95) < 16)

            var fieldFirsts: [Duration] = []
            var slowestFields: [(Duration, String)] = []
            for (number, query) in SyntheticLibrary.fieldQueries.enumerated() {
                for text in Self.typed(query.text) {
                    let started = clock.now
                    var first: Duration?
                    var last: QueryResult?
                    for try await result in try engine.search(LibraryQuery(parsing: text, asYouType: true)) {
                        first = first ?? clock.now - started
                        last = result
                    }
                    fieldFirsts.append(first ?? clock.now - started)
                    slowestFields.append((first ?? clock.now - started, text))
                    if text == query.text {
                        #expect(last?.count == library.fieldCounts[number], "\(text)")
                    }
                }
            }
            let worstFields = slowestFields.sorted { $0.0 > $1.0 }.prefix(3)
                .map { String(format: "%@ %.1f ms", $0.1, Self.milliseconds($0.0)) }.joined(separator: ", ")
            Self.report(String(
                format: "run %ld, %ld keystrokes of creators, locations and custom labels: first page and the "
                    + "count p50 %.2f ms, p95 %.2f ms; slowest: %@",
                run, fieldFirsts.count, Self.percentile(fieldFirsts, 0.5), Self.percentile(fieldFirsts, 0.95),
                worstFields,
            ))
            #expect(Self.percentile(fieldFirsts, 0.95) < 16)

            var facets: [Duration] = []
            var slowestFacets: [(Duration, String)] = []
            for query in FixtureQuery.corpus {
                let parsed = try LibraryQuery(parsing: query.text)
                for facet in Facet.allCases {
                    let started = clock.now
                    for try await counts in engine.facets([facet], for: parsed) {
                        #expect(counts.total == manifest.count(of: query.text), "\(query.text) by \(facet)")
                    }
                    facets.append(clock.now - started)
                    slowestFacets.append((clock.now - started, "\(query.text) by \(facet)"))
                }
            }
            let worstFacets = slowestFacets.sorted { $0.0 > $1.0 }.prefix(5)
                .map { String(format: "%@ %.1f ms", $0.1, Self.milliseconds($0.0)) }.joined(separator: ", ")
            Self.report(String(
                format: "run %ld, %ld facet passes: p50 %.2f ms, p95 %.2f ms; slowest: %@", run, facets.count,
                Self.percentile(facets, 0.5), Self.percentile(facets, 0.95), worstFacets,
            ))
            #expect(Self.percentile(facets, 0.95) < 100)
        }
    }

    /// `text` as it's typed: a character more each time.
    static func typed(_ text: String) -> [String] {
        let characters = Array(text)
        return (1 ... characters.count).map { String(characters[..<$0]) }
    }
}

/// A fixture's photos as the index holds them: their rows, the small tables, and their text; a
/// creator on a fifth of them, a place on those with GPS, and a custom label on one in fifty.
struct SyntheticLibrary {
    var names = QueryNames()
    var text = SyntheticText()
    /// How many photos each of `fieldQueries` finds.
    private(set) var fieldCounts = [Int](repeating: 0, count: SyntheticLibrary.fieldQueries.count)
    private var folders: [String: Int64] = [:]
    private var cameras: [String: Int64] = [:]
    private var lenses: [String: Int64] = [:]

    static let creators = (0 ..< 60).map { number in
        ["Ana Silva", "João Costa", "Élodie Tremblay", "Studio Acme", "Kenji Sato", "Maria Rossi"][number % 6]
            + (number < 6 ? "" : " \(number / 6)")
    }

    /// 400 places: a sublocation in one of 40 cities in 10 countries.
    static let places = (0 ..< 400).map { number in
        let countries = [
            "Portugal",
            "Spain",
            "France",
            "Canada",
            "Japan",
            "Italy",
            "Brazil",
            "Kenya",
            "Norway",
            "Chile",
        ]
        let codes = ["PT", "ES", "FR", "CA", "JP", "IT", "BR", "KE", "NO", "CL"]
        let cities = ["Lisbon", "Porto", "Madrid", "Paris", "Montréal", "Kyoto", "Rome", "Rio", "Nairobi", "Oslo"]
        return PhotoLocation(
            country: countries[number % 10], state: "Region \(number % 20)",
            city: cities[number % 10] + (number % 40 < 10 ? "" : " \(number % 40 / 10)"),
            sublocation: "Place \(number)", countryCode: codes[number % 10],
        )
    }

    static let customLabels = ["Approved", "Second", "Review"]

    /// Queries on the fields the fixture's manifest doesn't count, and the photos each finds.
    static let fieldQueries: [(text: String, matches: @Sendable (ColumnStore.Row) -> Bool)] = [
        ("creator:\"ana silva\"", { includes($0.creator, "ana silva") }),
        ("creator:acme", { includes($0.creator, "acme") }),
        ("city:lisbon", { includes($0.location?.city, "lisbon") }),
        ("country:portugal", { includes($0.location?.country, "portugal") }),
        ("countrycode:jp", { includes($0.location?.countryCode, "jp") }),
        ("sublocation:\"place 1\"", { includes($0.location?.sublocation, "place 1") }),
        ("has:creator", { $0.creator != nil }),
        ("-has:location", { $0.location == nil }),
        ("label:approved", { $0.customLabel == "Approved" }),
        ("rating>=3 city:porto", { $0.hot.rating >= 3 && includes($0.location?.city, "porto") }),
        ("montréal", { includes($0.location?.city, "montréal") }),
        ("tremblay", { includes($0.creator, "tremblay") }),
        ("is:long-exposure", { ColumnEncoding.shutter($0.shutter) >= 1_000_000 }),
        ("is:panorama", { ColumnEncoding.aspect(width: $0.width, height: $0.height) >= 200 }),
        ("is:high-resolution", { ColumnEncoding.megapixels(width: $0.width, height: $0.height) >= 400 }),
        ("is:low-light", { ColumnEncoding.iso($0.hot.iso) >= 3200 }),
        ("is:no-location", { !$0.details.contains(.location) }),
        ("is:panorama,low-light rating>=3", { row in
            (ColumnEncoding.aspect(width: row.width, height: row.height) >= 200
                || ColumnEncoding.iso(row.hot.iso) >= 3200) && row.hot.rating >= 3
        }),
    ]

    private static func includes(_ text: String?, _ part: String) -> Bool {
        text?.range(of: part, options: .caseInsensitive) != nil
    }

    init(_ fixture: LibraryFixture) {
        for (index, folder) in fixture.folders.enumerated() {
            folders[folder.path] = Int64(index + 1)
            names.folders[Int64(index + 1)] = "/Volumes/Million/" + folder.path
        }
        for (index, keyword) in FixtureCatalog.keywords.enumerated() {
            names.keywords[Int64(index + 1)] = keyword
        }
    }

    mutating func add(_ photo: FixturePhoto) -> ColumnStore.Row {
        let camera = id(of: photo.camera, in: &cameras, &names.cameras) {
            CaptureMetadata(make: photo.make, model: photo.model).cameraName ?? photo.camera
        }
        let lens = photo.lens.map { lens in id(of: lens, in: &lenses, &names.lenses) { lens } }
        let kind: PhotoRecord.Kind = switch photo.kind {
        case .raw: .raw
        case .jpeg: .jpeg
        case .heic: .heic
        }
        var details: ColumnStore.Details = []
        if photo.location != nil {
            details.insert(.location)
        }
        if !photo.keywords.isEmpty {
            details.insert(.keywords)
        }
        if photo.caption != nil {
            details.insert(.caption)
        }
        if photo.xmp != nil {
            details.insert(.xmp)
        }
        text.add(photo)
        var row = ColumnStore.Row(
            HotColumns(
                id: Int64(photo.index + 1), folder: folders[photo.folder] ?? 0,
                captured: photo.captured.date.timeIntervalSince1970, camera: camera, lens: lens, rating: photo.rating,
                flag: PhotoRecord.code(for: photo.flag), label: PhotoRecord.code(for: photo.label), marked: false,
                edited: photo.isEdited, iso: photo.iso.map(Double.init), aperture: photo.aperture,
                focal: photo.focalLength, kind: kind.rawValue, name: photo.name,
            ),
            shutter: photo.exposureTime, details: details,
            sidecarModified: photo.isEdited ? 1_700_000_000 + Double(photo.index) : nil,
        )
        if photo.index % 5 == 0 {
            row.creator = Self.creators[photo.index / 5 % Self.creators.count]
        }
        if photo.location != nil {
            row.location = Self.places[photo.index % Self.places.count]
        }
        if photo.label == nil, photo.index % 50 == 7 {
            row.customLabel = Self.customLabels[photo.index / 50 % Self.customLabels.count]
        }
        (row.width, row.height) = photo.index % 97 == 0 ? (12000, 4000) : photo.index % 13 == 0 ? (5504, 8256) : (
            6000,
            4000,
        )
        for (number, query) in Self.fieldQueries.enumerated() where query.matches(row) {
            fieldCounts[number] += 1
        }
        return row
    }

    private func id(
        of key: String, in ids: inout [String: Int64], _ names: inout [Int64: String], name: () -> String,
    ) -> Int64 {
        if let id = ids[key] {
            return id
        }
        let id = Int64(ids.count + 1)
        ids[key] = id
        names[id] = name()
        return id
    }
}

/// Photos' text as the trigram index matches it: names (digits aside), keywords and captions.
struct SyntheticText: Sendable {
    /// Each name lowercased with its digits as `#`; photos' names by index into it.
    private var patterns: [String] = []
    private var patternIndex: [String: UInt16] = [:]
    private var pattern: [UInt16] = []
    /// A bit per `FixtureCatalog.keywords`.
    private(set) var keywords: [UInt32] = []
    /// Into `FixtureCatalog.captions`; `UInt8.max` for none.
    private var caption: [UInt8] = []

    mutating func add(_ photo: FixturePhoto) {
        let key = String(photo.name.lowercased().map { $0.isNumber ? "#" : $0 })
        if patternIndex[key] == nil {
            patternIndex[key] = UInt16(patterns.count)
            patterns.append(key)
        }
        pattern.append(patternIndex[key] ?? 0)
        keywords.append(photo.keywords.reduce(0) { mask, keyword in
            mask | (FixtureCatalog.keywords.firstIndex(of: keyword).map { 1 << UInt32($0) } ?? 0)
        })
        caption.append(photo.caption.flatMap { FixtureCatalog.captions.firstIndex(of: $0) }.map(UInt8.init) ?? .max)
    }

    /// The photos an FTS5 query of `QueryText.match` finds.
    func ids(matching match: String) -> [Int64] {
        var column: Substring?
        var phrase = Substring(match)
        if let separator = match.range(of: " : ") {
            column = match[..<separator.lowerBound]
            phrase = match[separator.upperBound...]
        }
        let text = phrase.dropFirst().dropLast().replacingOccurrences(of: "\"\"", with: "\"").lowercased()
        let names = patterns
            .map { (column == nil || column == "name") && !text.contains { $0.isNumber } && $0.contains(text) }
        let captions = FixtureCatalog.captions
            .map { (column == nil || column == "caption") && $0.lowercased().contains(text) }
        let mask = column == nil || column == "keywords" ? FixtureCatalog.keywords.enumerated().reduce(UInt32(0)) {
            $1.element.contains(text) ? $0 | 1 << UInt32($1.offset) : $0
        } : 0
        var ids: [Int64] = []
        for index in pattern.indices
            where names[Int(pattern[index])] || keywords[index] & mask != 0
            || (caption[index] != .max && captions[Int(caption[index])]) {
            ids.append(Int64(index + 1))
        }
        return ids
    }
}

/// The engine's source for a synthetic library held in memory, its lookups kept once worked out.
final class SyntheticSource: QuerySource {
    struct Unsupported: Error {}

    let store: ColumnStore
    let names: QueryNames
    let text: SyntheticText
    private let lookedUp = Mutex<[String: [Int64]]>([:])

    init(store: ColumnStore, names: QueryNames, text: SyntheticText) {
        self.store = store
        self.names = names
        self.text = text
    }

    func columnStore() async throws -> ColumnStore {
        store
    }

    func names() async throws -> QueryNames {
        names
    }

    func photoIDs(matching match: String) async throws -> [Int64] {
        lookUp(match) { text.ids(matching: match) }
    }

    func photoIDs(withKeywords keywords: [Int64]) async throws -> [Int64] {
        let mask = keywords.reduce(UInt32(0)) { $0 | 1 << UInt32($1 - 1) }
        return lookUp("keywords \(keywords)") {
            text.keywords.indices.compactMap { text.keywords[$0] & mask != 0 ? Int64($0 + 1) : nil }
        }
    }

    func photoIDs(inCollections _: [Int64]) async throws -> [Int64] {
        []
    }

    func applying(_: [Int64], to store: ColumnStore) async throws -> ColumnStore {
        store
    }

    func run(
        _: QuerySQL, pageSize _: Int, cancellation _: QueryCancellation,
        firstPage _: @escaping @Sendable (ContiguousArray<Int64>) -> Void,
    ) async throws -> ContiguousArray<Int64> {
        throw Unsupported()
    }

    private func lookUp(_ key: String, _ work: () -> [Int64]) -> [Int64] {
        if let ids = lookedUp.withLock({ $0[key] }) {
            return ids
        }
        let ids = work()
        lookedUp.withLock { $0[key] = ids }
        return ids
    }
}
