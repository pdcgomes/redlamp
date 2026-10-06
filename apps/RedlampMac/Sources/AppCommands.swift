import RedlampUI
import SwiftUI

/// The menu bar, built from `ShortcutAction` so menus, keys and the ⌘/ sheet always agree.
/// Items are enabled when `canPerform` says so, as the command palette dims its rows.
struct AppCommands: Commands {
    let model: EditorModel
    let updates: Updates?
    let onWelcome: () -> Void
    let onWhatsNew: () -> Void
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
            // Ahead of Reset All Settings (⇧⌘R): AppKit gives ⌘R to the first item whose key is R.
            item(.showInFinder)
            Divider()
            item(.copySettings)
            item(.copySettingsAgain)
            item(.pasteSettings)
            item(.pastePrevious)
            item(.syncSettings)
            item(.syncSettingsAgain)
            item(.undoSync)
            Toggle(ShortcutAction.toggleAutoSync.title, isOn: Binding(
                get: { model.settingsSync.isAutoSyncing },
                set: { _ in model.perform(.toggleAutoSync) },
            ))
            .keyboardShortcut(ShortcutAction.toggleAutoSync.combos.first?.keyboardShortcut)
            .disabled(!model.canPerform(.toggleAutoSync))
            Divider()
            item(.autoTone)
            item(.autoWhiteBalance)
            item(.calibrateFromTarget)
            item(.resetAll)
            Divider()
            item(.rotateLeft)
            item(.rotateRight)
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

        CommandGroup(before: .toolbar) {
            item(.libraryModule)
            item(.developModule)
            item(.previousModule)
            Divider()
            ForEach([ShortcutAction.gridView, .loupeView, .compareView, .surveyView]) { mouseItem($0) }
            Divider()
            Menu("Grid View Style") {
                Picker("Grid View Style", selection: Binding(
                    get: { model.libraryViews.cellStyle },
                    set: { model.setCellStyle($0) },
                )) {
                    ForEach(GridCellStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(model.module != .library || model.isModalDialogOpen)
                Divider()
                mouseItem(.cycleGridStyle)
            }
            mouseItem(.largerThumbnails)
            mouseItem(.smallerThumbnails)
            Divider()
            mouseItem(.toggleFilterBar)
            toggle(.toggleFilters, isOn: model.libraryFilters?.filter.isEnabled == true)
            toggle(.lockFilters, isOn: model.libraryFilters?.isLocked == true)
            Menu("Filter Presets") {
                ForEach(model.libraryFilters?.presets ?? []) { preset in
                    Toggle(preset.name, isOn: Binding(
                        get: { model.libraryFilters?.preset == preset },
                        set: { _ in model.libraryFilters?.choose(preset) },
                    ))
                }
            }
            .disabled(model.libraryFilters == nil || model.isModalDialogOpen)
            Menu("Sort") {
                ForEach(ShortcutAction.allCases.filter { $0.sortField != nil }) { action in
                    toggle(action, isOn: model.libraryFilters?.sort.field == action.sortField)
                }
                Divider()
                item(.reverseSort)
            }
            Divider()
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
            Toggle(ShortcutAction.labReadout.title, isOn: Binding(
                get: { model.showsLabReadout },
                set: { _ in model.perform(.labReadout) },
            ))
            .disabled(!model.canPerform(.labReadout))
            Toggle("Show Photos in Subfolders", isOn: Binding(
                get: { model.library.includesSubfolders },
                set: { model.setIncludesSubfolders($0) },
            ))
            .disabled(model.folder == nil || model.isModalDialogOpen)
            Menu("Develop Panels") {
                ForEach(ShortcutAction.allCases.filter { $0.category == .panels && $0.isMenuShortcut }) { item($0) }
            }
            Menu("Filmstrip") {
                mouseItem(.toggleFilmstrip)
                Toggle("Hide Automatically", isOn: Binding(
                    get: { model.filmstripHidesAutomatically },
                    set: { model.filmstripHidesAutomatically = $0 },
                ))
                .disabled(model.isModalDialogOpen)
            }
            Divider()
        }

        CommandGroup(before: .windowList) {
            item(.filmLooks) { openWindow(id: FilmCatalogView.windowID) }
            Divider()
        }

        CommandGroup(after: .help) {
            Button("Welcome to Redlamp", action: onWelcome)
            Button(WhatsNewWindowController.title, action: onWhatsNew)
            item(.sendFeedback)
            Button("Your Reports…") { FeedbackActions.presentReports(model: model) }
                .disabled(model.isModalDialogOpen)
            item(.showShortcuts)
            item(.testCamera)
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

    /// A menu item with a checkmark while `isOn`, and the action's ⌘ shortcut.
    private func toggle(_ action: ShortcutAction, isOn: Bool) -> some View {
        Toggle(action.title, isOn: Binding(get: { isOn }, set: { _ in model.perform(action) }))
            .keyboardShortcut(action.combos.first?.keyboardShortcut)
            .disabled(!model.canPerform(action))
    }
}
