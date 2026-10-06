import Foundation
import RedlampEngineAPI

/// The keyword changes' journal, in `LibraryPaths.root/Keyword Changes` on the Mac's own disk, as the
/// file operations keep theirs (LIB-26): each batch a file of JSON lines, its summary and then a
/// photo a line with its keywords in the index, written to a hidden name, synced (`F_FULLFSYNC`) and
/// renamed into place before anything changes. Its log gets a line as each photo's sidecar is
/// written, with what the sidecar held before and after, and one at each change of state, written
/// straight to the file: a forced quit loses none of them, and the next launch finishes the batch or
/// rolls it back. Undo reads the log. Metadata changes keep a journal of the same kind
/// (`MetadataJournal`).
public struct KeywordJournal: Sendable {
    public let folder: URL
    /// Batches kept for Undo; older ones that are over are removed.
    public static let kept = 50
    static let version = 1

    public typealias State = BatchState
    public typealias Entry = BatchEntry
    typealias Progress = BatchJournal<KeywordBatch>.Progress
    typealias Log = BatchJournal<KeywordBatch>.Log

    public init(paths: LibraryPaths) {
        folder = paths.root.appending(path: "Keyword Changes", directoryHint: .isDirectory)
    }

    private var batches: BatchJournal<KeywordBatch> {
        BatchJournal(folder: folder, version: Self.version)
    }

    /// Writes `batch` and syncs it, with an empty log.
    func write(_ batch: KeywordBatch) throws {
        try batches.write(batch)
    }

    /// Opens `batch`'s log to add to it.
    func log(_ id: UUID) throws -> Log {
        guard let log = try batches.log(id) else { throw KeywordError.noSuchBatch(id) }
        return log
    }

    /// Every batch, oldest first.
    public func entries() throws -> [Entry] {
        batches.entries()
    }

    /// The batch, and what its log says.
    func load(_ id: UUID) throws -> (batch: KeywordBatch, progress: Progress) {
        do {
            return try batches.load(id)
        } catch {
            switch error {
            case .noSuchBatch: throw KeywordError.noSuchBatch(id)
            case .damaged: throw KeywordError.damagedJournal(id)
            case .newer: throw KeywordError.newerJournal(id)
            }
        }
    }

    /// Removes all but the `kept` newest batches that are over, and what interrupted writes left.
    func prune() {
        batches.prune(keeping: Self.kept)
    }
}

extension KeywordBatch: JournalBatch {
    typealias Values = SidecarKeywords

    static let undoKind = Kind.undo

    var definitionsJSON: JSONValue? {
        definitions?.json
    }

    init(
        id: UUID, kind: Kind, title: String, created: Date, undoes: UUID?, edit: KeywordEdit,
        definitionsJSON: JSONValue?, photos: [Photo],
    ) {
        self.init(
            id: id, kind: kind, title: title, created: created, undoes: undoes, edit: edit,
            definitions: definitionsJSON.map(DefinitionsChange.init(json:)), photos: photos,
        )
    }
}
