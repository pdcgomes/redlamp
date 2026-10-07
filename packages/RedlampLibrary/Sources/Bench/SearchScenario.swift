import Foundation

public extension BenchScenarios {
    /// Adds the query engine's scenarios (LIB-06) after the others: search as you type, and facets.
    static func registerQueries() {
        register(SearchScenario())
        register(FacetScenario())
    }
}

/// Types every query of the manifest a character at a time into the query engine, over an index of
/// the fixture, as the filter bar does: how soon the first page of 100 and the count come (the
/// design's budget: p95 under 16 ms), how soon every photo comes in order, and that each query, typed
/// in full, finds as many photos as the manifest says. It searches the index it's given and never
/// indexes the fixture itself, which takes minutes at a million photos; the search reads only the
/// Mac's own disk, so the fixture's volume profile doesn't matter.
public struct SearchScenario: BenchScenario {
    public let name = "search"
    static let budget = 16.0
    let indexFolder: URL?

    public init() {
        indexFolder = nil
    }

    /// Searches the index in `indexFolder` rather than the one kept in the temporary folder.
    public init(indexFolder: URL?) {
        self.indexFolder = indexFolder
    }

    public func run(_ context: BenchContext) async throws -> [BenchResult] {
        let setup = try await QueryScenario.engine(for: context, in: indexFolder)
        let engine = setup.engine
        let clock = ContinuousClock()
        var firsts: [Duration] = []
        var completes: [Duration] = []
        var counts: [Int] = []
        for query in FixtureQuery.corpus {
            let characters = Array(query.text)
            for length in 1 ... characters.count {
                let started = clock.now
                let parsed = try LibraryQuery(parsing: String(characters[..<length]), asYouType: true)
                var first: Duration?
                var last: QueryResult?
                for try await result in engine.search(parsed) {
                    first = first ?? clock.now - started
                    last = result
                }
                firsts.append(first ?? clock.now - started)
                completes.append(clock.now - started)
                if length == characters.count {
                    counts.append(last?.count ?? 0)
                }
            }
        }
        await setup.index.close()

        let photos = Double(engine.store?.count ?? 0)
        var results = [
            BenchResult(
                scenario: name, id: "library-search-load", name: "Column store built",
                value: setup.loaded.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-search-memory", name: "Column store, a photo",
                value: Double(engine.store?.memoryFootprint ?? 0) / max(photos, 1), unit: "bytes",
            ),
            BenchResult(
                scenario: name, id: "library-search-first-p50",
                name: "First page and count, p50 of \(firsts.count) keystrokes",
                value: QueryScenario.percentile(firsts, 0.5), unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-search-first", name: "First page and count, p95",
                value: QueryScenario.percentile(firsts, 0.95), unit: "ms", budget: .below(Self.budget, "ms"),
            ),
            BenchResult(
                scenario: name, id: "library-search-all", name: "Every photo in order, p95",
                value: QueryScenario.percentile(completes, 0.95), unit: "ms",
            ),
        ]
        for (number, (query, count)) in zip(FixtureQuery.corpus, counts).enumerated() {
            let expected = Double(context.manifest.count(of: query.text) ?? -1)
            results.append(BenchResult(
                scenario: name, id: "library-search-count-\(number + 1)", name: "Photos for \(query.text)",
                value: Double(count), unit: "photos", budget: .exactly(expected, "photos"),
            ))
        }
        return results
    }
}

/// What the query scenarios share: an index of the fixture, and a query engine over it.
enum QueryScenario {
    /// `TMPDIR`, which `FileManager`'s temporary directory doesn't follow, or that directory.
    static var temporaryDirectory: URL {
        guard let path = ProcessInfo.processInfo.environment["TMPDIR"], !path.isEmpty else {
            return FileManager.default.temporaryDirectory
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Where the index of the fixture is kept between runs when none is given: in the temporary
    /// folder, under the fixture's name, its size and seed, and its path.
    static func indexFolder(for context: BenchContext) -> URL {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in context.fixture.standardizedFileURL.path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        let spec = context.manifest.spec
        let name = "\(context.fixture.lastPathComponent)-\(spec.photos)-\(spec.seed)-\(String(hash, radix: 16))"
        return temporaryDirectory.appending(path: "redlamp-bench-query/\(name)", directoryHint: .isDirectory)
    }

    /// The fixture's index in `folder`, or in `indexFolder(for:)`, with a query engine over it, its
    /// column store loaded, and how long that took. Throws `MissingIndex` when there's no index
    /// there, or one that doesn't hold the manifest's photos.
    static func engine(for context: BenchContext, in folder: URL?) async throws
        -> (index: LibraryIndex, engine: QueryEngine, loaded: Duration) {
        let url = (folder ?? indexFolder(for: context)).appending(path: "Index.sqlite")
        let expected = context.manifest.totals.photos
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MissingIndex(index: url, fixture: context.fixture, photos: nil, expected: expected)
        }
        let index = try await LibraryIndex.open(at: url)
        let photos = try await index.read { try $0.photoCount() }
        guard photos == expected else {
            await index.close()
            throw MissingIndex(index: url, fixture: context.fixture, photos: photos, expected: expected)
        }
        let engine = QueryEngine(index: index)
        let clock = ContinuousClock()
        let started = clock.now
        try await engine.load()
        return (index, engine, clock.now - started)
    }

    /// The `fraction` percentile of `durations`, in milliseconds.
    static func percentile(_ durations: [Duration], _ fraction: Double) -> Double {
        let sorted = durations.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))].seconds * 1000
    }

    /// No index of the fixture where a query scenario looked: they search an index, and never index
    /// the fixture themselves.
    struct MissingIndex: Error, CustomStringConvertible {
        let index: URL
        let fixture: URL
        /// The photos the index there holds; nil when there's none.
        let photos: Int?
        let expected: Int

        var description: String {
            let found = photos.map { "the index at \(index.path) holds \($0) photos, not the fixture's \(expected)" }
                ?? "no index of the fixture at \(index.path)"
            return "\(found); the query scenarios never index the fixture themselves: make one with "
                + "`redlamp library index \(fixture.path) --index \(index.path)`, or pass the folder of one with --index"
        }
    }
}
