import Foundation
import RedlampLibrary
import Synchronization

/// `redlamp library keywords`: the keyword list (LIB-21), Lightroom Classic's keyword-list files in
/// and out, and keywords added to and removed from the photos a query finds, renamed, merged and
/// deleted, each change a batch with Undo. Every change first finishes one a forced quit left.
extension LibraryCommand {
    static let keywordsUsage = """
    usage: redlamp library keywords --index <path> [--tree] [--json]
           redlamp library keywords import <file> --index <path>
           redlamp library keywords export <file> --index <path>
           redlamp library keywords add|remove <keyword> --index <path> <query> [--dry-run] [--json]
           redlamp library keywords rename <keyword> <path> --index <path> [--dry-run]
           redlamp library keywords merge <keyword>… --into <keyword> --index <path> [--dry-run]
           redlamp library keywords delete <keyword>… --index <path> [--dry-run]
           redlamp library keywords undo --index <path>
    """

    static func keywords(_ arguments: [String]) async throws {
        let rest = Array(arguments.dropFirst())
        switch arguments.first {
        case "import": try await importKeywords(rest)
        case "export": try await exportKeywords(rest)
        case "add": try await changeKeyword(rest, adding: true)
        case "remove": try await changeKeyword(rest, adding: false)
        case "rename": try await renameKeyword(rest)
        case "merge": try await mergeKeywords(rest)
        case "delete": try await deleteKeywords(rest)
        case "undo": try await undoKeywords(rest)
        default: try await listKeywords(arguments)
        }
    }

    // MARK: - The list

    /// Every keyword with how many photos have it or one inside it, its path ready for `kw:`; with
    /// `--tree`, indented under the keywords containing it, with its options.
    private static func listKeywords(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard options.positional.isEmpty, let path = options.value("--index") else {
            throw CLIError(description: "keywords needs --index\n\n\(keywordsUsage)")
        }
        let list = try await withKeywords(path, recovering: false) { try await $0.list() }
        if options.has("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let output: [KeywordOutput] = options.has("--tree")
                ? list.children(of: nil).map { KeywordOutput($0, in: list, nested: true) }
                : list.ordered.map { KeywordOutput($0, in: list, nested: false) }
            try print(String(decoding: encoder.encode(output), as: UTF8.self))
            return
        }
        for keyword in list.ordered {
            let count = "\(keywordCount(keyword.count)) photo\(keyword.count == 1 ? "" : "s")"
            if options.has("--tree") {
                let notes = notes(keyword.options) + (keyword.isDefined && keyword.count == 0 ? ["kept"] : [])
                let detail = notes.isEmpty ? "" : "  " + notes.joined(separator: ", ")
                print("\(String(repeating: "  ", count: keyword.path.depth))\(keyword.name) (\(count))\(detail)")
            } else {
                print("\(keyword.path.text)\t\(count)")
            }
        }
        print("\(keywordCount(list.keywords.count)) keywords, \(keywordCount(list.roots.count)) at the top")
    }

    /// A keyword as `--json` prints it.
    private struct KeywordOutput: Encodable {
        let path: String
        let names: [String]
        let photos: Int
        let count: Int
        let synonyms: [String]
        let includeOnExport: Bool
        let exportContainingKeywords: Bool
        let exportSynonyms: Bool
        let category: Bool
        let `private`: Bool
        let person: Bool
        let defined: Bool
        let children: [KeywordOutput]?

        init(_ keyword: KeywordList.Keyword, in list: KeywordList, nested: Bool) {
            path = keyword.path.text
            names = keyword.path.names
            photos = keyword.photos
            count = keyword.count
            synonyms = keyword.options.synonyms
            includeOnExport = keyword.options.includeOnExport
            exportContainingKeywords = keyword.options.exportContainingKeywords
            exportSynonyms = keyword.options.exportSynonyms
            category = keyword.options.isCategory
            `private` = keyword.options.isPrivate
            person = keyword.options.isPerson
            defined = keyword.isDefined
            children = nested ? list.children(of: keyword.path).map { KeywordOutput($0, in: list, nested: true) } : nil
        }
    }

    private static func notes(_ options: KeywordOptions) -> [String] {
        var notes: [String] = []
        if options.isCategory {
            notes.append("category")
        }
        if options.isPrivate {
            notes.append("private")
        }
        if options.isPerson {
            notes.append("person")
        }
        if !options.includeOnExport {
            notes.append("not exported")
        }
        if !options.exportContainingKeywords {
            notes.append("exported without the keywords containing it")
        }
        if !options.exportSynonyms {
            notes.append("exported without its synonyms")
        }
        if !options.synonyms.isEmpty {
            notes.append("synonyms: " + options.synonyms.joined(separator: ", "))
        }
        return notes
    }

