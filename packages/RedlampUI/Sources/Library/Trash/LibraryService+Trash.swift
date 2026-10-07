import Foundation
import RedlampLibrary

/// Recently Trashed through the library (LIB-26): its list, and Put Back as one of the library's batches.
extension LibraryService {
    /// Recently Trashed as the journal and the Trash have it, then again each time that changes; nil until
    /// the library is open.
    func trashedUpdates() -> AsyncStream<[TrashedPhoto]>? {
        core?.files.trashedUpdates()
    }

    /// Looks at the Trash again: when the app becomes active or a volume comes back, which its events
    /// don't say.
    func checkTrash() {
        core?.files.checkTrash()
    }

    /// Puts photos `ids` of Recently Trashed back where they were, with their pairs, sidecars and other
    /// apps' `.xmp`, or with `batch` every photo of that batch still in the Trash: one batch of the file
    /// operations, written to their journal and synced before anything moves, so a forced quit is finished
    /// or rolled back at the next launch and Undo moves the photos to the Trash again. The index gets each
    /// photo's row back as its batch took it out. It runs in the library's changes' turn, after what a
    /// forced quit cut short is settled.
    func putBack(_ ids: [TrashedPhoto.ID], batch: UUID? = nil) async throws -> FileOutcome {
        guard let core else { throw PutBackError.libraryClosed }
        let outcome = await core.change { () -> Result<FileOutcome, any Error> in
            do {
                let plan = if let batch {
                    try await core.files.planPutBack(batch: batch)
                } else {
                    try await core.files.planPutBack(ids)
                }
                return try await .success(core.files.run(plan))
            } catch {
                return .failure(error)
            }
        }
        return try outcome.get()
    }

    /// Whether `url` is in a Trash: the home folder's, or a volume's. No photo's sidecar is written there.
    nonisolated static func isInTrash(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        return components.contains(".Trash") || components.contains(".Trashes")
    }

    /// `written` with the photos it leaves to their own saves that are in the Trash left as they are: a
    /// sidecar written beside a photo there wouldn't go back with it, and one rewritten there would stay.
    nonisolated static func leavingTrash(_ written: CullingWritten) -> CullingWritten {
        let trashed = written.unindexed.filter(isInTrash)
        guard !trashed.isEmpty else { return written }
        var written = written
        written.unindexed.removeAll(where: isInTrash)
        for photo in trashed {
            written.unwritten.append(photo)
            written.reasons[photo] = "it's in the Trash"
        }
        return written
    }

    enum PutBackError: Error {
        case libraryClosed
        case notInLibrary
    }

    // MARK: - For the regression suite

    /// Moves `photos`, which the library has indexed, to the Trash as one batch, as `redlamp library trash`
    /// does; returns the batch.
    @_spi(Harness) @discardableResult public func moveToTrash(_ photos: [URL]) async throws -> UUID {
        guard let core else { throw PutBackError.libraryClosed }
        let ids = await Self.indexIDs(of: photos, in: core.index)
        guard ids.count == photos.count else { throw PutBackError.notInLibrary }
        let outcome = await core.change { () -> Result<FileOutcome, any Error> in
            do {
                return try await .success(core.files.run(core.files.planTrash(photos: Array(ids.values))))
            } catch {
                return .failure(error)
            }
        }
        return try outcome.get().batch
    }

    /// Where each photo Recently Trashed lists is in the Trash, with the files that went with it.
    @_spi(Harness) public func trashedPlaces() async -> [String] {
        let photos = await (try? core?.files.trashed()) ?? []
        return photos.flatMap { [$0.place] + $0.files.map(\.place) }
    }
}
