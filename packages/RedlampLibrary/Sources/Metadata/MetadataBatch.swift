import Foundation
import RedlampDocument
import RedlampEngineAPI

/// One change to photos' metadata, made as a batch with Undo (LIB-15, LIB-22, LIB-23, LIB-28): what it
/// does to each photo's fields (`edit`, or a photo's own `edits`), its photos with what the index showed
/// of those fields before, and what it changes in the collection definitions.
struct MetadataBatch: JournalBatch, Hashable {
    enum Kind: String, Sendable, Hashable, Codable {
        case metadata, preset, collections, stacks, undo
    }

    /// A photo of the batch: where it is, and the index's values of the batch's fields before.
    struct Photo: Sendable, Hashable, Codable {
        var id: Int64
        var path: String
        var index: MetadataValues
        /// What the batch does to this photo in place of `edit`: a stack's photos each get their place.
        var edits: [String: FieldEdit]?
        /// For an undo: the photo's fields before and after the batch it undoes.
        var undo: Undo?
    }

    struct Undo: Sendable, Hashable, Codable {
        var sidecarBefore: MetadataValues
        var sidecarAfter: MetadataValues
        var indexBefore: MetadataValues
        var indexAfter: MetadataValues
    }

    typealias Values = MetadataValues
    static let undoKind = Kind.undo

    var id = UUID()
    var kind: Kind
    var title: String
    var created = Date()
    var undoes: UUID?
    var edit: [String: FieldEdit] = [:]
    var definitions: CollectionsChange?
    var photos: [Photo] = []

    init(kind: Kind, title: String, undoes: UUID? = nil) {
        self.kind = kind
        self.title = title
        self.undoes = undoes
    }

    init(
        id: UUID, kind: Kind, title: String, created: Date, undoes: UUID?, edit: [String: FieldEdit],
        definitionsJSON: JSONValue?, photos: [Photo],
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.created = created
        self.undoes = undoes
        self.edit = edit
        definitions = definitionsJSON.map(CollectionsChange.init(json:))
        self.photos = photos
    }

    var definitionsJSON: JSONValue? {
        definitions?.json
    }

    /// The sidecar's keys the batch changes, for `photo`.
    func keys(of photo: Photo) -> Set<String> {
        if let undo = photo.undo {
            return Set(undo.sidecarAfter.keys).union(undo.indexAfter.keys)
        }
        return (photo.edits ?? edit).touched
    }

    /// The photo's fields in the index once the batch is done, from those it has now.
    func indexAfter(_ photo: Photo, current: MetadataValues) -> MetadataValues {
        if let undo = photo.undo {
            return undone(current, before: undo.indexBefore, after: undo.indexAfter)
        }
        return PhotoMetadata.canonical((photo.edits ?? edit).applied(to: current, fallback: current))
    }

    /// What the photo's sidecar holds of the fields once the batch is done, from what it holds now;
    /// `fallback` is what the index shows, for a field the sidecar holds none of.
    func sidecarAfter(_ photo: Photo, current: MetadataValues, fallback: MetadataValues) -> MetadataValues {
        if let undo = photo.undo {
            return undone(current, before: undo.sidecarBefore, after: undo.sidecarAfter)
        }
        return PhotoMetadata.canonical((photo.edits ?? edit).applied(to: current, fallback: fallback))
    }
}

/// What a batch changes in `Collections.json`: each place's options before and after (nil where the
/// definitions don't keep it), and the target collection where it changes.
struct CollectionsChange: Sendable, Hashable {
    var collections: [CollectionPath: Pair<CollectionOptions>] = [:]
    var target: Pair<CollectionPath>?

    struct Pair<Value: Sendable & Hashable>: Sendable, Hashable {
        var before: Value?
        var after: Value?
    }

    /// What makes `old` into `new`.
    init(from old: CollectionDefinitions, to new: CollectionDefinitions) {
        for path in Set(old.collections.keys).union(new.collections.keys)
            where old.collections[path] != new.collections[path] {
            collections[path] = Pair(before: old.collections[path], after: new.collections[path])
        }
        if old.target != new.target {
            target = Pair(before: old.target, after: new.target)
        }
    }

    var isEmpty: Bool {
        collections.isEmpty && target == nil
    }

    /// `definitions` as the change leaves them, or, `reversed`, as they were before it.
    func applied(to definitions: CollectionDefinitions, reversed: Bool = false) -> CollectionDefinitions {
        var changed = definitions
        for (path, options) in collections {
            changed.collections[path] = reversed ? options.before : options.after
        }
        if let target {
            changed.target = reversed ? target.before : target.after
        }
        return changed
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [:]
        object["collections"] = .object(Dictionary(uniqueKeysWithValues: collections.map { path, options in
            (path.text, .object([
                "before": options.before.map(\.json) ?? .null, "after": options.after.map(\.json) ?? .null,
            ]))
        }))
        if let target {
            object["target"] = .object([
                "before": target.before.map { .string($0.text) } ?? .null,
                "after": target.after.map { .string($0.text) } ?? .null,
            ])
        }
        return .object(object)
    }

