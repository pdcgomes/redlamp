import Foundation
import RedlampLibrary

/// Library Health's changes on Library's ⌘Z and ⇧⌘Z (LIB-40): a batch the sheet confirmed, taken back through its
/// Undo in the file operations' journal and made again from the check's findings for the same photos, checked again
/// as the first was; and Keep Anyway and List Again, each taking back what the other makes.
///
/// Library's other changes, culling's, the panels', the renames and moves and the Put Backs, each keep an Undo of
/// their own. A change of Library Health's is the newest while the newest of each of them is the one it was when the
/// change was made, and the newest taken back while the newest each of them took back is the one it was then; a
/// change made since it was taken back ends its Redo, and one of Library Health's ends theirs. Its keys come before
/// theirs, so the newest change is always taken back first.
extension EditorModel {
    /// Library Health's changes Undo can take back.
    static let healthUndoLimit = 20

    var healthSteps: HealthSteps {
        if let steps = Self.healthSteps.object(forKey: self) {
            return steps
        }
        let steps = HealthSteps()
        Self.healthSteps.setObject(steps, forKey: self)
        return steps
    }

    private static let healthSteps = NSMapTable<EditorModel, HealthSteps>.weakToStrongObjects()

    /// The newest change on each of Library's other Undos.
    private var newestOtherChanges: [ObjectIdentifier?] {
        [
            cullingUndo.last.map(ObjectIdentifier.init), libraryPanels.undoSteps.last.map(ObjectIdentifier.init),
            fileSteps.undo.last.map(ObjectIdentifier.init), putBackSteps.undo.last.map(ObjectIdentifier.init),
        ]
    }

    /// The newest change on each of Library's other Redos.
    private var newestOtherUndone: [ObjectIdentifier?] {
        [
            cullingRedo.last.map(ObjectIdentifier.init), libraryPanels.redoSteps.last.map(ObjectIdentifier.init),
            fileSteps.redo.last.map(ObjectIdentifier.init), putBackSteps.redo.last.map(ObjectIdentifier.init),
        ]
    }

    /// Every change on Library's other Undos.
    private var otherChangesMade: [ObjectIdentifier] {
        cullingUndo.map(ObjectIdentifier.init) + libraryPanels.undoSteps.map(ObjectIdentifier.init)
            + fileSteps.undo.map(ObjectIdentifier.init) + putBackSteps.undo.map(ObjectIdentifier.init)
    }

    /// Library's Undo takes back Library Health's latest change: nothing was changed since it was made.
    var healthUndoIsNewest: Bool {
        guard module == .library, let step = healthSteps.undo.last else { return false }
        return step.newest == newestOtherChanges
    }

    /// Library's Redo makes again Library Health's change taken back last: nothing was taken back after it. A change
    /// made since it was taken back ends every Redo of Library Health's.
    var healthRedoIsNewest: Bool {
        guard module == .library, let step = healthSteps.redo.last else { return false }
        guard otherChangesMade.allSatisfy(step.known.contains) else {
            healthSteps.redo.removeAll()
            return false
        }
        return step.newestUndone == newestOtherUndone
    }

    /// Puts `step`, just made, on Undo, newest, ending every Redo.
    func pushHealthStep(_ step: HealthStep) {
        step.newest = newestOtherChanges
        healthSteps.undo.append(step)
        if healthSteps.undo.count > Self.healthUndoLimit {
            healthSteps.undo.removeFirst(healthSteps.undo.count - Self.healthUndoLimit)
        }
        healthSteps.redo.removeAll()
        putBackSteps.redo.removeAll()
        if !cullingRedo.isEmpty {
            cullingRedo.removeAll()
        }
        if !libraryPanels.redoSteps.isEmpty {
            libraryPanels.redoSteps.removeAll()
        }
        fileSteps.redo.removeAll()
    }

    /// ⌘Z: Library Health's latest change taken back, in the background.
    @discardableResult
    func undoHealth() -> Bool {
        guard healthUndoIsNewest, let core = library.service?.core, let step = healthSteps.undo.popLast() else {
            return false
        }
        step.newestUndone = newestOtherUndone
        step.known = Set(otherChangesMade)
        healthSteps.redo.append(step)
        activity.record(.action, "Undo \(step.title)")
        let health = healthProposals.library(core)
        healthSteps.enqueue { [weak self] in
            guard let self else { return }
            do {
                try await take(step, back: true, core: core, health: health)
            } catch {
                activity.record(.error, "Undo \(step.title) wasn't done: \(Self.healthFailure(error))")
                if let place = healthSteps.redo.lastIndex(where: { $0 === step }) {
                    healthSteps.redo.remove(at: place)
                    if Self.mayRetryHealth(error) {
                        healthSteps.undo.append(step)
                    }
                }
            }
        }
        return true
    }

