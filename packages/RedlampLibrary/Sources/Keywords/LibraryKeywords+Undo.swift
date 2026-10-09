import Foundation
import RedlampDocument
import Synchronization

public extension LibraryKeywords {
    // MARK: - The journal

    /// Every batch in the journal, oldest first.
    func entries() async throws -> [KeywordJournal.Entry] {
        let journal = journal
        return try await LibraryIndex.offCaller { try journal.entries() }
    }

    /// The batches a forced quit left unfinished.
    func unfinishedEntries() async throws -> [KeywordJournal.Entry] {
        try await entries().filter(\.state.isUnfinished)
    }

    /// The batch Undo would undo: the newest that's finished, not an Undo itself, its own Undo not run.
    func lastUndoable() async throws -> KeywordJournal.Entry? {
        try await entries().last { !$0.isUndo && $0.state == .finished }
    }

    // MARK: - Undo

    /// What undoing batch `id` (the last undoable when nil) would do: each sidecar it wrote back as it
    /// was, unless the photo's keywords changed since, when what the batch added comes off and what it
    /// took off goes back; the index alike; and the definitions as they were.
    func planUndo(_ id: UUID? = nil) async throws -> KeywordPlan {
        var target = id
        if target == nil {
            target = try await lastUndoable()?.id
        }
        guard let id = target else { throw KeywordError.nothingToUndo }
        let journal = journal
        let (batch, logged) = try await LibraryIndex.offCaller { try journal.load(id) }
        guard logged.state == .finished, batch.kind != .undo else { throw KeywordError.nothingToUndo }
        let places = logged.written.filter { $0.value.before != $0.value.after }.keys.sorted()
        let ids = places.map { batch.photos[$0].id }
        let current = try await index.read { try $0.keywordPaths(ofPhotos: ids) }
        var undo = KeywordBatch(kind: .undo, title: "Undo \(batch.title)", undoes: batch.id)
        undo.definitions = batch.definitions?.reversed
        undo.photos = places.compactMap { place in
            guard let written = logged.written[place] else { return nil }
            let photo = batch.photos[place]
            return KeywordBatch.Photo(
                id: photo.id, path: photo.path, index: current[photo.id] ?? [],
                undo: KeywordBatch.Undo(
                    sidecarBefore: written.before, sidecarAfter: written.after, indexBefore: photo.index,
                    indexAfter: batch.indexAfter(photo, current: photo.index),
                ),
            )
        }
        return KeywordPlan(batch: undo)
    }

    /// Undoes batch `id`, the last undoable when nil, as a batch of its own.
    @discardableResult
    func undo(_ id: UUID? = nil) async throws -> KeywordOutcome {
        try await run(planUndo(id))
    }

    // MARK: - Recovery

    /// Finishes, or rolls back as `choice` says, every batch a forced quit left unfinished; one that
    /// was rolling back is rolled back. Returns what became of each.
    @discardableResult
    func recover(_ choice: FileRecovery = .finish) async throws -> [KeywordOutcome] {
        try await serially { [self] in
            var outcomes: [KeywordOutcome] = []
            for entry in try await unfinishedEntries() {
                let journal = journal
                let (batch, logged) = try await LibraryIndex.offCaller { try journal.load(entry.id) }
                var outcome = KeywordOutcome(batch: batch.id, title: batch.title, state: logged.state)
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
    internal func rollBack(_ batch: KeywordBatch, logged: KeywordJournal.Progress) async throws {
        let writing = index.photoWrites.begin(batch.photos.map(\.id))
        defer { writing.end() }
        let log = try journal.log(batch.id)
        try await LibraryIndex.offCaller { try log.state(.rollingBack) }
        if let change = batch.definitions {
            try await updateDefinitions { change.applied(to: $0, reversed: true) }
        }
        let store = try await SidecarStore(locator: LibrarySidecars(index: index, paths: paths).locator())
        let ids = batch.photos.map(\.id)
        let paths = try await index.read { try $0.photoPaths(ids) }
        let places = logged.written.sorted { $0.key < $1.key }.compactMap { place, change in
            change.before == change.after ? nil : paths[batch.photos[place].id].map { (place, change, path: $0) }
        }
        let restored = try await LibraryIndex.offCaller {
            let restored = Mutex<[Int64: [KeywordPath]]>([:])
            store.change(places.map { URL(fileURLWithPath: $0.path) }) { number, sidecar in
                guard var sidecar else { return .keep }
                let (place, change, _) = places[number]
                var metadata = sidecar.metadata ?? PhotoMetadata()
                let current = SidecarKeywords(keywords: metadata.keywords)
                let target = Self.rolledBack(current, batch.photos[place], change)
                guard target != current else { return .keep }
                metadata.keywords = target.keywords
                sidecar.metadata = metadata.isEmpty ? nil : metadata
                sidecar.modified = Date()
                return .saveOrRemove(sidecar)
            } done: { result in
                guard let sidecar = result.sidecar else { return }
                let (place, change, _) = places[result.index]
                let photo = batch.photos[place]
                if let keywords = Self.rolledBack(SidecarKeywords(keywords: sidecar.metadata?.keywords), photo, change)
                    .paths {
                    restored.withLock { $0[photo.id] = keywords }
                }
            }
            return restored.withLock { $0 }
        }
        let keywords = Dictionary(batch.photos.map { ($0.id, restored[$0.id] ?? $0.index) }) { first, _ in first }
        let existing = try await index.write { writer -> [Int64] in
            let found = try keywords.keys.filter { try writer.photo(id: $0) != nil }
            try writer.setKeywords(keywords.filter { found.contains($0.key) })
            return found
        }
        live?.photosChanged(existing)
        try await LibraryIndex.offCaller { try log.state(.rolledBack) }
    }

    /// What a sidecar holding `current` holds once `change`, the batch's to the photo, is put back:
    /// what it held before, or, when it changed since, that with what the batch added off and what it
    /// took off on.
    private static func rolledBack(
        _ current: SidecarKeywords, _ photo: KeywordBatch.Photo,
        _ change: (before: SidecarKeywords, after: SidecarKeywords),
    ) -> SidecarKeywords {
        guard current != change.after else { return change.before }
        return SidecarKeywords(keywords: undone(
            current.paths ?? photo.index, before: change.before.paths ?? photo.index,
            after: change.after.paths ?? photo.index,
        ).map(\.text))
    }
}

extension DefinitionsChange {
    /// The change that takes this one back.
    var reversed: DefinitionsChange {
        var reversed = self
        reversed.keywords = keywords.mapValues { ($0.after, $0.before) }
        reversed.sets = sets.map { ($0.after, $0.before) }
        reversed.activeSet = activeSet.map { ($0.after, $0.before) }
        return reversed
    }
}
