import Foundation
import RedlampLibrary

/// Put Back on Library's Undo and Redo (LIB-26): ⌘Z after a Put Back moves its photos to the Trash again, through
/// its batch's Undo in the file operations' journal, and ⇧⌘Z puts back what that Undo moved there, as a Put Back
/// of its own; in Recently Trashed and in the folders alike.
///
/// Library's other changes, culling's, the panels' and the renames and moves, each keep an Undo of their own. A Put
/// Back is the newest change while the newest of each of them is the one it was when the Put Back was asked for,
/// and the newest taken back while the newest each of them took back is the one it was then; a change made since
/// it was taken back ends its Redo, as a new change ends theirs, and a new Put Back ends theirs.
extension EditorModel {
    /// Put Backs Undo can take back.
    static let putBackUndoLimit = 20

    var putBackSteps: PutBackSteps {
        if let steps = Self.putBackSteps.object(forKey: self) {
            return steps
        }
        let steps = PutBackSteps()
        Self.putBackSteps.setObject(steps, forKey: self)
        return steps
    }

    private static let putBackSteps = NSMapTable<EditorModel, PutBackSteps>.weakToStrongObjects()

    /// The newest change on each of Library's other Undos.
    private var newestChanges: LibraryNewest {
        LibraryNewest(
            culling: cullingUndo.last.map(ObjectIdentifier.init),
            panels: libraryPanels.undoSteps.last.map(ObjectIdentifier.init),
            files: fileSteps.undo.last.map(ObjectIdentifier.init),
        )
    }

    /// The newest change on each of Library's other Redos.
    private var newestUndone: LibraryNewest {
        LibraryNewest(
            culling: cullingRedo.last.map(ObjectIdentifier.init),
            panels: libraryPanels.redoSteps.last.map(ObjectIdentifier.init),
            files: fileSteps.redo.last.map(ObjectIdentifier.init),
        )
    }

    /// Every change on Library's other Undos.
    private var changesMade: [ObjectIdentifier] {
        cullingUndo.map(ObjectIdentifier.init) + libraryPanels.undoSteps.map(ObjectIdentifier.init)
            + fileSteps.undo.map(ObjectIdentifier.init)
    }

    /// Library's Undo takes back the latest Put Back: nothing was changed since it was asked for.
    var putBackUndoIsNewest: Bool {
        guard module == .library, let step = putBackSteps.undo.last else { return false }
        return newestChanges == step.newest
    }

    /// Library's Redo makes again the Put Back taken back last: nothing was taken back after it. A change made
    /// since it was taken back ends every Put Back's Redo.
    var putBackRedoIsNewest: Bool {
        guard module == .library, let step = putBackSteps.redo.last else { return false }
        guard changesMade.allSatisfy(step.known.contains) else {
            putBackSteps.redo.removeAll()
            return false
        }
        return newestUndone == step.newestUndone
    }

    /// Runs `putBack`, a Put Back's batch, after the Put Backs and their Undos asked for before it, and puts it on
    /// Undo once it has run, ending every Redo; one that stops has changed nothing, and Redo stays. `originals` are
    /// where its photos go back to.
    func makePutBack(
        originals: [URL], _ putBack: @escaping @MainActor () async throws -> FileOutcome,
    ) -> Task<Void, Never> {
        let newest = newestChanges
        return putBackSteps.enqueue { [weak self] in
            do {
                let outcome = try await putBack()
                guard let self else { return }
                endEveryRedo()
                library.countFolders()
                if !outcome.gone.isEmpty {
                    activity.record(
                        .error,
                        "\(outcome.title): \(outcome.gone.count) of its files weren't in the Trash any more",
                    )
                }
                guard outcome.photos > 0 else { return }
                let step = PutBackStep(title: outcome.title, photos: originals, batch: outcome.batch, newest: newest)
                putBackSteps.undo.append(step)
                if putBackSteps.undo.count > Self.putBackUndoLimit {
                    putBackSteps.undo.removeFirst(putBackSteps.undo.count - Self.putBackUndoLimit)
                }
            } catch {
                self?.putBackFailed(error)
            }
        }
    }

