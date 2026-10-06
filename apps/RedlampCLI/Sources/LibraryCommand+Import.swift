import Foundation
import RedlampLibrary

extension LibraryCommand {
    /// `redlamp library import`: copies a card's or a folder's photos (LIB-27) to a destination, and to
    /// a backup when one is given, in folders and with names from naming templates, each photo verified
    /// at both before its card counts as safe to erase. Photos the index at `--index` has already, and
    /// those already in their folders at the destination, are left; the destination is added to the
    /// index. Without `--index` the import is journaled in the app's library folder and nothing is
    /// indexed. `--dry-run` prints the plan and copies nothing; an import a forced quit interrupted is
    /// finished first. Exits 1 when a photo wasn't copied and verified.
    static func importing(_ arguments: [String]) async throws {
        let options = try Arguments(
            arguments, valued: ["--to", "--backup", "--folders", "--names", "--keywords", "--index"],
        )
        guard options.positional.count == 1, let destination = options.value("--to") else {
            throw CLIError(description: "import needs a card or a folder and --to\n\n\(usage)")
        }
        let folder = URL(fileURLWithPath: options.positional[0], isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CLIError(description: "no card or folder at \(folder.path)")
        }
        let settings = try ImportSettings(
            destination: URL(fileURLWithPath: destination, isDirectory: true).standardizedFileURL,
            backup: options.value("--backup").map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL },
            folders: template(options.value("--folders"), or: ImportSettings.standardFolders),
            names: template(options.value("--names"), or: ImportSettings.standardNames),
            rawOnly: options.has("--raw-only"),
            metadata: ImportMetadata(keywords: options.values("--keywords").flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces) }),
        )
        let source = try ImportSource.at(folder)
        var index: LibraryIndex?
        if let path = options.value("--index") {
            index = try await LibraryIndex.open(at: URL(fileURLWithPath: path))
        }
        let library = index.map { ImportLibrary.around($0) } ?? ImportLibrary(paths: .standard)
        let result = await Result {
            try await ImportReport.importing(
                [source],
                settings: settings,
                library: library,
                dryRun: options.has("--dry-run"),
            )
        }
        library.store?.close()
        await index?.close()
        let (report, recovered) = try result.get()
        for outcome in recovered {
            FileHandle.standardError.write(Data(
                "Finished an import a forced quit interrupted: \(outcome.verified) of \(outcome.photos) photos verified\n"
                    .utf8,
            ))
        }
        if options.has("--json") {
            try print(String(decoding: report.json(), as: UTF8.self))
        } else {
            for line in report.lines() {
                print(line)
            }
        }
        if let outcome = report.outcome, !outcome.failures.isEmpty || outcome.state != ImportJournal.State.finished {
            throw ExitCode(1)
        }
    }

    /// The template `text` writes, or `standard` without one; an error points at what's wrong in it.
    private static func template(_ text: String?, or standard: NamingTemplate) throws -> NamingTemplate {
        guard let text else { return standard }
        do {
            return try NamingTemplate(parsing: text)
        } catch {
            let marks = String(repeating: " ", count: error.range.lowerBound)
                + String(repeating: "^", count: max(error.range.count, 1))
            throw CLIError(description: "\(text)\n\(marks)\n\(error.message)")
        }
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
