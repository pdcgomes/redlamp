import Foundation

/// What `redlamp library import` prints: the plan, a line a photo, what stays on the sources and why,
/// and once it has run, what was copied and verified and whether each card can be erased.
public struct ImportReport: Sendable {
    public let plan: ImportPlan
    /// Nil for a dry run.
    public let outcome: ImportOutcome?
    /// Reading the sources' photos, before planning.
    public let browsing: Duration?

    public init(plan: ImportPlan, outcome: ImportOutcome? = nil, browsing: Duration? = nil) {
        self.plan = plan
        self.outcome = outcome
        self.browsing = browsing
    }

    /// What `redlamp library import` does: finishes the imports a forced quit interrupted, reads the
    /// sources' photos (their heads, without previews: the indexer makes thumbnails at the destination),
    /// plans the import and, unless it's a dry run, copies it.
    public static func importing(
        _ sources: [ImportSource], settings: ImportSettings, library: ImportLibrary,
        fileSystem: any LibraryFileSystem = LocalFileSystem(), dryRun: Bool = false,
    ) async throws -> (report: ImportReport, recovered: [ImportOutcome]) {
        let session = ImportSession(sources: sources, library: library, fileSystem: fileSystem, makesPreviews: false)
        let importer = session.importer()
        let recovered = dryRun ? [] : try await importer.recover()
        let clock = ContinuousClock()
        let started = clock.now
        for await _ in session.browse() {}
        let browsing = clock.now - started
        let plan = try await session.plan(settings)
        guard !dryRun else { return (ImportReport(plan: plan, browsing: browsing), recovered) }
        let outcome = try await importer.run(plan)
        return (ImportReport(plan: plan, outcome: outcome, browsing: browsing), recovered)
    }

    /// A line a photo, the first `limit` of them, then the summary.
    public func lines(limit: Int? = nil) -> [String] {
        let destination = LibraryIndexer.path(plan.settings.destination)
        var lines = plan.items.prefix(limit ?? plan.items.count).map { item in
            let first = item.copies[0]
            var notes: [String] = []
            let others = item.copies.dropFirst().map(\.name)
            if !others.isEmpty {
                notes.append("with " + others.joined(separator: ", "))
            }
            if let number = item.numbered {
                notes.append("numbered \(number) to tell it apart")
            }
            if !item.emptyTokens.isEmpty {
                notes.append("empty: " + item.emptyTokens.joined(separator: ", "))
            }
            if let failure = outcome?.failures.first(where: { $0.photo == item.photo }) {
                notes.append("not copied: \(failure.message)")
            }
            return "\(first.source) → \(destination)/\(first.path)" +
                (notes.isEmpty ? "" : "  (\(notes.joined(separator: "; ")))")
        }
        let sources = plan.sources.map { "\($0.name) (\($0.kind.rawValue))" }.joined(separator: ", ")
        var summary = "\(Self.count(plan.items.count, "photo")), \(Self.count(plan.files, "file")), "
            + "\(Self.size(plan.bytes)) from \(sources.isEmpty ? "nowhere" : sources) to \(destination)"
        if let backup = plan.settings.backup {
            summary += ", with a backup at \(LibraryIndexer.path(backup))"
        }
        summary += ": \(Self.count(plan.folders.count, "folder")), \(plan.numbered) numbered to tell them apart"
        if limit.map({ $0 < plan.items.count }) == true {
            summary += ". The first \(limit!) are shown"
        }
        lines.append(summary + ".")
        let left = Self.reasons.compactMap { reason, text -> String? in
            let count = plan.left(reason)
            return count == 0 ? nil : "\(count) \(text)"
        }
        if !left.isEmpty {
            lines.append("Left on the sources: " + left.joined(separator: ", ") + ".")
        }
        for source in plan.sources where source.otherFiles > 0 {
            lines.append(source.otherFiles == 1
                ? "\(source.name) also holds 1 file that isn't a photo, left where it is."
                : "\(source.name) also holds \(Self.count(source.otherFiles, "file")) that aren't photos, left where "
                + "they are.")
        }
        lines += plan.problems
        guard let outcome else {
            lines.append("A dry run: nothing was copied.")
            return lines
        }
        let seconds = max(outcome.elapsed.seconds, 1e-9)
        var copied = "Copied and verified \(outcome.verified) of \(Self.count(outcome.photos, "photo")) "
            + "(\(Self.count(outcome.files, "file")), \(Self.size(outcome.bytes))) in "
            + String(format: "%.1f s, %.1f MB a second", seconds, Double(outcome.bytes) / 1_000_000 / seconds)
        if plan.settings.backup != nil {
            copied += ", at the destination and the backup"
        }
        lines.append(copied + ".")
        if outcome.sidecars > 0 || outcome.indexed > 0 {
            lines.append("\(Self.count(outcome.sidecars, "sidecar")) written with the choices made and the metadata; "
                + "\(Self.count(outcome.indexed, "photo")) added to the index.")
        }
        for problem in outcome.sidecarsFailed {
            lines.append("\(problem): its sidecar couldn't be written")
        }
        for source in outcome.sources {
            let verdict = source.isSafeToErase
                ? "safe to erase: every photo copied from it is verified at every destination"
                : "not safe to erase: \(source.verified) of \(source.photos) photos verified"
                + (source.failed > 0 ? ", \(source.failed) not copied" : "")
            lines.append("\(source.name): \(verdict).")
        }
        return lines
    }

