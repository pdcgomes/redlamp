import Foundation
import RedlampEngineAPI

/// Sync Settings, and Paste and Update AI Masks across a selection: the active photo's own change
/// is a step in its history as usual; the others go through `SettingsSync`.
public extension EditorModel {
    /// The selection's photos other than the open one.
    var otherSelectedPhotos: [URL] {
        selectedPhotos.filter { $0 != selection }
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
        guard settingsSync.isAutoSyncing, isMultiSelecting, info != nil else { return }
        let changes = SettingsSelection.changes(from: previous, to: recipe)
        settingsSync.autoSync(recipe, changes, on: otherSelectedPhotos, done: written)
    }

    internal func sync(_ source: EditRecipe, _ selection: SettingsSelection, title: String) {
        saveNow()
        settingsSync.run(.paste(source, selection), on: otherSelectedPhotos, title: title, done: written)
    }

    internal func written(_ url: URL, _ recipe: EditRecipe) {
        library.update(url) { $0.hasEdits = !recipe.isPristine }
    }
}
