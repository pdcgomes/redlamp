import Foundation
import RedlampDocument
import RedlampEngineAPI

/// The Copy Settings checklist, open for an edit.
public struct SettingsChooser: Identifiable {
    public enum Purpose {
        case copy
        /// Sync Settings: onto the rest of the selection.
        case sync
    }

    public let id = UUID()
    public let purpose: Purpose
    /// The edit whose settings are chosen from: its masks are listed by name.
    public let source: EditRecipe
    public var selection: SettingsSelection
    /// The photo `source` is from, when it isn't the open one (the filmstrip's menu).
    public var sourceURL: URL?
}

/// Copy Settings, Paste and Previous, by Lightroom's checklist (`SettingsSelection`): the choice is
/// made when copying, remembered for next time, and a paste takes only what was ticked
/// (`docs/plans/2026-10-02-copy-paste-sync-design.md`).
public extension EditorModel {
    /// ⇧⌘C: the checklist, for the open photo's settings.
    func chooseSettingsToCopy() {
        guard info != nil else { return }
        settingsChooser = SettingsChooser(purpose: .copy, source: recipe, selection: copySelection.remembered)
    }

    /// The checklist's choice: copied, and remembered for next time. (The checklist is modal: the
    /// open photo is still the one it was opened for.)
    func confirmSettingsChoice(_ chosen: SettingsSelection) {
        guard let chooser = settingsChooser else { return }
        settingsChooser = nil
        copySelection = chosen.remembered
        switch chooser.purpose {
        case .copy:
            clipboard = CopiedSettings(
                source: chooser.source,
                selection: chosen,
                sourceURL: chooser.sourceURL ?? selection,
            )
            hasClipboard = true
        case .sync:
            sync(chooser.source, chosen, title: "Sync Settings")
        }
    }

    /// ⌥⇧⌘C: copies the open photo's settings with the last choice, without the checklist.
    func copySettings() {
        guard info != nil else { return }
        clipboard = CopiedSettings(source: recipe, selection: copySelection, sourceURL: selection)
        hasClipboard = true
    }

    /// ⇧⌘V: what was copied, onto the open photo, and onto the rest of the selection.
    func pasteSettings() {
        guard let clipboard else { return }
        let step = paste(clipboard.source, clipboard.selection, name: "Paste Settings")
        if isMultiSelecting {
            sync(clipboard.source, clipboard.selection, title: "Paste Settings", step: step)
        }
    }

    /// ⌥⌘V: the previously viewed photo's settings, with the last choice (Lightroom's "Previous"),
    /// onto the open photo and the rest of the selection.
    func pasteFromPrevious() {
        guard let previous = previousSelection, info != nil,
              let sidecar = try? SidecarStore().loadThrowing(for: previous)
        else { return }
        let step = paste(sidecar.recipe, copySelection, name: "Paste from Previous")
        if isMultiSelecting {
            sync(sidecar.recipe, copySelection, title: "Paste from Previous", step: step)
        }
    }

    // MARK: - A photo in the filmstrip

    /// The checklist for `photo`'s settings: the open photo's, or another's read from its sidecar
    /// without opening it.
    func chooseSettingsToCopy(from photo: URL) async {
        guard photo != selection else { return chooseSettingsToCopy() }
        guard !isModalDialogOpen, let edit = await edit(of: photo), !isModalDialogOpen else { return }
        settingsChooser = SettingsChooser(
            purpose: .copy, source: edit, selection: copySelection.remembered, sourceURL: photo,
        )
    }

    /// `photo`'s settings with the last choice, without the checklist.
    func copySettings(from photo: URL) async {
        guard photo != selection else { return copySettings() }
        guard !isModalDialogOpen, let edit = await edit(of: photo) else { return }
        clipboard = CopiedSettings(source: edit, selection: copySelection, sourceURL: photo)
        hasClipboard = true
        activity.record(.action, "Copied settings from \(activity.alias(for: photo))")
    }

    /// What was copied, onto `photo`: with the selection when it is in it, otherwise onto it
    /// alone, in the background, leaving the open photo as it is.
    func pasteSettings(onto photo: URL) {
        guard !isModalDialogOpen else { return }
        guard !selectedPhotos.contains(photo) else { return pasteSettings() }
        guard let clipboard else { return }
        settingsSync.run(
            .paste(clipboard.source, clipboard.selection),
            on: [photo],
            title: "Paste Settings",
            done: written,
        )
        activity.record(.action, "Pasted settings onto \(activity.alias(for: photo))")
    }

    /// A photo's edit as saved: the default edit if it has none, nil if it can't be read.
    private func edit(of photo: URL) async -> EditRecipe? {
        await saves.wait(for: photo)
        let read = try? await library.scheduler.run(.onScreen) { () -> EditRecipe? in
            try? SidecarStore().loadThrowing(for: photo).map(\.recipe) ?? EditRecipe()
        }
        return read ?? nil
    }

    /// Pastes onto the open photo as one step, then recomputes the AI masks it brought for this
    /// photo. White balance As Shot reads this photo's own; Auto is measured again for it. Returns
    /// the step it recorded, if it changed anything.
    @discardableResult
    internal func paste(_ source: EditRecipe, _ selection: SettingsSelection, name: String) -> UUID? {
        guard info != nil else { return nil }
        let previous = history.indices.contains(historyIndex) ? history[historyIndex].id : nil
        let pasted = recipe.pasting(source, selection)
            .reusingAIMasks(from: recipe, in: EditRecipe.pastedMasks(from: source, selection))
        var next = pasted.recipe
        let pastesWhiteBalance = selection.items.contains("whiteBalance")
        if pastesWhiteBalance, next.whiteBalanceMode == .asShot, let wb = info?.asShotWhiteBalance {
            next[.temperature] = wb.temperature
            next[.tint] = wb.tint
        }
        commit(next, .paste, name)
        let step = history.indices.contains(historyIndex) ? history[historyIndex].id : nil
        if pastesWhiteBalance, next.whiteBalanceMode == .auto {
            setWhiteBalanceMode(.auto)
        }
        updatePastedAIMasks(pasted.recompute)
        return step == previous ? nil : step
    }
}

extension SettingsSelection {
    private static let defaultsKey = "app.redlamp.copySettings"

    static func saved(in defaults: UserDefaults = .standard) -> SettingsSelection {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(SettingsSelection.self, from: $0) }
            ?? .default
    }

    func save(in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(remembered) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
