import Foundation
import RedlampDocument
import RedlampEngineAPI

/// History: this session's steps, undo and redo through them, and the photo's earlier sessions.
public extension EditorModel {
    var canUndo: Bool {
        historyIndex > 0
    }

    var canRedo: Bool {
        historyIndex < history.count - 1
    }

    func undo() {
        commandPalette?.endBurst()
        guard canUndo else { return }
        goToHistory(historyIndex - 1)
    }

    func redo() {
        commandPalette?.endBurst()
        guard canRedo else { return }
        goToHistory(historyIndex + 1)
    }

    /// Clears every session's history, this one's and the earlier ones saved with the photo.
    func clearHistory() {
        history = [HistoryStep(action: .clear, title: "History Cleared", recipe: recipe)]
        historyIndex = 0
        historyTask?.cancel()
        earlierSessions = []
        earlierSessionsLoaded = true
        clearsSavedHistory = true
        saveNow()
    }

    /// Brings back a step of an earlier session as a new step of this one, so earlier sessions
    /// never change.
    func restoreHistory(_ step: HistoryStep, from session: HistorySession) {
        let started = session.started.formatted(date: .abbreviated, time: .shortened)
        commit(step.recipe, .restore, "Restored") { _ in started }
    }
}

extension EditorModel {
    /// Records the edit as a step. With `value`, the step shows the value it changed in `previous`
    /// and now, or only now when they read the same.
    func recordHistory(
        _ action: HistoryAction,
        _ title: String,
        from previous: EditRecipe? = nil,
        value: ((EditRecipe) -> String)? = nil,
    ) {
        let after = value?(recipe)
        let before = previous.flatMap { value?($0) }
        let prior = history.indices.contains(historyIndex) ? history[historyIndex].recipe : previous
        defer {
            // A paste reaches the selection itself.
            if action != .paste, let prior {
                autoSync(from: prior)
            }
        }
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(HistoryStep(
            action: action, title: title, before: before == after ? nil : before, after: after, recipe: recipe,
        ))
        if history.count > 500 {
            history.removeFirst(history.count - 500)
        }
        historyIndex = history.count - 1
    }

    /// Records a slider's change as a step: "Exposure", 0.00 → +0.50.
    func recordStep(for parameter: ParameterID, from previous: EditRecipe) {
        let spec = parameter.spec
        if parameter.isSpotScoped {
            let spot = selectedSpotID
            recordHistory(.retouch, "Spot \(spec.label)", from: previous) { recipe in
                spec.formatted(recipe.spots.first { $0.id == spot }?[parameter] ?? spec.defaultValue)
            }
        } else if parameter.isMaskScoped {
            let mask = selectedMaskID
            let component = selectedComponentID
            recordHistory(.mask(nil), "\(selectedMask?.name ?? "Mask") \(spec.label)", from: previous) { recipe in
                spec.formatted(Self.maskValue(parameter, in: recipe, mask: mask, component: component))
            }
        } else {
            recordHistory(.adjustment(parameter), parameter.displayName, from: previous) {
                spec.formatted($0[parameter])
            }
        }
    }
}
