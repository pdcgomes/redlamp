import Foundation
import RedlampDocument

public extension FileOperations {
    /// Recently Trashed: the photos the batches moved to the Trash that are still there, the newest
    /// batch's first, from the journal. Each is the file at the place the Trash gave it, with the file
    /// identifier, size and date the journal recorded: one emptied from the Trash, put back by Finder
    /// or replaced there isn't listed, nor one whose Trash is on a volume that's away. Each has its row
    /// as the batch took it out of the index, where it was and where it is, its batch, the sidecars
    /// and other apps' still in the Trash with it, and its pair among the photos listed.
    func trashed() async throws -> [TrashedPhoto] {
        let (journal, fileSystem) = (journal, fileSystem)
        return try await LibraryIndex.offCaller {
            try TrashSurvey(journal: journal, fileSystem: fileSystem).photos()
        }
    }

    /// Recently Trashed as `trashed()` lists it, then again each time that changes: after each batch,
    /// when a Trash folder holding its photos changes, as its volume's events say, and after
    /// `checkTrash()`. It ends when the stream is let go.
    func trashedUpdates() -> AsyncStream<[TrashedPhoto]> {
        trashWatch.follow { [weak self] in try await self?.trashed() ?? [] }
    }

    /// Looks at the Trash again for `trashedUpdates()`: when the app becomes active, say, or a volume
    /// comes back, which its events don't tell.
    func checkTrash() {
        trashWatch.changed()
    }

    /// The batch that puts photos `ids` of Recently Trashed back where they were, each with its pair
    /// and the sidecars and other apps' still in the Trash with it, making again a folder that's gone;
    /// a photo of a folder that went to the Trash whole brings back the folder, with everything in it,
    /// as Finder's Put Back does. The index gets each photo's row back as the batch took it out, with
    /// its ID, content key, keywords and collections, so no photo is read again and the store's
    /// thumbnails show at once. A name taken where a photo was stops the batch before it starts, as a
    /// collision does (`check`); what's no longer in the Trash is left out (`FileBatch.gone`). Undo
    /// moves them to the Trash again.
    func planPutBack(_ ids: [TrashedPhoto.ID]) async throws -> FileBatch {
        let wanted = Set(ids)
        return try await planPutBack { wanted.contains($0) }
    }

    /// The batch that puts back the photos of batch `id` still in the Trash, as `planPutBack(_:)` does.
    func planPutBack(batch id: UUID) async throws -> FileBatch {
        guard try await entries().contains(where: { $0.id == id }) else { throw FileOperationError.noSuchBatch(id) }
        return try await planPutBack { $0.batch == id }
    }
}

extension FileOperations {
    /// A batch's step.
    private struct StepKey: Hashable {
        var batch: UUID
        var step: Int
    }

    /// The batch that puts back the photos of Recently Trashed `chosen` picks, with their pairs; the
    /// photos it picks that aren't in the Trash any more are left out, in `gone`.
    private func planPutBack(choosing chosen: @escaping @Sendable (TrashedPhoto.ID) -> Bool) async throws
        -> FileBatch {
        let (journal, fileSystem) = (journal, fileSystem)
        let (steps, gone) = try await LibraryIndex.offCaller { () -> ([FileStep], [String]) in
            let survey = try TrashSurvey(journal: journal, fileSystem: fileSystem)
            let listed = survey.photos()
            var going = Set(listed.map(\.id).filter(chosen))
            for photo in listed where going.contains(photo.id) {
                going.formUnion(photo.pair)
            }
            let listedIDs = Set(listed.map(\.id))
            let stepsGoing = Set(going.map { StepKey(batch: $0.batch, step: $0.step) })
            var steps: [FileStep] = []
            var gone: [String] = []
            for batch in survey.batches {
                for step in batch.steps {
                    let id = { (photo: Int64) in
                        TrashedPhoto.ID(batch: batch.entry.id, step: step.index, photo: photo)
                    }
                    guard stepsGoing.contains(StepKey(batch: batch.entry.id, step: step.index)) else {
                        gone += step.step.removed.filter { chosen(id($0.photo.id)) }
                            .map { $0.folder + "/" + $0.photo.name }
                        continue
                    }
                    guard var back = step.step.puttingBack(places: step.places, presence: step.presence, gone: &gone)
                    else { continue }
                    back.removed = back.removed.filter { listedIDs.contains(id($0.photo.id)) }
                    steps.append(back)
                }
            }
            return (steps, gone)
        }
        guard !steps.isEmpty || gone.isEmpty else {
            throw FileOperationError.conflicts(gone.map { FileConflict(path: $0, reason: .gone) })
        }
        var batch = FileBatch(kind: .putBack, title: "", steps: steps)
        let count = batch.photoCount
        batch.title = "Put back \(count) photo\(count == 1 ? "" : "s")"
        batch.gone = gone
        return batch
    }
}
