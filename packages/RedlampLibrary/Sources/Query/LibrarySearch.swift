import Foundation

/// A search as `redlamp library search` runs it (LIB-06): a query over an index, or over a collection's
/// photos, the photos it finds in a sort's order, how many there are, and how long it took, as lines
/// of text or as JSON.
public struct LibrarySearch: Sendable {
    public let query: LibraryQuery
    /// The collection, set or smart collection searched; nil for the whole library.
    public let collection: CollectionPath?
    public let sort: QuerySort
    /// How many photos the query found.
    public let count: Int
    /// The paths of the first photos found, as many as were asked for, in order.
    public let paths: [String]
    public let elapsed: Duration
    public let firstPage: Duration
    /// How long the column store took to build.
    public let loaded: Duration

    /// Runs `query` over `index`, or over the photos of `collection`, in `sort`'s order, keeping the
    /// paths of the first `limit` photos, or of every photo when it's nil.
    public static func run(
        _ query: LibraryQuery, in collection: CollectionPath? = nil, sort: QuerySort = QuerySort(),
        limit: Int? = nil, index: LibraryIndex,
    ) async throws -> LibrarySearch {
        let engine = QueryEngine(index: index)
        let clock = ContinuousClock()
        let loading = clock.now
        try await engine.load()
        let loaded = clock.now - loading
        let started = clock.now
        var firstPage: Duration?
        var result = QueryResult(ids: [], count: 0, isComplete: true)
        if let collection {
            let list = try await engine.list(.collection(collection), matching: query, sort: sort)
            result = QueryResult(ids: list.ids, count: list.count, isComplete: true)
        } else {
            for try await found in engine.search(query, sort: sort) {
                firstPage = firstPage ?? clock.now - started
                result = found
            }
        }
        let elapsed = clock.now - started
        let shown = Array(result.ids.prefix(limit ?? result.ids.count))
        let paths = try await index.read { reader in try shown.map { try reader.photoPath(id: $0) ?? "" } }
        return LibrarySearch(
            query: query, collection: collection, sort: sort, count: result.count ?? result.ids.count,
            paths: paths, elapsed: elapsed, firstPage: firstPage ?? elapsed, loaded: loaded,
        )
    }

    /// Each photo's path, then the summary.
    public func lines() -> [String] {
        paths + [summary]
    }

    /// How many photos were found, for which query, in which order and how soon.
    public var summary: String {
        let photos = count == 1 ? "1 photo" : "\(Self.grouped(count)) photos"
        var summary = "\(photos) for \(query.description.isEmpty ? "everything" : query.description)"
            + (collection.map { " in “\($0.displayName)”" } ?? "")
            + ", sorted by \(sort.key.rawValue)\(sort.ascending ? "" : ", descending"), in "
            + String(
                format: "%.1f ms (first page in %.1f ms; column store built in %.0f ms)",
                Self.milliseconds(elapsed), Self.milliseconds(firstPage), Self.milliseconds(loaded),
            )
        if paths.count < count {
            summary += "; the first \(Self.grouped(paths.count)) shown"
        }
        return summary
    }

    public func json() throws -> Data {
        struct Output: Encodable {
            let query: String
            let collection: String?
            let sort: String
            let ascending: Bool
            let count: Int
            let milliseconds: Double
            let firstPageMilliseconds: Double
            let loadMilliseconds: Double
            let paths: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Output(
            query: query.description, collection: collection?.text, sort: sort.key.rawValue,
            ascending: sort.ascending, count: count,
            milliseconds: Self.milliseconds(elapsed), firstPageMilliseconds: Self.milliseconds(firstPage),
            loadMilliseconds: Self.milliseconds(loaded), paths: paths,
        ))
    }

    /// `20,000`, whatever the locale.
    private static func grouped(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        duration / .milliseconds(1)
    }
}