    init(json: JSONValue) {
        guard case let .object(object) = json else { return }
        func options(_ value: JSONValue?) -> CollectionOptions? {
            guard let value, value != .null else { return nil }
            return CollectionOptions(json: value)
        }
        if case let .object(entries)? = object["collections"] {
            for (text, value) in entries {
                guard let path = CollectionPath(text), case let .object(pair) = value else { continue }
                collections[path] = Pair(before: options(pair["before"]), after: options(pair["after"]))
            }
        }
        if case let .object(pair)? = object["target"] {
            target = Pair(
                before: pair["before"]?.textValue.flatMap(CollectionPath.init),
                after: pair["after"]?.textValue.flatMap(CollectionPath.init),
            )
        }
    }
}

/// A change worked out but not made: what it would do, for a preview or `--dry-run`.
public struct MetadataPlan: Sendable, Hashable {
    /// What a photo's fields would be, by the sidecar's keys, as JSON.
    public struct Photo: Sendable, Hashable {
        public let id: Int64
        public let path: String
        public let before: [String: JSONValue]
        public let after: [String: JSONValue]
    }

    let batch: MetadataBatch

    public var id: UUID {
        batch.id
    }

    /// `Set the caption of 1,200 photos`.
    public var title: String {
        batch.title
    }

    /// The photos whose fields change, in ID order.
    public var photos: [Photo] {
        batch.photos.map { photo in
            Photo(
                id: photo.id,
                path: photo.path,
                before: photo.index,
                after: batch.indexAfter(photo, current: photo.index),
            )
        }
    }

    /// The collections and sets the definitions change, add or drop.
    public var definedCollections: [CollectionPath] {
        (batch.definitions?.collections.keys).map { $0.sorted() } ?? []
    }

    /// Whether running it would change nothing.
    public var isEmpty: Bool {
        batch.photos.isEmpty && (batch.definitions?.isEmpty ?? true)
    }
}

/// What running a batch did.
public struct MetadataOutcome: Sendable, Hashable {
    public var batch: UUID
    public var title: String
    public var state: BatchState
    /// Photos whose fields changed in the index.
    public var photos = 0
    /// Sidecars written.
    public var written = 0
    /// Photos whose sidecars this build can't write, left as they were, by path.
    public var skipped: [String] = []
    /// How long the journal, the definitions and index, and the sidecars took.
    public var journalTime = Duration.zero
    public var indexTime = Duration.zero
    public var sidecarTime = Duration.zero
    /// For a batch a forced quit interrupted: how many of its sidecars were written before it.
    public var recoveredFrom: Int?
}

/// The metadata changes' journal, in `LibraryPaths.root/Metadata Changes`, kept as the keyword changes'
/// is (`KeywordJournal`): each batch with its photos, written and synced before anything changes, and a
/// log of each photo's fields before and after as its sidecar is written. Changes to ratings, flags,
/// labels and marks, to IPTC Core's fields, to collections and to stacks all go in it, so Undo takes back
/// the last of them whatever it was.
public struct MetadataJournal: Sendable {
    public let folder: URL
    /// Batches kept for Undo; older ones that are over are removed.
    public static let kept = 50
    static let version = 1

    typealias Progress = BatchJournal<MetadataBatch>.Progress
    typealias Log = BatchJournal<MetadataBatch>.Log

    public init(paths: LibraryPaths) {
        folder = paths.root.appending(path: "Metadata Changes", directoryHint: .isDirectory)
    }

    private var batches: BatchJournal<MetadataBatch> {
        BatchJournal(folder: folder, version: Self.version)
    }

    func write(_ batch: MetadataBatch) throws {
        try batches.write(batch)
    }

    func log(_ id: UUID) throws -> Log {
        guard let log = try batches.log(id) else { throw MetadataError.noSuchBatch(id) }
        return log
    }

    /// Every batch, oldest first.
    public func entries() -> [BatchEntry] {
        batches.entries()
    }

    func load(_ id: UUID) throws -> (batch: MetadataBatch, progress: Progress) {
        do {
            return try batches.load(id)
        } catch {
            switch error {
            case .noSuchBatch: throw MetadataError.noSuchBatch(id)
            case .damaged: throw MetadataError.damagedJournal(id)
            case .newer: throw MetadataError.newerJournal(id)
            }
        }
    }

    func prune() {
        batches.prune(keeping: Self.kept)
    }
}

/// Why a metadata change couldn't be made.
public enum MetadataError: Error, Sendable, Hashable, CustomStringConvertible {
    case noSuchBatch(UUID)
    case damagedJournal(UUID)
    case newerJournal(UUID)
    /// A batch a forced quit interrupted waits for `LibraryMetadata.recover`.
    case unfinished(UUID)
    case nothingToUndo
    /// A preset file or a code replacement file that can't be read.
    case unreadableFile(String)
    case noSuchPreset(String)
    case collection(CollectionError)

    public var description: String {
        switch self {
        case let .noSuchBatch(id): "no metadata change \(id) in the journal"
        case let .damagedJournal(id): "the metadata change \(id) in the journal can't be read"
        case let .newerJournal(id): "the metadata change \(id) was written by a newer Redlamp"
        case let .unfinished(id): "a metadata change a forced quit interrupted (\(id)) is unfinished"
        case .nothingToUndo: "no metadata change to undo"
        case let .unreadableFile(name): "\(name) can't be read"
        case let .noSuchPreset(name): "there's no metadata preset “\(name)”"
        case let .collection(error): error.description
        }
    }
}