    // MARK: - Lightroom's keyword-list files

    private static func importKeywords(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard options.positional.count == 1, let path = options.value("--index") else {
            throw CLIError(description: "keywords import needs a file and --index\n\n\(keywordsUsage)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: options.positional[0]))
        let outcome = try await withKeywords(path) { try await $0.importLightroomFile(data) }
        print("\(outcome.title): \(describe(outcome.state))")
    }

    private static func exportKeywords(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard options.positional.count == 1, let path = options.value("--index") else {
            throw CLIError(description: "keywords export needs a file and --index\n\n\(keywordsUsage)")
        }
        let file = URL(fileURLWithPath: options.positional[0])
        let export = try await withKeywords(path, recovering: false) { try await $0.exportLightroomFile() }
        try Data(export.text.utf8).write(to: file, options: .atomic)
        print("\(keywordCount(export.keywords)) keywords written to \(file.path)")
        if !export.unrepresentable.isEmpty {
            print("  read back as something else, their names in brackets or braces: "
                + export.unrepresentable.map(\.text).joined(separator: ", "))
        }
        if !export.refusedByLightroom.isEmpty {
            print("  refused by Lightroom Classic, a comma, semicolon or pipe in the name or an asterisk at its end: "
                + export.refusedByLightroom.map(\.text).joined(separator: ", "))
        }
    }

    // MARK: - Changes

    private static func changeKeyword(_ arguments: [String], adding: Bool) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        let verb = adding ? "add" : "remove"
        guard let text = options.positional.first, let path = options.value("--index") else {
            throw CLIError(description: "keywords \(verb) needs a keyword and --index\n\n\(keywordsUsage)")
        }
        let query = try keywordQuery(options.positional.dropFirst().joined(separator: " "))
        try await withKeywords(path) { keywords in
            let list = try await keywords.list()
            let keyword = try resolved(text, in: list, existing: !adding)
            let ids = try await photoIDs(matching: query, in: keywords.index)
            let change: KeywordChange = adding ? .add([keyword], to: ids) : .remove([keyword], from: ids)
            try await planned(keywords.plan(change), keywords: keywords, options: options)
        }
    }

    private static func renameKeyword(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard options.positional.count == 2, let path = options.value("--index") else {
            throw CLIError(description: "keywords rename needs a keyword, its new path and --index\n\n\(keywordsUsage)")
        }
        try await withKeywords(path) { keywords in
            let keyword = try await resolved(options.positional[0], in: keywords.list(), existing: true)
            guard let target = KeywordPath(options.positional[1]) else {
                throw CLIError(description: "“\(options.positional[1])” has no keyword in it")
            }
            let destination = target.names.count == 1 ? keyword.parent?.appending(target.name) ?? target : target
            try await planned(keywords.plan(.rename(keyword, to: destination)), keywords: keywords, options: options)
        }
    }

    private static func mergeKeywords(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index", "--into"])
        guard !options.positional.isEmpty, let into = options.value("--into"),
              let path = options.value("--index") else {
            throw CLIError(description: "keywords merge needs keywords, --into and --index\n\n\(keywordsUsage)")
        }
        try await withKeywords(path) { keywords in
            let list = try await keywords.list()
            let sources = try options.positional.map { try resolved($0, in: list, existing: true) }
            let target = try resolved(into, in: list, existing: false)
            try await planned(keywords.plan(.merge(sources, into: target)), keywords: keywords, options: options)
        }
    }

    private static func deleteKeywords(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard !options.positional.isEmpty, let path = options.value("--index") else {
            throw CLIError(description: "keywords delete needs keywords and --index\n\n\(keywordsUsage)")
        }
        try await withKeywords(path) { keywords in
            let list = try await keywords.list()
            let doomed = try options.positional.map { try resolved($0, in: list, existing: true) }
            try await planned(keywords.plan(.delete(doomed)), keywords: keywords, options: options)
        }
    }

    private static func undoKeywords(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard let path = options.value("--index") else {
            throw CLIError(description: "keywords undo needs --index\n\n\(keywordsUsage)")
        }
        try await withKeywords(path) { keywords in
            try await planned(keywords.planUndo(), keywords: keywords, options: options)
        }
    }

    /// Runs `plan`, printing its progress on stderr and then what it did; with `--dry-run`, prints
    /// each photo it would change and its keywords after, and changes nothing.
    private static func planned(_ plan: KeywordPlan, keywords: LibraryKeywords, options: Arguments) async throws {
        let photos = plan.photos
        if options.has("--dry-run") {
            if options.has("--json") {
                struct Photo: Encodable {
                    let path: String
                    let before: [String]
                    let after: [String]
                }
                struct Output: Encodable {
                    let title: String
                    let photos: [Photo]
                    let definitions: [String]
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try print(String(decoding: encoder.encode(Output(
                    title: plan.title,
                    photos: photos
                        .map { Photo(path: $0.path, before: $0.before.map(\.text), after: $0.after.map(\.text)) },
                    definitions: plan.definedKeywords.map(\.text),
                )), as: UTF8.self))
                return
            }
            for photo in photos {
                print("\(photo.path)\t\(photo.after.map(\.text).joined(separator: ", "))")
            }
            print("\(plan.title): \(keywordCount(photos.count)) photos would change. Nothing was written.")
            return
        }
        let reported = Mutex(ContinuousClock.now)
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = try await keywords.run(plan) { done, total in
            let report = reported.withLock { last in
                guard ContinuousClock.now - last >= .seconds(1) || done == total else { return false }
                last = .now
                return true
            }
            if report {
                FileHandle.standardError
                    .write(Data("  \(keywordCount(done)) of \(keywordCount(total)) sidecars\n".utf8))
            }
        }
        let seconds = (clock.now - started) / .seconds(1)
        if options.has("--json") {
            struct Output: Encodable {
                let batch: String
                let title: String
                let state: String
                let photos: Int
                let written: Int
                let skipped: [String]
                let seconds: Double
                let indexSeconds: Double
                let sidecarSeconds: Double
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try print(String(decoding: encoder.encode(Output(
                batch: outcome.batch.uuidString, title: outcome.title, state: outcome.state.rawValue,
                photos: outcome.photos, written: outcome.written, skipped: outcome.skipped, seconds: seconds,
                indexSeconds: outcome.indexTime / .seconds(1), sidecarSeconds: outcome.sidecarTime / .seconds(1),
            )), as: UTF8.self))
            return
        }
        print(String(
            format: "%@: %@, %@ photos changed, %@ sidecars written in %.1f s", outcome.title,
            describe(outcome.state), keywordCount(outcome.photos), keywordCount(outcome.written), seconds,
        ))
        if !outcome.skipped.isEmpty {
            print("  \(keywordCount(outcome.skipped.count)) sidecars this build can't write kept as they were:")
            outcome.skipped.prefix(20).forEach { print("    \($0)") }
        }
    }

    // MARK: - Helpers

    /// Opens the index, finishes a keyword change a forced quit left (unless `recovering` is false),
    /// then runs `body`.
    private static func withKeywords<T>(
        _ path: String, recovering: Bool = true, _ body: (LibraryKeywords) async throws -> T,
    ) async throws -> T {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(description: "no index at \(url.path) (make one with redlamp library index)")
        }
        let index = try await LibraryIndex.open(at: url)
        let keywords = LibraryKeywords(index: index)
        do {
            if recovering {
                for outcome in try await keywords.recover() {
                    FileHandle.standardError.write(Data(
                        "\(outcome.title), which a forced quit interrupted: \(describe(outcome.state))\n".utf8,
                    ))
                }
            }
            let result = try await body(keywords)
            await index.close()
            return result
        } catch {
            await index.close()
            if let error = error as? KeywordError {
                throw CLIError(description: error.description)
            }
            throw error
        }
    }

    /// The keyword `text` names: a path, or one the list has by its name or a synonym; a new one at
    /// that path unless it must be in the list.
    private static func resolved(_ text: String, in list: KeywordList, existing: Bool) throws -> KeywordPath {
        if let found = list.resolve(text) {
            return found
        }
        guard let path = KeywordPath(text) else { throw CLIError(description: "“\(text)” has no keyword in it") }
        guard !existing else { throw CLIError(description: "there's no keyword \(path.text) in the list") }
        return path
    }

    private static func keywordQuery(_ text: String) throws -> LibraryQuery {
        do {
            return try LibraryQuery(parsing: text)
        } catch {
            let caret = String(repeating: " ", count: error.range.lowerBound)
                + String(repeating: "^", count: max(error.range.count, 1))
            throw CLIError(description: "\(text)\n\(caret)\n\(error.message)")
        }
    }

    /// The IDs of the photos `query` finds.
    private static func photoIDs(matching query: LibraryQuery, in index: LibraryIndex) async throws -> [Int64] {
        let engine = QueryEngine(index: index)
        try await engine.load()
        var found: [Int64] = []
        for try await result in engine.search(query) {
            found = Array(result.ids)
        }
        return found
    }

    private static func describe(_ state: KeywordJournal.State) -> String {
        switch state {
        case .planned: "planned"
        case .running: "unfinished"
        case .finished: "done"
        case .rollingBack: "rolling back"
        case .rolledBack: "rolled back"
        case .undone: "undone"
        }
    }

    /// `20,000`, whatever the locale.
    private static func keywordCount(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}
