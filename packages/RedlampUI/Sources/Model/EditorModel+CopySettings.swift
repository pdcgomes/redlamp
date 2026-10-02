import Foundation
import RedlampDocument
import RedlampEngineAPI

/// The Copy Settings checklist, open for an edit.
public struct SettingsChooser: Identifiable {
    public enum Purpose {
        case copy
    }

    public let id = UUID()
    public let purpose: Purpose
    /// The edit whose settings are chosen from: its masks are listed by name.
    public let source: EditRecipe
    public var selection: SettingsSelection
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
            clipboard = CopiedSettings(source: chooser.source, selection: chosen, sourceURL: selection)
            hasClipboard = true
        }
    }

    /// ⌥⇧⌘C: copies the open photo's settings with the last choice, without the checklist.
    func copySettings() {
        guard info != nil else { return }
        clipboard = CopiedSettings(source: recipe, selection: copySelection, sourceURL: selection)
        hasClipboard = true
    }

    /// ⇧⌘V: what was copied, onto the open photo.
    func pasteSettings() {
        guard let clipboard else { return }
        paste(clipboard.source, clipboard.selection, name: "Paste Settings")
    }

    /// ⌥⌘V: the previously viewed photo's settings, with the last choice (Lightroom's "Previous").
    func pasteFromPrevious() {
        guard let previous = previousSelection, info != nil,
              let sidecar = SidecarStore().load(for: previous)
        else { return }
        paste(sidecar.recipe, copySelection, name: "Paste from Previous")
    }

    /// Pastes onto the open photo as one step, then recomputes the AI masks it brought for this
    /// photo. White balance As Shot reads this photo's own; Auto is measured again for it.
    internal func paste(_ source: EditRecipe, _ selection: SettingsSelection, name: String) {
        guard info != nil else { return }
        var next = recipe.pasting(source, selection)
        let pastesWhiteBalance = selection.items.contains("whiteBalance")
        if pastesWhiteBalance, next.whiteBalanceMode == .asShot, let wb = info?.asShotWhiteBalance {
            next[.temperature] = wb.temperature
            next[.tint] = wb.tint
        }
        commit(next, .paste, name)
        if pastesWhiteBalance, next.whiteBalanceMode == .auto {
            setWhiteBalanceMode(.auto)
        }
        updatePastedAIMasks(EditRecipe.pastedMasks(from: source, selection))
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
