import Foundation
import RedlampLibrary

extension LibraryCommand {
    /// `redlamp library groups`: the photos a query finds, or a collection's, in groups (LIB-41), each
    /// with how many photos and picks it has and the filter finding it, then the moments without a
    /// pick and the photos' summary (`LibraryGroupReport`).
    static func groups(_ arguments: [String]) async throws {
        let options = try Arguments(
            arguments, valued: ["--index", "--by", "--tighter", "--looser", "--sort", "--collection"],
        )
        guard let path = options.value("--index") else {
            throw CLIError(description: "groups needs --index\n\n\(usage)")
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
        let keyName = options.value("--by") ?? GroupKey.moment.rawValue
        guard let key = GroupKey(rawValue: keyName) else {
            let names = GroupKey.allCases.map(\.rawValue)
            throw CLIError(
                description: "unknown grouping \(keyName): \(names.dropLast().joined(separator: ", ")) or \(names.last ?? "")",
            )
        }
        let setting = try momentSetting(options, command: "groups")
        let sortName = options.value("--sort") ?? QuerySort.Key.captured.rawValue
        guard let sortKey = QuerySort.Key(rawValue: sortName) else {
            let names = QuerySort.Key.allCases.map(\.rawValue)
            throw CLIError(
                description: "unknown sort \(sortName): \(names.dropLast().joined(separator: ", ")) or \(names.last ?? "")",
            )
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
        let report = try await LibraryGroupReport.run(
            query, in: collection, by: key, setting: setting,
            sort: QuerySort(sortKey, ascending: !options.has("--descending")), index: index,
        )
        await index.close()
        if options.has("--json") {
            try print(String(decoding: report.json(), as: UTF8.self))
            return
        }
        for line in report.lines() {
            print(line)
        }
    }

    /// The Tighter–Looser setting `--tighter` or `--looser` asks for, steps from the default.
    static func momentSetting(_ options: Arguments, command: String) throws -> MomentSetting {
        let (tighter, looser) = try (options.int("--tighter"), options.int("--looser"))
        guard tighter == nil || looser == nil else {
            throw CLIError(description: "\(command) takes --tighter or --looser, not both")
        }
        if let steps = tighter ?? looser, !(0 ... MomentSetting.loosest).contains(steps) {
            throw CLIError(description: "--tighter and --looser take 0 to \(MomentSetting.loosest) steps")
        }
        return MomentSetting(looseness: looser ?? -(tighter ?? 0))
    }
}
