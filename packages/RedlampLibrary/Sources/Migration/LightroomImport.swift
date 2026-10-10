import Foundation
import RedlampDocument
import Synchronization

/// An import from a Lightroom Classic catalog, as the library keeps it to take back (LIB-29): its batches
/// in the keyword and metadata journals, in the order they ran.
public struct LightroomImportRecord: Sendable, Hashable, Codable, Identifiable {
    public struct Batch: Sendable, Hashable, Codable {
        public enum Journal: String, Sendable, Hashable, Codable {
            case keywords, metadata
        }

        public var journal: Journal
        public var id: UUID
    }

    public var id: UUID
    /// The catalog's path.
    public var catalog: String
    public var date: Date
    /// Photos whose fields or keywords it changed.
    public var photos = 0
    public var batches: [Batch] = []
    /// Stopped before every part ran.
    public var stopped = false
    public var undone = false
}

/// Why an import couldn't be made or taken back.
public enum LightroomImportError: Error, Sendable, Hashable, CustomStringConvertible {
    case nothingToUndo
    /// Some of an import's batches can't be taken back: the journals no longer have them as they ran.
    case partlyUndone([String])

    public var description: String {
        switch self {
        case .nothingToUndo: "there's no import from Lightroom Classic to undo"
        case let .partlyUndone(titles): "these weren't taken back: \(titles.joined(separator: "; "))"
        }
    }
}

/// Runs a Lightroom Classic catalog's import into the library (LIB-29) as the library's batches, so the
/// sidecars, the index, the open lists, Undo and the recovery after a forced quit work as for every change.
///
/// - **In parts** of `partSize` photos, each a keyword batch (each photo's keywords, and with the first part
///   the keyword definitions: synonyms, export options and keywords no photo has) and a metadata batch (the
///   fields and the collections, and with the first part the collection definitions: sets, smart collections
///   and collections without photos). `stop` is asked between parts, so a stopped import leaves whole
///   batches, which Undo takes back.
/// - **Undo** takes back every batch of the import, newest first, each keeping what changed since, as a
///   batch's Undo does.
/// - **The record** of imports (`Lightroom Imports.json` in the library's folder) names each import's batches,
///   written as each finishes, so an import a quit cut short can still be taken back.
public final class LightroomImport: Sendable {
    public let index: LibraryIndex
    public let paths: LibraryPaths
    public let live: LibraryLive?
    /// Photos a part takes.
    public let partSize: Int
    public static let standardPartSize = 10000
    /// Imports the record keeps; older ones go.
    static let kept = 20
    /// Runs each batch: at once by default; the app runs each in the library's turn for changes, so the
    /// syncs of other apps' metadata and the changes asked for meanwhile go between them.
    private let turn: (@Sendable (@escaping @Sendable () async -> Void) async -> Void)?
    /// Hears of the photos each batch changed, as the app's other apps' metadata follows them.
    private let changed: (@Sendable ([Int64]) -> Void)?
    private static let recordLock = Mutex(())

    public init(
        index: LibraryIndex, paths: LibraryPaths? = nil, live: LibraryLive? = nil,
        partSize: Int = LightroomImport.standardPartSize,
        turn: (@Sendable (@escaping @Sendable () async -> Void) async -> Void)? = nil,
        changed: (@Sendable ([Int64]) -> Void)? = nil,
    ) {
        self.index = index
        self.paths = paths ?? LibraryPaths(root: index.url.deletingLastPathComponent())
        self.live = live
        self.partSize = max(partSize, 1)
        self.turn = turn
        self.changed = changed
    }

    private var keywords: LibraryKeywords {
        LibraryKeywords(index: index, paths: paths, live: live)
    }

    private var metadata: LibraryMetadata {
        LibraryMetadata(index: index, paths: paths, live: live)
    }

    /// How far an import or its Undo has got: photos done of the photos it takes, and its parts.
    public struct Progress: Sendable, Hashable {
        public var done: Int
        public var total: Int
        public var part: Int
        public var parts: Int

        public init(done: Int, total: Int, part: Int, parts: Int) {
            self.done = done
            self.total = total
            self.part = part
            self.parts = parts
        }
    }

    /// What an import did.
    public struct Outcome: Sendable, Hashable {
        public var record: LightroomImportRecord
        /// Sidecars written.
        public var written = 0
        /// Photos whose sidecars this build can't write, left as they were, by path, and why.
        public var skipped: [String: String] = [:]
    }

    // MARK: - Importing