    /// ⌘Z: the latest Put Back's photos to the Trash again, through its batch's Undo.
    @discardableResult
    func undoPutBack() -> Bool {
        guard putBackUndoIsNewest, let step = putBackSteps.undo.popLast(), let service = library.service else {
            return false
        }
        step.newestUndone = newestUndone
        step.known = Set(changesMade)
        putBackSteps.redo.append(step)
        activity.record(.action, "Undo \(step.title)")
        if let selection, step.photos.contains(selection) {
            saveNow()
        }
        putBackSteps.enqueue { [weak self] in
            guard let self else { return }
            await waitForSaves(of: step.photos)
            do {
                let outcome = try await service.undoPutBack(step.batch)
                step.undone = outcome.batch
                library.countFolders()
            } catch {
                activity.record(.error, "Undo \(step.title) wasn't done: \(LibraryService.describe(error))")
                putBackSteps.redo.removeAll { $0 === step }
                if Self.mayRetry(error) {
                    putBackSteps.undo.append(step)
                }
            }
        }
        return true
    }

    /// ⇧⌘Z: the photos the latest Put Back's Undo moved to the Trash put back again, as a Put Back of their own.
    @discardableResult
    func redoPutBack() -> Bool {
        guard putBackRedoIsNewest, let step = putBackSteps.redo.popLast(), let service = library.service else {
            return false
        }
        step.newest = newestChanges
        putBackSteps.undo.append(step)
        activity.record(.action, "Redo \(step.title)")
        putBackSteps.enqueue { [weak self] in
            guard let self else { return }
            do {
                guard let undone = step.undone else { throw FileOperationError.nothingToUndo }
                let outcome = try await service.putBack([], batch: undone)
                step.batch = outcome.batch
                library.countFolders()
            } catch {
                activity.record(.error, "Redo \(step.title) wasn't done: \(LibraryService.describe(error))")
                putBackSteps.undo.removeAll { $0 === step }
                if Self.mayRetry(error) {
                    putBackSteps.redo.append(step)
                }
            }
        }
        return true
    }

    /// Whether a Put Back's Undo or Redo that stopped with `error` may go through when it's asked for again: once
    /// what a forced quit cut short is settled, or after a move that failed and was rolled back. One whose photos
    /// aren't where it left them, or whose batch the journal no longer has, never will.
    private static func mayRetry(_ error: any Error) -> Bool {
        switch error as? FileOperationError {
        case .unfinished, .failed, .stuck: true
        default: false
        }
    }

    /// A new change ends Redo: Put Back's, culling's, the panels' and the file steps'.
    private func endEveryRedo() {
        putBackSteps.redo.removeAll()
        if !cullingRedo.isEmpty {
            cullingRedo.removeAll()
        }
        if !libraryPanels.redoSteps.isEmpty {
            libraryPanels.redoSteps.removeAll()
        }
        fileSteps.redo.removeAll()
    }

    /// Returns once the saves asked for any of `photos` before the call are on disk, so what goes to the Trash
    /// goes as they leave it.
    private func waitForSaves(of photos: [URL]) async {
        let saves = saves
        for photo in await Task.detached(priority: .userInitiated, operation: { saves.pending(photos) }).value {
            await saves.wait(for: photo)
        }
    }
}

/// The Put Backs Library's Undo and Redo take back and make again, run one at a time in the order they're asked for.
@MainActor
final class PutBackSteps {
    var undo: [PutBackStep] = []
    var redo: [PutBackStep] = []
    private var tail: Task<Void, Never>?

    /// Runs `body` once those asked for before it are done.
    @discardableResult
    func enqueue(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        tail = task
        return task
    }

    /// Returns once every Put Back, Undo and Redo asked for is done.
    func made() async {
        while let tail {
            await tail.value
            if self.tail == tail {
                break
            }
        }
    }
}

/// One Put Back, as Undo takes it back and Redo makes it again.
@MainActor
final class PutBackStep {
    /// As the journal and the activity log name it: "Put back 2 photos".
    let title: String
    /// Where its photos were put back, whose saves Undo waits for.
    let photos: [URL]
    /// The batch that put them back last, which Undo takes back.
    var batch: UUID
    /// The Undo that moved them to the Trash again last, whose photos Redo puts back.
    var undone: UUID?
    /// The newest change of Library's other Undos when it was asked for or made again.
    var newest: LibraryNewest
    /// When it was taken back: the newest change of Library's other Redos, and every change on their Undos.
    var newestUndone = LibraryNewest()
    var known: Set<ObjectIdentifier> = []

    init(title: String, photos: [URL], batch: UUID, newest: LibraryNewest) {
        self.title = title
        self.photos = photos
        self.batch = batch
        self.newest = newest
    }
}

/// The newest change on each of Library's other Undos, or Redos: culling's, the panels' and the file steps'.
struct LibraryNewest: Equatable {
    var culling: ObjectIdentifier?
    var panels: ObjectIdentifier?
    var files: ObjectIdentifier?
}
