import Foundation
import RedlampLibrary
import Synchronization

extension LibraryCommand {
    static let lightroomUsage = """
    usage: redlamp library lightroom <catalog> [--index <path>] [--root <lightroom folder>=<folder>]… [--apply]
                                     [--json]
           redlamp library lightroom --undo [--index <path>] [--json]
      lightroom reads a Lightroom Classic catalog, a .lrcat file or a copy of one, opened read-only and never
               written (one Lightroom has open is refused), and reports what it would bring into the library at
               --index, the app's own library without it (best with Redlamp closed): the catalog's root folders and
               where each is on this Mac, its photos found by path, their ratings, picks, rejects, colour labels,
               Quick Collection (Redlamp's mark), titles, captions, creators, copyrights and locations, the
               keywords with their hierarchy, synonyms and export options, the collections and sets, and the smart
               collections whose rules the query language can say; then what doesn't come across and why: virtual
               copies, Lightroom's edits, stacks and rules with no counterpart. --root says where a root folder
               that moved is now, by the path the report shows for it. --apply adds the root folders the library
               doesn't have and indexes them, then imports as the library's journaled batches, writing each
               photo's .redlamp sidecar: Lightroom's value replaces the library's where Lightroom has one, and
               keywords and collections join the photos'. --undo takes the last import back. --json prints JSON.
    """

    /// `redlamp library lightroom`: a Lightroom Classic catalog's report, its import with `--apply`, and the
    /// last import taken back with `--undo` (LIB-29). Exits 1 when a sidecar couldn't be written or a
    /// batch couldn't be taken back.
    static func lightroom(_ arguments: [String]) async throws {
        guard !arguments.contains("--help") else {
            print(lightroomUsage)
            return
        }
        let options = try Arguments(arguments, valued: ["--index", "--root"])
        let url = options.value("--index").map { URL(fileURLWithPath: $0) } ?? LibraryPaths.standard.index
        if options.has("--undo") {
            try await undoLightroom(index: url, json: options.has("--json"))
            return
        }
        guard options.positional.count == 1 else {
            throw CLIError(description: "lightroom needs a catalog\n\n\(lightroomUsage)")
        }
        let catalogURL = URL(fileURLWithPath: options.positional[0]).standardizedFileURL
        var moved: [String: URL] = [:]
        for argument in options.values("--root") {
            guard let equals = argument.lastIndex(of: "="), equals != argument.startIndex else {
                throw CLIError(
                    description: "--root needs <lightroom folder>=<folder>, as in --root D:/Photos/=/Volumes/Photos",
                )
            }
            let folder = URL(fileURLWithPath: String(argument[argument.index(after: equals)...]), isDirectory: true)
            moved[String(argument[..<equals])] = folder.standardizedFileURL
        }

        let catalog = try await Task.detached { try LightroomCatalog.read(catalogURL) }.value
        guard options.has("--apply") || FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(description: "no index at \(url.path): --apply makes one, or --index names another")
        }
        let index = try await LibraryIndex.open(at: url)
        let result = await Result {
            try await lightroom(
                catalog,
                index: index,
                moved: moved,
                apply: options.has("--apply"),
                json: options.has("--json"),
            )
        }
        await index.close()
        try result.get()
    }

    private static func lightroom(
        _ catalog: LightroomCatalog, index: LibraryIndex, moved: [String: URL], apply: Bool, json: Bool,
    ) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        var plan = try await LightroomPlan.make(catalog, index: index, moved: moved)
        let planned = clock.now - started
        guard apply else {
            if json {
                try print(String(decoding: plan.report.json(), as: UTF8.self))
            } else {
                plan.report.lines().forEach { print($0) }
                print("  read and worked out in \(seconds(planned)) s; --apply imports it")
            }
            return
        }
        if !plan.foldersToAdd.isEmpty {
            try await addFolders(plan.foldersToAdd, to: index)
            plan = try await LightroomPlan.make(catalog, index: index, moved: moved)
        }
        let reported = Mutex(ContinuousClock.now)
        let importer = LightroomImport(index: index)
        let outcome = try await importer.run(plan) { progress in
            let due = reported.withLock { last in
                guard ContinuousClock.now - last >= .seconds(1) || progress.done == progress.total else { return false }
                last = ContinuousClock.now
                return true
            }
            if due {
                FileHandle.standardError.write(Data(
                    "  \(number(progress.done)) of \(number(progress.total)) photos\n".utf8,
                ))
            }
        }
        let elapsed = clock.now - started
        if json {
            let object: [String: Any] = try [
                "report": JSONSerialization.jsonObject(with: plan.report.json()),
                "import": [
                    "id": outcome.record.id.uuidString, "photos": outcome.record.photos, "written": outcome.written,
                    "skipped": outcome.skipped, "batches": outcome.record.batches.map(\.id.uuidString),
                ],
            ]
            try print(String(decoding: JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes],
            ), as: UTF8.self))
        } else {
            plan.report.lines().forEach { print($0) }
            print("Imported in \(seconds(elapsed)) s: \(number(outcome.record.photos)) photos changed, "
                + "\(number(outcome.written)) sidecars written, "
                + "\(outcome.record.batches.count) batches; redlamp library lightroom --undo takes it back")
            for (path, why) in outcome.skipped.sorted(by: { $0.key < $1.key }) {
                print("  not written: \(path): \(why)")
            }
        }
        if !outcome.skipped.isEmpty {
            throw ExitCode(1)
        }
    }

    /// Adds `folders` to the index and indexes them, as `redlamp library index` does, before their photos are
    /// looked for.
    private static func addFolders(_ folders: [URL], to index: LibraryIndex) async throws {
        FileHandle.standardError.write(Data(
            "Adding \(folders.map(\.path).joined(separator: ", ")) to the library and indexing it\n".utf8,
        ))
        var added = 0
        var failures = 0
        for await event in LibraryIndexer(index: index).index(folders) {
            switch event {
            case let .photosInserted(ids): added += ids.count
            case let .failed(path, message):
                failures += 1
                if failures <= 20 {
                    FileHandle.standardError.write(Data("  couldn't index \(path): \(message)\n".utf8))
                }
            default: break
            }
        }
        FileHandle.standardError.write(Data("  \(number(added)) photos added\n".utf8))
    }

    private static func undoLightroom(index url: URL, json: Bool) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(description: "no index at \(url.path)")
        }
        let index = try await LibraryIndex.open(at: url)
        let result = await Result { try await LightroomImport(index: index).undo() }
        await index.close()
        switch result {
        case let .success(record):
            if json {
                try print(String(decoding: JSONSerialization.data(withJSONObject: [
                    "undone": record.id.uuidString, "catalog": record.catalog, "batches": record.batches.count,
                ], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
            } else {
                print("Took back the import from \(record.catalog): \(record.batches.count) batches, "
                    + "\(number(record.photos)) photos")
            }
        case let .failure(error as LightroomImportError):
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            throw ExitCode(1)
        case let .failure(error):
            throw error
        }
    }

    /// `20,000`, whatever the locale.
    private static func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.2f", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }
}

private extension Result where Failure == any Error {
    init(_ body: () async throws -> Success) async {
        do {
            self = try await .success(body())
        } catch {
            self = .failure(error)
        }
    }
}