    /// Runs `plan`: each part's keyword batch, then its metadata batch, `progress` hearing of the photos done
    /// and `stop` asked before each part after the first. A batch that fails is rolled back and the error
    /// thrown; the parts before it stay, in the record, for Undo.
    @discardableResult
    public func run(
        _ plan: LightroomPlan, progress: (@Sendable (Progress) -> Void)? = nil, stop: (@Sendable () -> Bool)? = nil,
    ) async throws -> Outcome {
        try await settle()
        var outcome = Outcome(record: LightroomImportRecord(id: UUID(), catalog: plan.report.catalog, date: Date()))
        let photos = plan.photos
        let parts = max(1, (photos.count + partSize - 1) / partSize)
        var changedPhotos = Set<Int64>()
        try save(outcome.record)
        for part in 0 ..< parts {
            if part > 0, stop?() == true {
                outcome.record.stopped = true
                break
            }
            let slice = Array(photos[min(part * partSize, photos.count) ..< min((part + 1) * partSize, photos.count)])
            let start = part * partSize
            let title = Self.title(
                plan.name,
                photos: photos.count,
                part: part,
                of: parts,
                from: start,
                count: slice.count,
            )
            let report: @Sendable (Double) -> Void = { fraction in
                progress?(Progress(
                    done: start + Int(Double(slice.count) * fraction), total: photos.count, part: part, parts: parts,
                ))
            }
            let keywordPlan = try await keywordPlan(
                slice, definitions: part == 0 ? plan.keywords : [:], title: "Import the keywords of \(title)",
            )
            if !keywordPlan.isEmpty {
                let ran = try await inTurn { [keywords] in
                    try await keywords
                        .run(keywordPlan) { done, total in report(Double(done) / Double(max(total, 1)) / 2) }
                }
                outcome.record.batches.append(.init(journal: .keywords, id: ran.batch))
                outcome.written += ran.written
                for path in ran.skipped {
                    outcome.skipped[path] = "its sidecar can't be written here"
                }
                changedPhotos.formUnion(keywordPlan.photos.map(\.id))
                changed?(keywordPlan.photos.map(\.id))
                try save(outcome.record)
            }
            let metadataPlan = try await metadataPlan(
                slice, definitions: part == 0 ? plan.collections : [:], title: "Import \(title)",
            )
            if !metadataPlan.isEmpty {
                let ran = try await inTurn { [metadata] in
                    try await metadata.run(metadataPlan) { done, total in
                        report(0.5 + Double(done) / Double(max(total, 1)) / 2)
                    }
                }
                outcome.record.batches.append(.init(journal: .metadata, id: ran.batch))
                outcome.written += ran.written
                outcome.skipped.merge(ran.reasons) { first, _ in first }
                changedPhotos.formUnion(metadataPlan.photos.map(\.id))
                changed?(metadataPlan.photos.map(\.id))
                if metadataPlan.batch.definitions != nil {
                    live?.namesChanged()
                }
            }
            outcome.record.photos = changedPhotos.count
            try save(outcome.record)
            report(1)
        }
        try save(outcome.record)
        return outcome
    }

    /// `1,200 photos from “Lightroom Catalog”`, and which part when there are several.
    static func title(_ name: String, photos: Int, part: Int, of parts: Int, from _: Int, count: Int) -> String {
        let whole = "\(LibraryMetadata.count(parts == 1 ? count : photos)) from “\(name)”"
        guard parts > 1 else { return whole }
        return "\(whole), part \(part + 1) of \(parts)"
    }

    /// Finishes the keyword and metadata batches a forced quit left unfinished, which would stop a new one.
    private func settle() async throws {
        if try await !keywords.unfinishedEntries().isEmpty {
            try await keywords.recover()
        }
        if try await !metadata.unfinishedEntries().isEmpty {
            try await metadata.recover()
        }
    }

    /// The keyword batch of `part`: each photo gets the keywords Lightroom gives it that it lacks, after
    /// those it has. A keyword batch gives every photo one edit, so each photo's keywords go in as the target
    /// of its `undo`, the per-photo form an Undo uses to give each photo back the keywords it had: the batch
    /// is the Undo of one that took them off.
    func keywordPlan(
        _ part: [(id: Int64, values: LightroomValues)], definitions: [KeywordPath: KeywordOptions], title: String,
    ) async throws -> KeywordPlan {
        let wanted = part.filter { !$0.values.keywords.isEmpty }
        let ids = wanted.map(\.id)
        let (current, paths) = try await index.read { reader in
            try (reader.keywordPaths(ofPhotos: ids), reader.photoPaths(ids))
        }
        var batch = KeywordBatch(kind: .add, title: title)
        for (id, values) in wanted {
            guard let shown = current[id], let path = paths[id] else { continue }
            var target = shown
            for keyword in values.keywords where !target.contains(keyword) {
                target.append(keyword)
            }
            guard target != shown else { continue }
            batch.photos.append(KeywordBatch.Photo(
                id: id, path: path, index: shown,
                undo: KeywordBatch.Undo(
                    sidecarBefore: SidecarKeywords(keywords: target.map(\.text)),
                    sidecarAfter: SidecarKeywords(keywords: shown.map(\.text)), indexBefore: target, indexAfter: shown,
                ),
            ))
        }
        if !definitions.isEmpty {
            let old = try await keywords.definitions()
            var new = old
            for (path, options) in definitions {
                new.keywords[path] = Self.merged(options, into: old.keywords[path])
            }
            let change = DefinitionsChange(from: old, to: new)
            batch.definitions = change.isEmpty ? nil : change
        }
        return KeywordPlan(batch: batch)
    }