    /// ⇧⌘Z: Library Health's change taken back last made again, in the background.
    @discardableResult
    func redoHealth() -> Bool {
        guard healthRedoIsNewest, let core = library.service?.core, let step = healthSteps.redo.popLast() else {
            return false
        }
        step.newest = newestOtherChanges
        healthSteps.undo.append(step)
        activity.record(.action, "Redo \(step.title)")
        let health = healthProposals.library(core)
        healthSteps.enqueue { [weak self] in
            guard let self else { return }
            do {
                try await take(step, back: false, core: core, health: health)
            } catch {
                activity.record(.error, "Redo \(step.title) wasn't done: \(Self.healthFailure(error))")
                if let place = healthSteps.undo.lastIndex(where: { $0 === step }) {
                    healthSteps.undo.remove(at: place)
                    if Self.mayRetryHealth(error) {
                        healthSteps.redo.append(step)
                    }
                }
            }
        }
        return true
    }

    /// Takes `step` back, or makes it again, in the library's changes' turn.
    private func take(_ step: HealthStep, back: Bool, core: LibraryCore, health: LibraryHealth) async throws {
        switch step.kind {
        case let .batch(check, photos, chosen):
            if back {
                guard let batch = step.batch else { throw FileOperationError.nothingToUndo }
                _ = try await core.change { () -> Result<FileOutcome, any Error> in
                    do {
                        return try await .success(core.files.run(core.files.planUndo(batch)))
                    } catch {
                        return .failure(error)
                    }
                }.get()
            } else {
                let wanted = Set(photos)
                step.batch = try await core.change { () -> Result<UUID, any Error> in
                    do {
                        let found = try await health.findings(check)
                        let again = HealthFindings(check: check, findings: found.findings.filter {
                            wanted.contains($0.photo)
                        })
                        return try await .success(health.run(health.plan(again, choosing: chosen)).batch)
                    } catch {
                        return .failure(error)
                    }
                }.get()
            }
            library.countFolders()
        case let .keptAnyway(entries), let .listedAgain(entries):
            let keeping = if case .keptAnyway = step.kind {
                !back
            } else {
                back
            }
            _ = try await core.change { () -> Result<Void, any Error> in
                do {
                    if keeping {
                        try await health.keepAnyway(entries)
                    } else {
                        try await health.takeBack(entries)
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.get()
        }
    }

    /// Why Library Health's Undo or Redo stopped, in words.
    private static func healthFailure(_ error: any Error) -> String {
        error is HealthError ? HealthWords.failure(error) : LibraryService.describe(error)
    }

    /// Whether an Undo or Redo that stopped with `error` may go through when it's asked for again: once what a forced
    /// quit cut short is settled, or after a move that failed and was rolled back.
    private static func mayRetryHealth(_ error: any Error) -> Bool {
        switch error as? FileOperationError {
        case .unfinished, .failed, .stuck: true
        default: false
        }
    }

    // MARK: - Keys, menus and the palette

    /// Library Health's actions, and Library's Undo and Redo when its change is the newest; nil for every other action.
    func performHealthShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .acceptHealthProposals: acceptHealthProposals()
        case .keepAnyway: keepAnyway()
        case .listAgain: listAgain()
        case .undo where healthUndoIsNewest: undoHealth()
        case .redo where healthRedoIsNewest: redoHealth()
        default: nil
        }
    }

    /// Whether `performHealthShortcut` would do something now; nil for the actions it leaves to others.
    func canPerformHealthShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .acceptHealthProposals: canAcceptHealthProposals
        case .keepAnyway: canKeepAnyway
        case .listAgain: canListAgain
        case .undo where healthUndoIsNewest, .redo where healthRedoIsNewest: true
        default: nil
        }
    }
}

/// Library Health's changes Library's Undo and Redo take back and make again, run one at a time in the order they're
/// asked for.
@MainActor
final class HealthSteps {
    var undo: [HealthStep] = []
    var redo: [HealthStep] = []
    private var tail: Task<Void, Never>?

    /// Runs `body` once those asked for before it are done.
    func enqueue(_ body: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await body()
        }
    }

    /// Returns once every change, Undo and Redo asked for is done.
    func made() async {
        while let tail {
            await tail.value
            if self.tail == tail {
                break
            }
        }
    }
}

/// One of Library Health's changes, as Undo takes it back and Redo makes it again.
@MainActor
final class HealthStep {
    enum Kind {
        /// A batch carrying out `check`'s proposals for `photos`, those `chosen` among them chosen though listed apart.
        case batch(check: HealthCheck, photos: [Int64], chosen: Set<Int64>)
        /// Findings kept anyway, by what Keep Anyway added.
        case keptAnyway([KeptAnyway])
        /// What kept photos anyway, taken back by List Again.
        case listedAgain([KeptAnyway])
    }

    let kind: Kind
    /// As Undo and the activity log name it: "Move 14 copies to the Trash".
    let title: String
    /// The batch that made it last, for its Undo.
    var batch: UUID?
    /// The newest change of Library's other Undos when it was made or made again.
    var newest: [ObjectIdentifier?] = []
    /// When it was taken back: the newest change of Library's other Redos, and every change on their Undos.
    var newestUndone: [ObjectIdentifier?] = []
    var known: Set<ObjectIdentifier> = []

    init(_ kind: Kind, title: String) {
        self.kind = kind
        self.title = title
    }
}

@_spi(Harness) public extension EditorModel {
    /// Returns once every change of Library Health's, its Undos and Redos included, asked for is done.
    func healthChangesMade() async {
        await healthSteps.made()
    }

    /// Library Health's changes Undo can take back.
    var healthUndoCount: Int {
        healthSteps.undo.count
    }
}
