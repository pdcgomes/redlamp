import Foundation
import RedlampLibrary

/// Library Health's changes on Library's ⌘Z and ⇧⌘Z (LIB-40): a batch the sheet confirmed, taken back through its
/// Undo in the file operations' journal and made again from the check's findings for the same photos, checked again
/// as the first was; and Keep Anyway and List Again, each taking back what the other makes.
///
/// Each takes its turn among Library's changes (`EditorModel+LibraryUndo`): a batch once it has run, as the sheet
/// holds every other change back until then, and Keep Anyway and List Again as they're asked for. ⌘Z takes one back
/// when it's the newest of them, and a change of any kind ends their Redo, as one of theirs ends every other's. One
/// that stops, or changes nothing, leaves Undo.
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

    /// Library's Undo takes back Library Health's latest change: it's the library's newest change.
    var healthUndoIsNewest: Bool {
        module == .library && libraryUndoKind == .health
    }

    /// Library's Redo makes again Library Health's change taken back last: it's the library's change taken back last.
    var healthRedoIsNewest: Bool {
        module == .library && libraryRedoKind == .health
    }

    /// Puts `step` on Undo, newest, ending every Redo.
    func pushHealthStep(_ step: HealthStep) {
        step.turn = nextLibraryTurn()
        healthSteps.undo.append(step)
        if healthSteps.undo.count > Self.healthUndoLimit {
            healthSteps.undo.removeFirst(healthSteps.undo.count - Self.healthUndoLimit)
        }
        endLibraryRedo()
    }

    /// Takes `step`, which stopped or changed nothing, off Undo and Redo.
    func dropHealthStep(_ step: HealthStep) {
        healthSteps.undo.removeAll { $0 === step }
        healthSteps.redo.removeAll { $0 === step }
    }

    /// ⌘Z: Library Health's latest change taken back, in the background.
    @discardableResult
    func undoHealth() -> Bool {
        guard healthUndoIsNewest, let core = library.service?.core, let step = healthSteps.undo.popLast() else {
            return false
        }
        let made = step.turn
        step.turn = nextLibraryTurn()
        healthSteps.redo.append(step)
        activity.record(.action, "Undo \(step.title)")
        let health = healthProposals.library(core)
        healthSteps.enqueue { [weak self] in
            guard let self else { return }
            do {
                try await take(step, back: true, core: core, health: health)
            } catch {
                activity.record(.error, "Undo \(step.title) wasn't done: \(Self.healthFailure(error))")
                // Back on Undo in its place when it may go through later, unless a change made since ended its Redo.
                let undone = healthSteps.redo.contains { $0 === step }
                healthSteps.redo.removeAll { $0 === step }
                if Self.mayRetryHealth(error), undone {
                    step.turn = made
                    healthSteps.undo.append(step)
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
        let undone = step.turn
        step.turn = nextLibraryTurn()
        healthSteps.undo.append(step)
        activity.record(.action, "Redo \(step.title)")
        let health = healthProposals.library(core)
        healthSteps.enqueue { [weak self] in
            guard let self else { return }
            do {
                try await take(step, back: false, core: core, health: health)
            } catch {
                activity.record(.error, "Redo \(step.title) wasn't done: \(Self.healthFailure(error))")
                // Back on Redo when it may go through later and is still the newest change; off Undo either way.
                let newest = healthSteps.undo.last === step && libraryUndoKind == .health
                healthSteps.undo.removeAll { $0 === step }
                if Self.mayRetryHealth(error), newest {
                    step.turn = undone
                    healthSteps.redo.append(step)
                }
            }
        }
        return true
    }

    /// Takes `step` back, or makes it again, in the library's changes' turn.
    private func take(_ step: HealthStep, back: Bool, core: LibraryCore, health: LibraryHealth) async throws {
        switch step.kind {
        case .batch, .remove, .relink:
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
                let kind = step.kind
                step.batch = try await core.change { () -> Result<UUID, any Error> in
                    do {
                        return try await .success(health.run(Self.plan(again: kind, health: health)).batch)
                    } catch {
                        return .failure(error)
                    }
                }.get()
            }
            library.countFolders()
            if case let .relink(relinks) = step.kind {
                library.service?.look(at: Self.folders(of: relinks))
            }
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

    /// The batch that makes a step of `kind` again, from its check's findings now, for the same photos.
    private nonisolated static func plan(
        again kind: HealthStep.Kind,
        health: LibraryHealth,
    ) async throws -> HealthPlan {
        switch kind {
        case let .batch(check, photos, chosen):
            let found = try await health.findings(check)
            let wanted = Set(photos)
            let again = HealthFindings(check: check, findings: found.findings.filter { wanted.contains($0.photo) })
            return try await health.plan(again, choosing: chosen)
        case let .remove(photos):
            return try await health.planRemoval(photos, in: health.findings(.missing))
        case let .relink(relinks):
            return try await health.planRelink(relinks, in: health.findings(.missing))
        case .keptAnyway, .listedAgain:
            throw FileOperationError.nothingToUndo
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
        default: performMissingShortcut(action)
        }
    }

    /// Whether `performHealthShortcut` would do something now; nil for the actions it leaves to others.
    func canPerformHealthShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .acceptHealthProposals: canAcceptHealthProposals
        case .keepAnyway: canKeepAnyway
        case .listAgain: canListAgain
        case .undo where healthUndoIsNewest, .redo where healthRedoIsNewest: true
        default: canPerformMissingShortcut(action)
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
        /// Missing photos taken out of the library (DEC-59).
        case remove([Int64])
        /// Missing photos relinked to the files they were found as (DEC-59).
        case relink([PhotoRelink])
        /// Findings kept anyway, by what Keep Anyway added.
        case keptAnyway([KeptAnyway])
        /// What kept photos anyway, taken back by List Again.
        case listedAgain([KeptAnyway])
    }

    /// What it changes; Keep Anyway's and List Again's entries once they're made.
    var kind: Kind
    /// As Undo and the activity log name it: "Move 14 copies to the Trash".
    var title: String
    /// The batch that made it last, for its Undo.
    var batch: UUID?
    /// Its turn in Library's Undo and Redo (`EditorModel+LibraryUndo`).
    var turn = 0

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