    /// Lightroom's options for a keyword the definitions may keep already: its synonyms join those kept, and
    /// its export options and whether it's a person replace theirs; a category or a private keyword stays one.
    static func merged(_ options: KeywordOptions, into kept: KeywordOptions?) -> KeywordOptions {
        guard var merged = kept else { return options }
        merged.synonyms = KeywordOptions.tidied(merged.synonyms + options.synonyms)
        merged.includeOnExport = options.includeOnExport
        merged.exportContainingKeywords = options.exportContainingKeywords
        merged.exportSynonyms = options.exportSynonyms
        merged.isPerson = options.isPerson
        return merged
    }

    /// The metadata batch of `part`: each photo's fields and collections, and the collections' definitions.
    func metadataPlan(
        _ part: [(id: Int64, values: LightroomValues)], definitions: [CollectionPath: CollectionOptions],
        title: String,
    ) async throws -> MetadataPlan {
        var edits: [Int64: [String: FieldEdit]] = [:]
        for (id, values) in part {
            let edit = values.edits
            if !edit.isEmpty {
                edits[id] = edit
            }
        }
        var batch = MetadataBatch(kind: .metadata, title: title)
        batch.photos = try await metadata.photos(Array(edits.keys), edits: edits, edit: [:], keepingUnchanged: false)
        if !definitions.isEmpty {
            let old = try await metadata.collections.definitions()
            var new = old
            for (path, options) in definitions where old.collections[path] == nil
                || options.kind == .smart && old.collections[path]?.kind == .smart {
                new.collections[path] = options
            }
            let change = CollectionsChange(from: old, to: new)
            batch.definitions = change.isEmpty ? nil : change
        }
        return MetadataPlan(batch: batch)
    }

    /// `body` in the turn the app gives batches, or at once.
    private func inTurn<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let turn else { return try await body() }
        let result = Mutex<Result<T, any Error>?>(nil)
        await turn {
            let outcome: Result<T, any Error>
            do {
                outcome = try await .success(body())
            } catch {
                outcome = .failure(error)
            }
            result.withLock { $0 = outcome }
        }
        guard let outcome = result.withLock({ $0 }) else { throw CancellationError() }
        return try outcome.get()
    }

    // MARK: - Undo

    /// The newest import not taken back.
    public func lastImport() throws -> LightroomImportRecord? {
        try records().last { !$0.undone && !$0.batches.isEmpty }
    }

    /// Takes back import `id` (the newest not taken back when nil): each of its batches, newest first, each
    /// keeping what changed since. Throws `partlyUndone` naming the batches the journals no longer have as
    /// they ran, once the others are taken back.
    @discardableResult
    public func undo(_ id: UUID? = nil, progress: (@Sendable (Progress) -> Void)? = nil) async throws
        -> LightroomImportRecord {
        try await settle()
        guard var record = try id.map({ id in try records().first { $0.id == id && !$0.undone } }) ?? lastImport()
        else { throw LightroomImportError.nothingToUndo }
        let keywordEntries = try await keywords.entries()
        let metadataEntries = try await metadata.entries()
        var failed: [String] = []
        for (number, batch) in record.batches.reversed().enumerated() {
            progress?(Progress(done: number, total: record.batches.count, part: number, parts: record.batches.count))
            switch batch.journal {
            case .keywords:
                guard let entry = keywordEntries.first(where: { $0.id == batch.id }) else {
                    failed.append("a keyword change no longer in the journal")
                    continue
                }
                guard entry.state == .finished else { continue }
                _ = try await inTurn { [keywords] in try await keywords.undo(batch.id) }
            case .metadata:
                guard let entry = metadataEntries.first(where: { $0.id == batch.id }) else {
                    failed.append("a metadata change no longer in the journal")
                    continue
                }
                guard entry.state == .finished else { continue }
                _ = try await inTurn { [metadata] in try await metadata.undo(batch.id) }
                live?.namesChanged()
            }
        }
        record.undone = true
        try save(record)
        if !failed.isEmpty {
            throw LightroomImportError.partlyUndone(failed)
        }
        return record
    }

    // MARK: - The record

    /// `Lightroom Imports.json` in the library's folder.
    public var recordURL: URL {
        paths.root.appending(path: "Lightroom Imports.json")
    }

    /// The imports the record keeps, oldest first.
    public func records() throws -> [LightroomImportRecord] {
        try Self.recordLock.withLock { _ in try load() }
    }

    private func load() throws -> [LightroomImportRecord] {
        let data: Data
        do {
            data = try Data(contentsOf: recordURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([LightroomImportRecord].self, from: data)
    }

    /// Keeps `record` in place of the one with its ID, or newest.
    private func save(_ record: LightroomImportRecord) throws {
        try Self.recordLock.withLock { _ in
            var records = (try? load()) ?? []
            if let place = records.firstIndex(where: { $0.id == record.id }) {
                records[place] = record
            } else {
                records.append(record)
            }
            records = Array(records.suffix(Self.kept))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            try encoder.encode(records).write(to: recordURL, options: .atomic)
        }
    }
}
