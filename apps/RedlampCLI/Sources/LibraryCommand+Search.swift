import Foundation
import RedlampLibrary

extension LibraryCommand {
    /// `redlamp library search`: runs a query over an index (LIB-06) and prints the photos' paths in
    /// order, then how many photos the query found and how long it took.
    static func search(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index", "--sort", "--limit"])
        guard !options.positional.isEmpty, let path = options.value("--index") else {
            throw CLIError(description: "search needs a query and --index\n\n\(usage)")
        }
        let text = options.positional.joined(separator: " ")
        let query: LibraryQuery
        do {
            query = try LibraryQuery(parsing: text)
        } catch {
            let caret = String(repeating: " ", count: error.range.lowerBound)
                + String(repeating: "^", count: max(error.range.count, 1))
            throw CLIError(description: "\(text)\n\(caret)\n\(error.message)")
        }
        let sortName = options.value("--sort") ?? QuerySort.Key.captured.rawValue
        guard let key = QuerySort.Key(rawValue: sortName) else {
            throw CLIError(description: "unknown sort \(sortName): captured, name, rating or edited")
        }
        let sort = QuerySort(key, ascending: !options.has("--descending"))
        let limit = try options.int("--limit")
        if let limit, limit < 0 {
            throw CLIError(description: "--limit needs a whole number, 0 or more")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(description: "no index at \(url.path) (make one with redlamp library index)")
        }

        let index = try await LibraryIndex.open(at: url)
        let engine = QueryEngine(index: index)
        let clock = ContinuousClock()
        let loading = clock.now
        try await engine.load()
        let loaded = clock.now - loading
        let started = clock.now
        var firstPage: Duration?
        var result = QueryResult(ids: [], count: 0, isComplete: true)
        for try await found in engine.search(query, sort: sort) {
            firstPage = firstPage ?? clock.now - started
            result = found
        }
        let elapsed = clock.now - started
        let shown = Array(result.ids.prefix(limit ?? result.ids.count))
        let paths = try await index.read { reader in try shown.map { try reader.photoPath(id: $0) ?? "" } }
        await index.close()

        let count = result.count ?? result.ids.count
        if options.has("--json") {
            struct Output: Encodable {
                let query: String
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
            let output = Output(
                query: query.description, sort: key.rawValue, ascending: sort.ascending, count: count,
                milliseconds: elapsed.milliseconds, firstPageMilliseconds: (firstPage ?? elapsed).milliseconds,
                loadMilliseconds: loaded.milliseconds, paths: paths,
            )
            try print(String(decoding: encoder.encode(output), as: UTF8.self))
            return
        }
        for path in paths {
            print(path)
        }
        var summary = "\(grouped(count)) photos for \(query.description.isEmpty ? "everything" : query.description)"
            + ", sorted by \(key.rawValue)\(sort.ascending ? "" : ", descending"), in "
            + String(
                format: "%.1f ms (first page in %.1f ms; column store built in %.0f ms)",
                elapsed.milliseconds,
                (firstPage ?? elapsed).milliseconds,
                loaded.milliseconds,
            )
        if shown.count < count {
            summary += "; the first \(grouped(shown.count)) shown"
        }
        print(summary)
    }

    /// `20,000`, whatever the locale.
    private static func grouped(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}

private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
