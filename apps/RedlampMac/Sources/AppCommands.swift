import RedlampUI
import SwiftUI

/// The menu bar, built from `ShortcutAction` so menus, keys and the ⌘/ sheet always agree.
/// Items are enabled when `canPerform` says so, as the command palette dims its rows.
struct AppCommands: Commands {
    let model: EditorModel
    let updates: Updates?
    let onOpen: () -> Void
    let onExport: () -> Void
    let onExportWithPrevious: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if let updates {
                Button("Check for Updates…") { updates.check() }
                    .disabled(!updates.canCheck)
            }
        }

        CommandGroup(replacing: .newItem) {
            item(.openFolder, perform: onOpen)
            Divider()
            item(.export, perform: onExport)
            item(.exportWithPrevious, perform: onExportWithPrevious)
        }

        CommandGroup(replacing: .undoRedo) {
            item(.undo)
            item(.redo)
        }

        // Edit ▸ Find: the command palette, and ⌘F for its sliders.
        CommandGroup(replacing: .textEditing) {
            item(.commandPalette)
            item(.findAdjustment)
        }

        CommandMenu("Photo") {
            item(.copySettings)
            item(.copySettingsAgain)
            item(.pasteSettings)
            item(.pastePrevious)
            item(.syncSettings)
            item(.syncSettingsAgain)
            item(.undoSync)
            item(.toggleAutoSync)
            Divider()
            item(.autoTone)
            item(.autoWhiteBalance)
            item(.resetAll)
            Divider()
            item(.newSnapshot)
            item(.newPreset)
            item(.virtualCopy)
            Divider()
            item(.mergeFocusStack)
            item(.editFocusStack)
            Divider()
            item(.previousPhoto)
            item(.nextPhoto)
            item(.selectAllPhotos)
            item(.deselectOtherPhotos)
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
                .disabled(model.selection == nil || model.isModalDialogOpen)
                Divider()
                mouseItem(.nextCompareLayout)
                mouseItem(.previousCompareLayout)
            }
            item(.zoomIn)
            item(.zoomOut)
            Toggle("Show Photos in Subfolders", isOn: Binding(
                get: { model.library.includesSubfolders },
                set: { model.setIncludesSubfolders($0) },
            ))
            .disabled(model.folder == nil || model.isModalDialogOpen)
            Menu("Develop Panels") {
                ForEach(ShortcutAction.allCases.filter { $0.category == .panels && $0.isMenuShortcut }) { item($0) }
            }
            Divider()
        }

        CommandGroup(before: .windowList) {
            item(.filmLooks) { openWindow(id: FilmCatalogView.windowID) }
            Divider()
        }

        CommandGroup(after: .help) {
            item(.showShortcuts)
            Divider()
            Button("Support Redlamp") { openURL(SettingsView.supportURL) }
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
        .disabled(!action.isAvailable || !model.canPerform(action))
    }

    /// A menu item for a single-key shortcut: the key is shown in the title, because a
    /// modifier-free key equivalent would also fire while typing in a text field.
    private func mouseItem(_ action: ShortcutAction) -> some View {
        Button("\(action.title)    \(action.combos.first?.display ?? "")") { model.perform(action) }
            .disabled(!model.canPerform(action))
    }
}