    private static let reasons: [(ImportPlan.Reason, String)] = [
        (.imported, "already in the library"), (.atDestination, "already at the destination"),
        (.rawOnly, "not raw files (raw only)"), (.notChosen, "not chosen"), (.unreadable, "unreadable"),
        (.blocked, "with no folder to go in"),
    ]

    /// The same as JSON, for scripts.
    public func json() throws -> Data {
        struct Copy: Encodable {
            let source: String
            let destination: String
            let backup: String?
            let bytes: Int64
        }
        struct Photo: Encodable {
            let id: String
            let files: [Copy]
            let numbered: Int?
            let emptyTokens: [String]
            let rating: Int
            let flag: String?
            let label: String?
            let failed: String?
        }
        struct Source: Encodable {
            let name: String
            let kind: String
            let path: String
            let photos: Int
            let verified: Int?
            let safeToErase: Bool?
            let otherFiles: Int
        }
        struct Output: Encodable {
            let tool: String
            let dryRun: Bool
            let destination: String
            let backup: String?
            let folders: String
            let names: String
            let rawOnly: Bool
            let keywords: [String]
            let photos: [Photo]
            let files: Int
            let bytes: Int64
            let numbered: Int
            let left: [String: Int]
            let sources: [Source]
            let verified: Int?
            let sidecars: Int?
            let indexed: Int?
            let seconds: Double?
            let safeToErase: Bool?
        }
        let photos = plan.items.map { item in
            Photo(
                id: item.photo,
                files: item.copies.map { copy in
                    let targets = plan.targets(of: copy)
                    return Copy(
                        source: copy.source, destination: targets[0].path, backup: targets.dropFirst().first?.path,
                        bytes: copy.size,
                    )
                },
                numbered: item.numbered, emptyTokens: item.emptyTokens, rating: item.choices.rating,
                flag: item.choices.flag?.rawValue, label: item.choices.label?.rawValue,
                failed: outcome?.failures.first { $0.photo == item.photo }?.message,
            )
        }
        var left: [String: Int] = [:]
        for reason in ImportPlan.Reason.allCases where plan.left(reason) > 0 {
            left[reason.rawValue] = plan.left(reason)
        }
        let sources = plan.sources.map { source in
            let done = outcome?.sources.first { $0.id == source.id }
            return Source(
                name: source.name, kind: source.kind.rawValue, path: source.path,
                photos: plan.items.count { $0.source == source.id }, verified: done?.verified,
                safeToErase: done?.isSafeToErase, otherFiles: source.otherFiles,
            )
        }
        let output = Output(
            tool: "redlamp library import", dryRun: outcome == nil,
            destination: LibraryIndexer.path(plan.settings.destination),
            backup: plan.settings.backup.map(LibraryIndexer.path), folders: plan.settings.folders.description,
            names: plan.settings.names.description, rawOnly: plan.settings.rawOnly,
            keywords: plan.settings.metadata.keywords, photos: photos, files: plan.files, bytes: plan.bytes,
            numbered: plan.numbered, left: left, sources: sources, verified: outcome?.verified,
            sidecars: outcome?.sidecars, indexed: outcome?.indexed, seconds: outcome?.elapsed.seconds,
            safeToErase: outcome?.isSafeToErase,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(output)
    }

    static func count(_ value: Int, _ noun: String) -> String {
        "\(BenchResult.grouped(value)) \(noun)\(value == 1 ? "" : "s")"
    }

    static func size(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1e9 {
            return String(format: "%.1f GB", value / 1e9)
        }
        if value >= 1e6 {
            return String(format: "%.1f MB", value / 1e6)
        }
        return String(format: "%.0f KB", value / 1e3)
    }
}
