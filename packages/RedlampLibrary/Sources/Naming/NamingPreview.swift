import Foundation

/// What `redlamp library names` shows: the photos a query finds, each one's name now and the name a
/// template gives it, with the names numbered to tell them apart and the tokens that came out empty.
/// A dry run, which never renames: renaming is the file operations' (LIB-26).
public struct NamingPreview: Sendable {
    public struct Entry: Sendable {
        public let id: Int64
        /// Where the photo is now.
        public let path: String
        public let result: NamingResult
    }

    public let template: NamingTemplate
    public let query: LibraryQuery
    /// In the order the query finds them: when they were taken.
    public let entries: [Entry]
    public let batch: NamingBatch
    /// Naming the photos, once their fields were read.
    public let elapsed: Duration

    /// The photos `query` finds in `index` named by `template`, with the files beside them as
    /// `fileSystem` lists their folders.
    public static func make(
        _ template: NamingTemplate, query: LibraryQuery = .all, index: LibraryIndex,
        options: NamingOptions = NamingOptions(), context: NamingContext = NamingContext(),
        counters: NamingCounters = NamingCounters(), fileSystem: any LibraryFileSystem = LocalFileSystem(),
    ) async throws -> NamingPreview {
        let engine = QueryEngine(index: index, timeZone: context.timeZone)
        try await engine.load()
        var found = QueryResult(ids: [], count: 0, isComplete: true)
        for try await result in engine.search(query) {
            found = result
        }
        let usesKeywords = template.tokens.contains { $0.field == .keywords }
        let (job, ids) = try await NamingJob.renaming(
            Array(found.ids), in: index, fileSystem: fileSystem, keywords: usesKeywords,
        )
        let clock = ContinuousClock()
        let started = clock.now
        let batch = job.names(template, options: options, context: context, counters: counters)
        let elapsed = clock.now - started
        let entries = zip(ids, zip(job.photos, batch.results)).map { id, named in
            Entry(id: id, path: named.0.fields.folder + "/" + named.0.fields.name, result: named.1)
        }
        return NamingPreview(template: template, query: query, entries: entries, batch: batch, elapsed: elapsed)
    }

    /// A line a photo, the first `limit` of them, then what the job would do.
    public func lines(limit: Int? = nil) -> [String] {
        let tokens = template.tokens
        var lines = entries.prefix(limit ?? entries.count).map { entry in
            let notes = notes(entry.result, tokens: tokens)
            return "\(entry.path) → \(entry.result.name)" +
                (notes.isEmpty ? "" : "  (\(notes.joined(separator: "; ")))")
        }
        let renamed = entries.count - batch.unchanged
        var summary = "\(Self.grouped(entries.count)) photos for \(query.description.isEmpty ? "everything" : query.description): "
            + "\(Self.grouped(renamed)) renamed, \(Self.grouped(batch.unchanged)) unchanged, "
            + "\(Self.grouped(batch.collisions)) numbered to tell them apart"
        let empty = zip(tokens, batch.emptyCounts).filter { $0.1 > 0 }
        if !empty.isEmpty {
            summary += "; empty: " + empty.map { "\($0.0) for \(Self.grouped($0.1))" }.joined(separator: ", ")
        }
        summary += String(format: "; named in %.1f ms. Nothing was renamed.", elapsed / .milliseconds(1))
        if limit.map({ $0 < entries.count }) == true {
            summary += " The first \(Self.grouped(limit!)) are shown."
        }
        if !batch.counters.values.isEmpty, !template.counterNames.isEmpty {
            summary += " Counters after the job: "
                + template.counterNames.map { "\($0) \(batch.counters[$0])" }.joined(separator: ", ") + "."
        }
        lines.append(summary)
        return lines
    }

    /// The same as JSON, for scripts.
    public func json(limit: Int? = nil) throws -> Data {
        struct Numbered: Encodable {
            let suffix: Int
            /// The photo or file that has the name without the number, by its name now.
            let holder: String
            let holderIsFile: Bool
        }
        struct Photo: Encodable {
            let id: Int64
            let path: String
            let newName: String
            let unchanged: Bool
            let numbered: Numbered?
            let emptyTokens: [String]
            let adjusted: [String]
        }
        struct Output: Encodable {
            let template: String
            let query: String
            let count: Int
            let renamed: Int
            let unchanged: Int
            let numbered: Int
            let emptyTokens: [String: Int]
            let counters: [String: Int]
            let milliseconds: Double
            let photos: [Photo]
        }
        let tokens = template.tokens
        let photos = entries.prefix(limit ?? entries.count).map { entry in
            let collision = entry.result.collision.map { collision in
                switch collision.holder {
                case let .photo(index):
                    Numbered(suffix: collision.suffix, holder: entries[index].path, holderIsFile: false)
                case let .file(name):
                    Numbered(suffix: collision.suffix, holder: name, holderIsFile: true)
                }
            }
            return Photo(
                id: entry.id, path: entry.path, newName: entry.result.name, unchanged: entry.result.isUnchanged,
                numbered: collision, emptyTokens: entry.result.emptyTokens.map { tokens[$0].description },
                adjusted: Self.adjustments(entry.result.adjustments),
            )
        }
        var empty: [String: Int] = [:]
        for (token, count) in zip(tokens, batch.emptyCounts) where count > 0 {
            empty[token.description, default: 0] += count
        }
        let output = Output(
            template: template.description, query: query.description, count: entries.count,
            renamed: entries.count - batch.unchanged, unchanged: batch.unchanged, numbered: batch.collisions,
            emptyTokens: empty, counters: template.counterNames.reduce(into: [:]) { $0[$1] = batch.counters[$1] },
            milliseconds: elapsed / .milliseconds(1), photos: photos,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(output)
    }

    private func notes(_ result: NamingResult, tokens: [NamingToken]) -> [String] {
        var notes: [String] = []
        if result.isUnchanged {
            notes.append("unchanged")
        }
        if let collision = result.collision {
            switch collision.holder {
            case let .photo(index):
                notes.append("numbered: \((entries[index].path as NSString).lastPathComponent) has the name")
            case let .file(name):
                notes.append("numbered: \(name) is in the folder")
            }
        }
        if !result.emptyTokens.isEmpty {
            notes.append("empty: " + result.emptyTokens.map { tokens[$0].description }.joined(separator: ", "))
        }
        notes += Self.adjustments(result.adjustments)
        return notes
    }

    private static func adjustments(_ adjustments: NamingAdjustments) -> [String] {
        [
            (NamingAdjustments.replaced, "characters replaced"), (.trimmed, "trimmed"), (.shortened, "shortened"),
            (.reserved, "a device name, given an ending"), (.keptName, "nothing made, so it keeps its name"),
        ].compactMap { adjustments.contains($0.0) ? $0.1 : nil }
    }

    /// `20,000`, whatever the locale.
    private static func grouped(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}
