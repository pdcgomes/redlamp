import AppKit
import RedlampDesign

/// A filmstrip photo's context menu (`docs/plans/2026-10-02-copy-paste-sync-design.md`), as in
/// Lightroom and Finder: on a selected photo, the Photo menu's copy, paste and sync items and, in
/// Library, renaming and moving, acting on the selection as they do there; on any other photo, copying from it or
/// pasting onto it
/// alone, without opening it. Items that don't apply are left out. In Library, its rating, flag,
/// labels and mark come first (`LibraryGridMenu.culling`), then Stacking (`LibraryGridMenu.stacking`);
/// the grid's menu has its own. A photo in Recently Trashed has Put Back's instead (`TrashMenu`).
@MainActor
enum FilmstripMenu {
    static func menu(for photo: URL, model: EditorModel, culling: Bool = false) -> NSMenu? {
        if let trashed = TrashMenu.menu(for: photo, model: model) {
            return trashed
        }
        let menu = NSMenu()
        if culling {
            add(LibraryGridMenu.culling(for: photo, model: model), to: menu)
            if !model.isModalDialogOpen {
                add([LibraryGridMenu.stacking(for: photo, model: model)], to: menu)
            }
        }
        if model.selectedPhotos.contains(photo) {
            let groups: [[ShortcutAction]] = [
                [.copySettings, .copySettingsAgain, .pasteSettings, .pastePrevious],
                [.syncSettings, .syncSettingsAgain, .undoSync, .toggleAutoSync],
                [.renamePhotos, .moveToFolder],
            ]
            for group in groups {
                let actions = group.filter { action in
                    model.canPerform(action) && (action != .toggleAutoSync || model.isMultiSelecting)
                }
                add(actions.map { item(for: $0, model: model) }, to: menu)
            }
        } else if !model.isModalDialogOpen {
            var items = [
                NSMenuItem(title: ShortcutAction.copySettings.title) {
                    Task { await model.chooseSettingsToCopy(from: photo) }
                },
                NSMenuItem(title: ShortcutAction.copySettingsAgain.title) {
                    Task { await model.copySettings(from: photo) }
                },
            ]
            if model.hasClipboard {
                items.append(NSMenuItem(title: ShortcutAction.pasteSettings.title) {
                    model.pasteSettings(onto: photo)
                })
            }
            add(items, to: menu)
            if model.canPerform(.undoSync) {
                add([NSMenuItem(title: ShortcutAction.undoSync.title) { model.perform(.undoSync) }], to: menu)
            }
        }
        return menu.items.isEmpty ? nil : menu
    }

    /// An action as the Photo menu has it, with its keys: here they do the same.
    private static func item(for action: ShortcutAction, model: EditorModel) -> NSMenuItem {
        let state: NSControl.StateValue = action == .toggleAutoSync && model.settingsSync.isAutoSyncing ? .on : .off
        let item = NSMenuItem(title: action.title, state: state) { model.perform(action) }
        if let combo = action.combos.first, combo.command, case let .character(character) = combo.key {
            item.keyEquivalent = String(character)
            var modifiers: NSEvent.ModifierFlags = [.command]
            if combo.shift {
                modifiers.insert(.shift)
            }
            if combo.option {
                modifiers.insert(.option)
            }
            item.keyEquivalentModifierMask = modifiers
        }
        return item
    }

    private static func add(_ items: [NSMenuItem], to menu: NSMenu) {
        guard !items.isEmpty else { return }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        items.forEach(menu.addItem)
    }
}
