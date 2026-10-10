import Foundation
import RedlampLibrary
import Synchronization

/// `redlamp library rename`, `move`, `copy`, `trash`, `undo` and `journal`: the library's file operations
/// (LIB-26), journaled, undoable and safe across a forced quit. Each finishes first a batch a forced
/// quit left unfinished.
extension LibraryCommand {
    static func rename(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index", "--text", "--limit"])
        guard let templateText = options.positional.first, let path = options.value("--index") else {
            throw CLIError(description: "rename needs a template and --index\n\n\(usage)")
        }
        let template: NamingTemplate
        do {
            template = try NamingTemplate(parsing: templateText)
        } catch {
            throw CLIError(description: pointing(at: error.range, in: templateText, error.message))
        }
        let query = try parsedQuery(options.positional.dropFirst().joined(separator: " "))
        var texts: [String: String] = [:]
        for text in options.values("--text") {
            if let equals = text.firstIndex(of: "=") {
                texts[String(text[..<equals])] = String(text[text.index(after: equals)...])
            } else {
                texts[""] = text
            }
        }
        let limit = try options.int("--limit")
        try await withOperations(path) { operations in
            let preview = try await operations.renamePreview(
                template, query: query, context: NamingContext(texts: texts),
            )
            if options.has("--dry-run") {
                if options.has("--json") {
                    try print(String(decoding: preview.json(limit: limit), as: UTF8.self))
                } else {
                    preview.lines(limit: limit).forEach { print($0) }
                }
                return
            }
            let batch = try await operations.planRename(preview)
            try await run(batch, operations: operations, json: options.has("--json"))
        }
    }

    static func move(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index", "--to", "--folder"])
        guard let path = options.value("--index"), let target = options.value("--to") else {
            throw CLIError(description: "move needs --to and --index\n\n\(usage)")
        }
        let destination = URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL
        let folder = options.value("--folder").map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        let queryText = options.positional.joined(separator: " ")
        guard folder != nil || !queryText.isEmpty else {
            throw CLIError(description: "move needs a query, or --folder\n\n\(usage)")
        }
        let query = try parsedQuery(queryText)
        try await withOperations(path) { operations in
            let batch = if let folder {
                try await operations.planMove(folder: folder, to: destination)
            } else {
                try await operations.planMove(photos: photos(matching: query, in: operations.index), to: destination)
            }
            try await planned(batch, operations: operations, options: options)
        }
    }

    static func copy(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index", "--to"])
        guard let path = options.value("--index"), let target = options.value("--to"), !options.positional.isEmpty
        else {
            throw CLIError(description: "copy needs a query, --to and --index\n\n\(usage)")
        }
        let destination = URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL
        let query = try parsedQuery(options.positional.joined(separator: " "))
        try await withOperations(path) { operations in
            let ids = try await photos(matching: query, in: operations.index)
            try await planned(
                operations.planCopy(photos: ids, to: destination),
                operations: operations,
                options: options,
            )
        }
    }

    static func trash(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard let path = options.value("--index"), !options.positional.isEmpty else {
            throw CLIError(description: "trash needs a query and --index\n\n\(usage)")
        }
        let query = try parsedQuery(options.positional.joined(separator: " "))
        try await withOperations(path) { operations in
            let batch = try await operations.planTrash(photos: photos(matching: query, in: operations.index))
            try await planned(batch, operations: operations, options: options)
        }
    }

    static func undo(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard let path = options.value("--index") else {
            throw CLIError(description: "undo needs --index\n\n\(usage)")
        }
        try await withOperations(path) { operations in
            guard let last = try await operations.lastUndoable() else {
                throw CLIError(description: "nothing to undo in the journal of \(path)")
            }
            let batch = try await operations.planUndo(last.id)
            try await run(batch, operations: operations, json: options.has("--json"))
        }
    }

