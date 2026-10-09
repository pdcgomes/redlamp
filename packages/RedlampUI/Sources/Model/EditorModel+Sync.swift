import Foundation
import RedlampEngineAPI

/// Sync Settings, and Paste, Update AI Masks and mask presets across a selection: the active
/// photo's own change is a step in its history as usual; the others go through `SettingsSync`.
public extension EditorModel {
    /// The selection's photos other than the open one.
    var otherSelectedPhotos: [URL] {
        selectedPhotos.filter { $0 != selection }
    }

    /// Calls `body` with the selection's photos other than the open one, once their rows are read: a large source's
    /// are read first (`withSelectedPhotos`).
    internal func withOtherSelectedPhotos(_ body: @escaping @MainActor ([URL]) -> Void) {
        let open = selection
        withSelectedPhotos { photos in body(photos.filter { $0 != open }) }
    }

    var canSync: Bool {
        isMultiSelecting && info != nil && settingsSync.progress == nil
    }

    /// ⇧⌘S: the checklist, then the open photo's settings onto the rest of the selection.
    func chooseSettingsToSync() {
        guard canSync else { return }
        settingsChooser = SettingsChooser(purpose: .sync, source: recipe, selection: copySelection.remembered)
    }

    /// ⌥⇧⌘S: the same with the last choice, without the checklist.
    func syncSettings() {
        guard canSync else { return }
        sync(recipe, copySelection, title: "Sync Settings")
    }

    /// Update AI Masks on every selected photo.
    func updateAIMasksInSelection() async {
        if isMultiSelecting, settingsSync.progress == nil {
            saveNow()
            await readSelection()
            settingsSync.run(.updateAIMasks, on: otherSelectedPhotos, title: "Update AI Masks", done: written)
        }
        await updateAIMasks()
    }

    /// Puts back the photos the last sync or paste changed, those not edited since.
    func undoSync() {
        settingsSync.undo(done: written)
    }

    /// ⌥⇧⌘A: Auto Sync on or off.
    func toggleAutoSync() {
        settingsSync.isAutoSyncing.toggle()
    }

    /// With Auto Sync on, what the step just recorded changed goes to the rest of the selection.
    internal func autoSync(from previous: EditRecipe) {
        guard settingsSync.isAutoSyncing, isMultiSelecting, info != nil,
              history.indices.contains(historyIndex) else { return }
        let step = history[historyIndex]
        let (current, run) = (recipe, SettingsSync.RunStep(
            session: historySessionID, id: step.id, title: step.title,
            carried: SettingsSelection.changes(from: previous, to: recipe),
        ))
        withOtherSelectedPhotos { [weak self] others in
            guard let self else { return }
            settingsSync.autoSync(current, step: run, on: others, done: written)
        }
    }

    /// With Auto Sync on, Undo, Redo and history clicks take the rest of the selection with them:
    /// each photo gets back its edit at that step.
    internal func followHistory(back: Bool) {
        guard settingsSync.isAutoSyncing, isMultiSelecting, info != nil else { return }
        let (current, undone, session) = (recipe, Set(history[(historyIndex + 1)...].map(\.id)), historySessionID)
        withOtherSelectedPhotos { [weak self] others in
            guard let self else { return }
            settingsSync.follow(
                current, undone: undone, session: session, on: others,
                title: back ? "Undo Auto Sync" : "Redo Auto Sync", done: written,
            )
        }
    }

    /// `selection` of `source` onto the rest of the selection. `step`, the open photo's step that
    /// pasted the same, makes it part of an Auto Sync run.
    internal func sync(_ source: EditRecipe, _ selection: SettingsSelection, title: String, step: UUID? = nil) {
        saveNow()
        var runStep: SettingsSync.RunStep?
        if let step {
            let pasted = EditRecipe.pastedMasks(from: source, selection)
            runStep = SettingsSync.RunStep(
                session: historySessionID,
                id: step,
                title: title,
                carried: SettingsSelection(
                    items: selection.items, masks: !pasted.isEmpty,
                    excludedMasks: Set(recipe.masks.map(\.id)).subtracting(pasted),
                    panelSwitches: selection.panelSwitches,
                ),
            )
        }
        withOtherSelectedPhotos { [weak self] others in
            guard let self else { return }
            settingsSync.run(.paste(source, selection), on: others, title: title, step: runStep, done: written)
        }
    }

    internal func written(_ url: URL, _ recipe: EditRecipe) {
        library.update(url) { $0.hasEdits = !recipe.isPristine }
        library.sidecarSaved(url)
    }
}

/// A batch reaching the open photo changes it here, as a step of its history its Undo takes back.
extension EditorModel: SyncEditor {
    func apply(_ change: SettingsSync.EditorChange, to url: URL, title: String) async -> SettingsSync.EditorOutcome {
        await finishOpening(url)
        guard let visit = currentVisit, visit.url == url else { return isOpen(url) ? .left : .notOpen }
        guard !isReadOnly else { return .left }
        let before = recipe
        switch change {
        case let .edit(next, over):
            guard recipe == over else { return .left }
            commit(next, .paste, title)
        case let .change(.paste(source, selection)):
            paste(source, selection, name: title)
        case .change(.updateAIMasks):
            await updateAIMasks()
            guard currentVisit == visit else { return isOpen(url) ? .left : .notOpen }
        case let .change(.applyMaskPreset(preset)):
            await addMaskPreset(preset, autoSyncs: false)
            guard currentVisit == visit else { return isOpen(url) ? .left : .notOpen }
        case let .change(.healDust(found)):
            guard await healDustInEditor(found[url] ?? [], on: url) else { return isOpen(url) ? .left : .notOpen }
        case .change(.follow):
            return .left
        }
        return .applied(recipe == before ? nil : recipe)
    }
}
