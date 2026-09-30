import RedlampUI
import SwiftUI

/// The menu bar, built from `ShortcutAction` so menus, keys and the ⌘/ sheet always agree.
struct AppCommands: Commands {
    let model: EditorModel
    let onOpen: () -> Void
    let onExport: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            item(.openFolder, perform: onOpen)
            Divider()
            item(.export, perform: onExport)
                .disabled(model.info == nil)
        }

        CommandGroup(replacing: .undoRedo) {
            item(.undo).disabled(!model.canUndo)
            item(.redo).disabled(!model.canRedo)
        }

        CommandMenu("Photo") {
            item(.copySettings).disabled(model.info == nil)
            item(.pasteSettings).disabled(!model.hasClipboard || model.info == nil)
            item(.pastePrevious).disabled(model.previousSelection == nil || model.info == nil)
            Divider()
            item(.autoTone).disabled(model.info == nil)
            item(.autoWhiteBalance).disabled(model.info?.supportsWhiteBalance != true)
            item(.resetAll).disabled(model.info == nil)
            Divider()
            item(.newSnapshot).disabled(model.info == nil)
            item(.newPreset)
            item(.virtualCopy)
            Divider()
            item(.previousPhoto)
            item(.nextPhoto)
            Divider()
            Menu("Set Rating") {
                ForEach([ShortcutAction.rating0, .rating1, .rating2, .rating3, .rating4, .rating5]) { mouseItem($0) }
            }
            Menu("Set Flag") {
                ForEach([ShortcutAction.flagPick, .flagReject, .unflag]) { mouseItem($0) }
            }
            Menu("Set Color Label") {
                ForEach([ShortcutAction.labelRed, .labelYellow, .labelGreen, .labelBlue]) { mouseItem($0) }
            }
        }

        CommandGroup(after: .toolbar) {
            Menu("Before / After") {
                mouseItem(.beforeAfter)
                Divider()
                Picker("Layout", selection: Binding(
                    get: { model.compareLayout },
                    set: { model.showComparison(in: $0) },
                )) {
                    ForEach(CompareLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .disabled(model.selection == nil)
                Divider()
                mouseItem(.nextCompareLayout)
                mouseItem(.previousCompareLayout)
            }
            item(.zoomIn)
            item(.zoomOut)
            Menu("Develop Panels") {
                ForEach(ShortcutAction.allCases.filter { $0.category == .panels && $0.isMenuShortcut }) { item($0) }
            }
            Divider()
        }

        CommandGroup(after: .help) {
            item(.showShortcuts)
        }
    }

    /// A menu item with the action's ⌘ shortcut.
    private func item(_ action: ShortcutAction, perform: (() -> Void)? = nil) -> some View {
        Button(action.plannedPhase.map { "\(action.title) (\($0))" } ?? action.title) {
            if let perform {
                perform()
            } else {
                model.perform(action)
            }
        }
        .keyboardShortcut(action.combos.first?.keyboardShortcut)
        .disabled(!action.isAvailable)
    }

    /// A menu item for a single-key shortcut: the key is shown in the title, because a
    /// modifier-free key equivalent would also fire while typing in a text field.
    private func mouseItem(_ action: ShortcutAction) -> some View {
        Button("\(action.title)    \(action.combos.first?.display ?? "")") { model.perform(action) }
            .disabled(model.selection == nil)
    }
}