    static func journal(_ arguments: [String]) async throws {
        let options = try Arguments(arguments, valued: ["--index"])
        guard let path = options.value("--index") else {
            throw CLIError(description: "journal needs --index\n\n\(usage)")
        }
        let choice: FileRecovery? = options.has("--roll-back") ? .rollBack : options.has("--finish") ? .finish : nil
        let index = try await openIndex(path)
        let operations = FileOperations(index: index)
        do {
            var settled: [FileOutcome] = []
            if let choice {
                settled = try await operations.recover(choice)
            }
            let entries = try await operations.entries()
            await index.close()
            if options.has("--json") {
                struct Entry: Encodable {
                    let id: String
                    let kind: String
                    let title: String
                    let created: Date
                    let state: String
                    let steps: Int
                    let done: Int
                    let photos: Int
                    let undoes: String?
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                try print(String(decoding: encoder.encode(entries.map { entry in
                    Entry(
                        id: entry.id.uuidString, kind: entry.kind.rawValue, title: entry.title, created: entry.created,
                        state: entry.state.rawValue, steps: entry.steps, done: entry.done, photos: entry.photos,
                        undoes: entry.undoes?.uuidString,
                    )
                }), as: UTF8.self))
            } else {
                for outcome in settled {
                    print("\(outcome.title): \(describe(outcome.state)) after a forced quit")
                }
                for entry in entries {
                    let date = entry.created.ISO8601Format()
                    let steps = "\(count(entry.done)) of \(count(entry.steps)) steps"
                    print("\(date)  \(entry.title): \(describe(entry.state)), \(steps)")
                }
                let unfinished = entries.filter(\.state.isUnfinished)
                if !unfinished.isEmpty {
                    let left = count(unfinished.count)
                    print("\(left) left unfinished by a forced quit: --finish or --roll-back settles them")
                } else if entries.isEmpty {
                    print("The journal is empty")
                }
            }
        } catch {
            await index.close()
            throw error
        }
    }

    // MARK: - Running

    /// A batch run, or with `--dry-run` described; conflicts printed and exit 1.
    static func planned(_ batch: FileBatch, operations: FileOperations, options: Arguments) async throws {
        guard options.has("--dry-run") else {
            return try await run(batch, operations: operations, json: options.has("--json"))
        }
        let conflicts = try await operations.check(batch)
        let moves = batch.steps.flatMap(\.items).filter { $0.role == .photo || $0.role == .folder }
        if options.has("--json") {
            struct Move: Encodable {
                let from: String
                let to: String?
            }
            struct Output: Encodable {
                let title: String
                let moves: [Move]
                let conflicts: [String]
                let gone: [String]
                let notInIndex: [Int64]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try print(String(decoding: encoder.encode(Output(
                title: batch.title, moves: moves.map { Move(from: $0.source, to: $0.destination) },
                conflicts: conflicts.map(\.description), gone: batch.gone, notInIndex: batch.notInIndex,
            )), as: UTF8.self))
        } else {
            for move in moves {
                print("\(move.source) → \(move.destination ?? "the Trash")")
            }
            let files = count(batch.steps.flatMap(\.items).count)
            let untouched = batch.kind == .copy ? "Nothing was copied." : "Nothing was moved."
            print("\(batch.title): \(count(batch.steps.count)) steps, \(files) files. "
                + (conflicts.isEmpty ? untouched : "It can't start:"))
            conflicts.prefix(50).forEach { print("  \($0)") }
            leftOut(gone: batch.gone, notInIndex: batch.notInIndex).forEach { print($0) }
        }
        if !conflicts.isEmpty {
            throw ExitCode(1)
        }
    }

    /// What a batch leaves out: what isn't where a batch left it any more, and the photos it was asked
    /// to move to the Trash that the index no longer has.
    private static func leftOut(gone: [String], notInIndex: [Int64]) -> [String] {
        var lines: [String] = []
        if !gone.isEmpty {
            lines.append("  \(count(gone.count)) left out, no longer where the batch left them:")
            lines += gone.prefix(20).map { "    \($0)" }
        }
        if !notInIndex.isEmpty {
            lines.append(
                "  \(count(notInIndex.count)) photo\(notInIndex.count == 1 ? "" : "s") left out, no longer in the "
                    + "index: " + notInIndex.map { "photo \($0)" }.joined(separator: ", "),
            )
        }
        return lines
    }

    /// Runs `batch`, printing its progress on stderr, then what it did.
    static func run(_ batch: FileBatch, operations: FileOperations, json: Bool) async throws {
        guard !batch.steps.isEmpty else {
            print("\(batch.title): nothing to do")
            leftOut(gone: batch.gone, notInIndex: batch.notInIndex).forEach { print($0) }
            return
        }
        let reported = Mutex(ContinuousClock.now)
        let clock = ContinuousClock()
        let started = clock.now
        let outcome: FileOutcome
        do {
            outcome = try await operations.run(batch) { progress in
                let report = reported.withLock { last in
                    guard ContinuousClock.now - last >= .seconds(1) || progress.done == progress.total
                    else { return false }
                    last = .now
                    return true
                }
                if report {
                    let doing = progress.isRollingBack ? "rolling back, " : ""
                    FileHandle.standardError
                        .write(Data("  \(doing)\(count(progress.done)) of \(count(progress.total)) steps\n".utf8))
                }
            }
        } catch let FileOperationError.conflicts(conflicts) {
            print("\(batch.title): nothing was moved, since")
            conflicts.prefix(50).forEach { print("  \($0)") }
            if conflicts.count > 50 {
                print("  and \(count(conflicts.count - 50)) more")
            }
            throw ExitCode(1)
        }
        let seconds = (clock.now - started) / .seconds(1)
        if json {
            struct Output: Encodable {
                let batch: String
                let title: String
                let state: String
                let steps: Int
                let done: Int
                let photos: Int
                let originalNamesRecorded: Int
                let originalNamesSkipped: [String]
                let foldersLeft: [String]
                let gone: [String]
                let notInIndex: [Int64]
                let seconds: Double
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try print(String(decoding: encoder.encode(Output(
                batch: outcome.batch.uuidString, title: outcome.title, state: outcome.state.rawValue,
                steps: outcome.steps, done: outcome.done, photos: outcome.photos,
                originalNamesRecorded: outcome.originalNamesRecorded,
                originalNamesSkipped: outcome.originalNamesSkipped,
                foldersLeft: outcome.foldersLeft, gone: outcome.gone, notInIndex: outcome.notInIndex, seconds: seconds,
            )), as: UTF8.self))
            return
        }
        var lines = [String(
            format: "%@: %@, %@ photo%@ in %.1f s", outcome.title, describe(outcome.state), count(outcome.photos),
            outcome.photos == 1 ? "" : "s", seconds,
        )]
        if outcome.originalNamesRecorded > 0 {
            lines.append("  \(count(outcome.originalNamesRecorded)) original names recorded in their sidecars")
        }
        if !outcome.originalNamesSkipped.isEmpty {
            lines
                .append(
                    "  \(count(outcome.originalNamesSkipped.count)) sidecars this build can't write kept as they were",
                )
        }
        lines += leftOut(gone: outcome.gone, notInIndex: outcome.notInIndex)
        if !outcome.foldersLeft.isEmpty {
            lines
                .append("  folders kept, something having been put in them: " + outcome.foldersLeft
                    .joined(separator: ", "))
        }
        print(lines.joined(separator: "\n"))
    }

    /// Opens the index, finishes a batch a forced quit left, then runs `body`.
    static func withOperations(_ path: String, _ body: (FileOperations) async throws -> Void) async throws {
        let index = try await openIndex(path)
        let operations = FileOperations(index: index)
        do {
            for outcome in try await operations.recover() {
                FileHandle.standardError.write(Data(
                    "\(outcome.title), which a forced quit interrupted: \(describe(outcome.state))\n".utf8,
                ))
            }
            try await body(operations)
            await index.close()
        } catch {
            await index.close()
            if let error = error as? FileOperationError {
                throw CLIError(description: describe(error))
            }
            throw error
        }
    }

    private static func openIndex(_ path: String) async throws -> LibraryIndex {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(description: "no index at \(url.path) (make one with redlamp library index)")
        }
        return try await LibraryIndex.open(at: url)
    }

    private static func parsedQuery(_ text: String) throws -> LibraryQuery {
        do {
            return try LibraryQuery(parsing: text)
        } catch {
            throw CLIError(description: pointing(at: error.range, in: text, error.message))
        }
    }

    /// The IDs of the photos `query` finds, when they were taken.
    private static func photos(matching query: LibraryQuery, in index: LibraryIndex) async throws -> [Int64] {
        let engine = QueryEngine(index: index)
        try await engine.load()
        var found: [Int64] = []
        for try await result in engine.search(query) {
            found = Array(result.ids)
        }
        return found
    }

    private static func describe(_ state: FileJournal.State) -> String {
        switch state {
        case .planned: "planned"
        case .running: "unfinished"
        case .finished: "done"
        case .stopped: "stopped partway"
        case .rollingBack: "rolling back"
        case .rolledBack: "rolled back"
        case .undone: "undone"
        }
    }

    private static func describe(_ error: FileOperationError) -> String {
        switch error {
        case let .conflicts(conflicts): "nothing was moved: " + conflicts.prefix(5).map(\.description)
            .joined(separator: "; ")
        case let .unfinished(id): "a batch a forced quit interrupted (\(id)) is unfinished: run journal --finish"
        case let .noSuchBatch(id): "no batch \(id) in the journal"
        case let .damagedJournal(id): "the journal's batch \(id) can't be read"
        case let .newerJournal(id): "the journal's batch \(id) was written by a newer Redlamp"
        case .nothingToUndo: "nothing to undo"
        case let .notInLibrary(path): "\(path) isn't in the library's folders"
        case let .insideItself(path): "\(path) can't go inside itself"
        case let .isRoot(path): "\(path) is a folder added to the library: add it where it goes instead"
        case let .failed(path, message): "\(path): \(message); everything the batch had done was put back"
        case let .stuck(id, path, message):
            "\(path): \(message); the batch (\(id)) couldn't be put back and waits in the journal"
        }
    }

    private static func pointing(at range: Range<Int>, in text: String, _ message: String) -> String {
        let caret = String(repeating: " ", count: range.lowerBound) + String(repeating: "^", count: max(range.count, 1))
        return "\(text)\n\(caret)\n\(message)"
    }

    /// `20,000`, whatever the locale.
    private static func count(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}
