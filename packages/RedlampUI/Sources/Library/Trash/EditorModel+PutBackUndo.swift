import Foundation
import RedlampLibrary

/// Put Back on Library's Undo and Redo (LIB-26): ⌘Z after a Put Back moves its photos to the Trash again, through
/// its batch's Undo in the file operations' journal, and ⇧⌘Z puts back what that Undo moved there, as a Put Back
/// of its own; in Recently Trashed and in the folders alike.
///
/// A Put Back takes its turn among Library's changes as it's asked for (`EditorModel+LibraryUndo`): ⌘Z takes it
/// back when it's the newest of them, once its batch is done, and a change of any kind ends its Redo, as a Put
/// Back ends theirs. One that stops, or puts nothing back, leaves Undo.
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

    /// Library's Undo takes back the latest Put Back: it's the library's newest change.
    var putBackUndoIsNewest: Bool {
        module == .library && libraryUndoKind == .putBack
    }

    /// Library's Redo makes again the Put Back taken back last: it's the library's change taken back last.
    var putBackRedoIsNewest: Bool {
        module == .library && libraryRedoKind == .putBack
    }

    /// Puts a Put Back on Undo, newest, ending every Redo, and runs `putBack`, its batch, after the Put Backs and
    /// their Undos asked for before it; one that stops, or puts nothing back, leaves Undo. `originals` are where
    /// its photos go back to.
    func makePutBack(
        originals: [URL], _ putBack: @escaping @MainActor () async throws -> FileOutcome,
    ) -> Task<Void, Never> {
        let step = PutBackStep(photos: originals)
        step.turn = nextLibraryTurn()
        putBackSteps.undo.append(step)
        if putBackSteps.undo.count > Self.putBackUndoLimit {
            putBackSteps.undo.removeFirst(putBackSteps.undo.count - Self.putBackUndoLimit)
        }
        endLibraryRedo()
        return putBackSteps.enqueue { [weak self] in
            do {
                let outcome = try await putBack()
                guard let self else { return }
                library.countFolders()
                if !outcome.gone.isEmpty {
                    activity.record(
                        .error,
                        "\(outcome.title): \(outcome.gone.count) of its files weren't in the Trash any more",
                    )
                }
                guard outcome.photos > 0 else {
                    putBackSteps.undo.removeAll { $0 === step }
                    return
                }
                step.title = outcome.title
                step.batch = outcome.batch
            } catch {
                self?.putBackSteps.undo.removeAll { $0 === step }
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
        let made = step.turn
        step.turn = nextLibraryTurn()
        putBackSteps.redo.append(step)
        activity.record(.action, "Undo \(step.title)")
        if let selection, step.photos.contains(selection) {
            saveNow()
        }
        putBackSteps.enqueue { [weak self] in
            guard let self else { return }
            guard let batch = step.batch else {
                // It put nothing back.
                putBackSteps.redo.removeAll { $0 === step }
                return
            }
            await waitForSaves(of: step.photos)
            do {
                let outcome = try await service.undoPutBack(batch)
                step.undone = outcome.batch
                library.countFolders()
            } catch {
                activity.record(.error, "Undo \(step.title) wasn't done: \(LibraryService.describe(error))")
                // Back on Undo in its place when it may go through later, unless a change made since ended its Redo.
                let undone = putBackSteps.redo.contains { $0 === step }
                putBackSteps.redo.removeAll { $0 === step }
                if Self.mayRetry(error), undone {
                    step.turn = made
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
        let undone = step.turn
        step.turn = nextLibraryTurn()
        putBackSteps.undo.append(step)
        activity.record(.action, "Redo \(step.title)")
        putBackSteps.enqueue { [weak self] in
            guard let self else { return }
            do {
                guard let trashed = step.undone else { throw FileOperationError.nothingToUndo }
                let outcome = try await service.putBack([], batch: trashed)
                step.batch = outcome.batch
                library.countFolders()
            } catch {
                activity.record(.error, "Redo \(step.title) wasn't done: \(LibraryService.describe(error))")
                // Back on Redo when it may go through later and is still the newest change; off Undo either way.
                let newest = putBackSteps.undo.last === step && libraryUndoKind == .putBack
                putBackSteps.undo.removeAll { $0 === step }
                if Self.mayRetry(error), newest {
                    step.turn = undone
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
    /// As the journal and the activity log name it, "Put back 2 photos", once its batch has run.
    var title = "Put Back"
    /// Where its photos were put back, whose saves Undo waits for.
    let photos: [URL]
    /// The batch that put them back last, which Undo takes back; nil until it has run.
    var batch: UUID?
    /// The Undo that moved them to the Trash again last, whose photos Redo puts back.
    var undone: UUID?
    /// Its turn in Library's Undo and Redo (`EditorModel+LibraryUndo`).
    var turn = 0

    init(photos: [URL]) {
        self.photos = photos
    }
}
