import Foundation
import RedlampLibrary

extension LibraryCommand {
    /// `redlamp library search`: runs a query over an index (LIB-06), or over the photos of a collection,
    /// a set or a smart collection with `--collection` (LIB-23), and prints the photos' paths in order,
    /// then how many photos the query found and how long it took (`LibrarySearch`).
    static func search(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index", "--sort", "--limit", "--collection"])
        guard !options.positional.isEmpty || options.value("--collection") != nil, let path = options.value("--index")
        else {
            throw CLIError(description: "search needs a query or --collection, and --index\n\n\(usage)")
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
            let names = QuerySort.Key.allCases.map(\.rawValue)
            throw CLIError(
                description: "unknown sort \(sortName): \(names.dropLast().joined(separator: ", ")) or \(names.last ?? "")",
            )
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
        var collection: CollectionPath?
        if let text = options.value("--collection") {
            guard let found = try await LibraryMetadata(index: index).collections.list().resolve(text) else {
                await index.close()
                throw CLIError(description: "there's no collection or set \(text)")
            }
            collection = found
        }
        let search = try await LibrarySearch.run(query, in: collection, sort: sort, limit: limit, index: index)
        await index.close()
        if options.has("--json") {
            try print(String(decoding: search.json(), as: UTF8.self))
            return
        }
        for line in search.lines() {
            print(line)
        }
    }
}
