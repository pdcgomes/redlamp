import Foundation

/// Counts the photos each query of the manifest finds by every facet (cameras, lenses, ratings,
/// flags, labels, years, months, folders and kinds), a pass each, after the query's search, as the
/// filter bar's facets follow the grid: each pass's time (the design's budget: p95 under 100 ms), and
/// that every facet counts each of the query's photos once. Like search, it uses the index it's given.
public struct FacetScenario: BenchScenario {
    public let name = "facets"
    static let budget = 100.0
    let indexFolder: URL?

    public init() {
        indexFolder = nil
    }

    /// Counts over the index in `indexFolder` rather than the one kept in the temporary folder.
    public init(indexFolder: URL?) {
        self.indexFolder = indexFolder
    }

    public func run(_ context: BenchContext) async throws -> [BenchResult] {
        let setup = try await QueryScenario.engine(searching: context, in: indexFolder)
        let engine = setup.engine
        let clock = ContinuousClock()
        var passes: [Duration] = []
        var miscounted = 0
        for query in FixtureQuery.corpus {
            let parsed = try LibraryQuery(parsing: query.text)
            var count: Int?
            for try await result in engine.search(parsed) {
                count = result.count
            }
            for facet in Facet.allCases {
                let started = clock.now
                for try await counts in engine.facets([facet], for: parsed) where counts.total != count {
                    miscounted += 1
                }
                passes.append(clock.now - started)
            }
        }
        await setup.index.close()
        return [
            BenchResult(
                scenario: name, id: "library-facets-p50", name: "A facet's pass, p50 of \(passes.count)",
                value: QueryScenario.percentile(passes, 0.5), unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-facets", name: "A facet's pass, p95",
                value: QueryScenario.percentile(passes, 0.95), unit: "ms", budget: .below(Self.budget, "ms"),
            ),
            BenchResult(
                scenario: name, id: "library-facets-miscounted",
                name: "Facets that don't count each of their query's photos once", value: Double(miscounted),
                unit: "facets", budget: .exactly(0, "facets"),
            ),
        ]
    }
}
