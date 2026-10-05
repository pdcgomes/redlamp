import Foundation
import RedlampLibrary

extension LibraryCommand {
    /// `redlamp library names`: the names a naming template (LIB-25) gives the photos a query finds in
    /// an index, each photo's path now and its new name, with the names numbered to tell them apart and
    /// the tokens that came out empty. A dry run: it never renames.
    static func names(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index", "--limit", "--text"])
        guard let templateText = options.positional.first, let path = options.value("--index") else {
            throw CLIError(description: "names needs a template and --index\n\n\(usage)")
        }
        let template: NamingTemplate
        do {
            template = try NamingTemplate(parsing: templateText)
        } catch {
            throw CLIError(description: caret(templateText, error.range, error.message))
        }
        let queryText = options.positional.dropFirst().joined(separator: " ")
        let query: LibraryQuery
        do {
            query = try LibraryQuery(parsing: queryText)
        } catch {
            throw CLIError(description: caret(queryText, error.range, error.message))
        }
        let limit = try options.int("--limit")
        if let limit, limit < 0 {
            throw CLIError(description: "--limit needs a whole number, 0 or more")
        }
        var texts: [String: String] = [:]
        for text in options.values("--text") {
            if let equals = text.firstIndex(of: "=") {
                texts[String(text[..<equals])] = String(text[text.index(after: equals)...])
            } else {
                texts[""] = text
            }
        }
        for name in template.textNames where texts[name] == nil {
            let flag = name.isEmpty ? "--text <text>" : "--text \(name)=<text>"
            FileHandle.standardError.write(Data("\(template) uses a text the job is given: pass \(flag)\n".utf8))
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(description: "no index at \(url.path) (make one with redlamp library index)")
        }

        let index = try await LibraryIndex.open(at: url)
        let preview = try await NamingPreview.make(
            template, query: query, index: index, context: NamingContext(texts: texts),
        )
        await index.close()
        if options.has("--json") {
            try print(String(decoding: preview.json(limit: limit), as: UTF8.self))
        } else {
            for line in preview.lines(limit: limit) {
                print(line)
            }
        }
    }

    private static func caret(_ text: String, _ range: Range<Int>, _ message: String) -> String {
        let caret = String(repeating: " ", count: range.lowerBound) + String(repeating: "^", count: max(range.count, 1))
        return "\(text)\n\(caret)\n\(message)"
    }
}
