import Foundation
import RedlampLibrary

extension LibraryCommand {
    /// `redlamp library xmp`: metadata shared with other apps (LIB-24). Each photo a query finds in an
    /// index (every photo without one) that has other apps' `.xmp` or a `.redlamp`: what each holds,
    /// the changes other apps made that its `.redlamp` takes, and the fields written to its `.xmp`,
    /// which happens with `--write` or once the library writes them; then a summary. `--dry-run`
    /// works it all out and writes nothing. Exits 1 when a sidecar couldn't be written.
    static func xmp(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard let path = options.value("--index") else {
            throw CLIError(description: "xmp needs --index\n\n\(usage)")
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
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(description: "no index at \(url.path) (make one with redlamp library index)")
        }

        let index = try await LibraryIndex.open(at: url)
        let engine = QueryEngine(index: index)
        try await engine.load()
        var found = QueryResult(ids: [], count: 0, isComplete: true)
        for try await result in engine.search(query) {
            found = result
        }
        let report = try await LibraryXMP(index: index).sync(
            Array(found.ids), writing: options.has("--write") ? true : nil, dryRun: options.has("--dry-run"),
        )
        await index.close()
        if options.has("--json") {
            try print(String(decoding: report.json(), as: UTF8.self))
        } else {
            for line in report.lines {
                print(line)
            }
        }
        if report.photos.contains(where: { $0.problem != nil }) {
            throw ExitCode(1)
        }
    }
}
