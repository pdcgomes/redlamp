import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization

public extension LibraryMetadata {
    // MARK: - The journal

    /// Every batch in the journal, oldest first.
    func entries() async throws -> [BatchEntry] {
        let journal = journal
        return try await LibraryIndex.offCaller { journal.entries() }
    }

    /// The batches a forced quit left unfinished.
    func unfinishedEntries() async throws -> [BatchEntry] {
        try await entries().filter(\.state.isUnfinished)
    }

    /// The batch Undo would undo: the newest that's finished, not an Undo itself, its own Undo not run.
    func lastUndoable() async throws -> BatchEntry? {
        try await entries().last { !$0.isUndo && $0.state == .finished }
    }

    // MARK: - Undo

    /// What undoing batch `id` (the last undoable when nil) would do: each sidecar it wrote back as it
    /// was, unless a field changed since, which then keeps its change (a list of collections loses what
    /// the batch added and gets back what it took off); the index alike; and the definitions as they were.
    func planUndo(_ id: UUID? = nil) async throws -> MetadataPlan {
        var target = id
        if target == nil {
            target = try await lastUndoable()?.id
        }
        guard let id = target else { throw MetadataError.nothingToUndo }
        let journal = journal
        let (batch, logged) = try await LibraryIndex.offCaller { try journal.load(id) }
        guard logged.state == .finished, batch.kind != .undo else { throw MetadataError.nothingToUndo }
        var undo = MetadataBatch(kind: .undo, title: "Undo \(batch.title)", undoes: batch.id)
        undo.definitions = batch.definitions?.reversed
        let places = batch.photos.indices.filter { place in
            logged.written[place].map { $0.before != $0.after } ?? false
                || batch.indexAfter(batch.photos[place], current: batch.photos[place].index) != batch.photos[place]
                .index
        }
        let ids = places.map { batch.photos[$0].id }
        let keys = places.reduce(into: Set<String>()) { $0.formUnion(batch.keys(of: batch.photos[$1])) }
        let current = try await index.read { try $0.metadataValues(ofPhotos: ids, keys: keys) }
        undo.photos = places.compactMap { place in
            let photo = batch.photos[place]
            let photoKeys = batch.keys(of: photo)
            let written = logged.written[place]
            let indexAfter = batch.indexAfter(photo, current: photo.index)
            return MetadataBatch.Photo(
                id: photo.id, path: photo.path,
                index: current[photo.id]
                    .map { PhotoMetadata.canonical($0.values.filter { photoKeys.contains($0.key) }) }
                    ?? [:],
                undo: MetadataBatch.Undo(
                    sidecarBefore: written?.before ?? [:], sidecarAfter: written?.after ?? [:],
                    indexBefore: photo.index, indexAfter: indexAfter, othersBefore: photo.others,
                ),
            )
        }
        return MetadataPlan(batch: undo)
    }

    /// Undoes batch `id`, the last undoable when nil, as a batch of its own.
    @discardableResult
    func undo(_ id: UUID? = nil) async throws -> MetadataOutcome {
        try await run(planUndo(id))
    }

    // MARK: - Recovery

    /// Finishes, or rolls back as `choice` says, every batch a forced quit left unfinished; one that
    /// was rolling back is rolled back. Returns what became of each.
    @discardableResult
    func recover(_ choice: FileRecovery = .finish) async throws -> [MetadataOutcome] {
        try await serially { [self] in
            var outcomes: [MetadataOutcome] = []
            for entry in try await unfinishedEntries() {
                let journal = journal
                let (batch, logged) = try await LibraryIndex.offCaller { try journal.load(entry.id) }
                var outcome = MetadataOutcome(batch: batch.id, title: batch.title, state: logged.state)
                outcome.recoveredFrom = logged.done
                if choice == .finish, logged.state != .rollingBack {
                    outcome = try await forward(batch, progress: logged, outcome: outcome, report: nil)
                } else {
                    try await rollBack(batch, logged: logged)
                    outcome.state = .rolledBack
                }
                outcomes.append(outcome)
            }
            return outcomes
        }
    }

    /// Puts back what `batch` did, as its log says: the sidecars it wrote (keeping what changed in
    /// them since), the index of every one of its photos, and the definitions. Running it again after
    /// a forced quit changes nothing it already put back.
    internal func rollBack(_ batch: MetadataBatch, logged: MetadataJournal.Progress) async throws {
        let log = try journal.log(batch.id)
        try await LibraryIndex.offCaller { try log.state(.rollingBack) }
        if let change = batch.definitions {
            try await collections.updateDefinitions { change.applied(to: $0, reversed: true) }
        }
        let store = try await SidecarStore(locator: LibrarySidecars(index: index, paths: paths).locator())
        let ids = batch.photos.map(\.id)
        let paths = try await index.read { try $0.photoPaths(ids) }
        let places = logged.written.sorted { $0.key < $1.key }.compactMap { place, change in
            change.before == change.after ? nil : paths[batch.photos[place].id].map { (place, change, path: $0) }
        }
        try await LibraryIndex.offCaller {
            store.change(places.map { URL(fileURLWithPath: $0.path) }) { number, sidecar in
                guard var sidecar else { return .keep }
                let (_, change, _) = places[number]
                let metadata = sidecar.metadata ?? PhotoMetadata()
                let current = PhotoMetadata.canonical(metadata.values(change.after.keys))
                let target = undone(current, before: change.before, after: change.after)
                guard target != current, let restored = metadata.setting(target) else { return .keep }
                sidecar.metadata = restored.isEmpty ? nil : restored
                sidecar.modified = Date()
                return .saveOrRemove(sidecar)
            } done: { _ in }
        }
        let existing = try await index.write { writer -> [Int64] in
            var found: [Int64] = []
            for photo in batch.photos where try writer.photo(id: photo.id) != nil {
                try writer.setMetadata(photo.index, forPhoto: photo.id, others: photo.others)
                found.append(photo.id)
            }
            return found
        }
        live?.photosChanged(existing)
        try await LibraryIndex.offCaller { try log.state(.rolledBack) }
    }
}

extension CollectionsChange {
    /// The change that takes this one back.
    var reversed: CollectionsChange {
        var reversed = self
        reversed.collections = collections.mapValues { Pair(before: $0.after, after: $0.before) }
        reversed.target = target.map { Pair(before: $0.after, after: $0.before) }
        return reversed
    }
}
