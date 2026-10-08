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
            item(.importPhotos)
            item(.importKeywords)
            item(.exportKeywords)
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
            item(.putBack)
            item(.putBackBatch)
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
            mouseItem(.previousGroup)
            mouseItem(.nextGroup)
            item(.selectAllPhotos)
            item(.deselectOtherPhotos)
            Divider()
            // In Library on the whole selection, in Develop on the active photo (LIB-15).
            Menu("Set Rating") {
                ForEach([ShortcutAction.rating0, .rating1, .rating2, .rating3, .rating4, .rating5]) { mouseItem($0) }
                Divider()
                mouseItem(.decreaseRating)
                mouseItem(.increaseRating)
            }
            Menu("Set Flag") {
                ForEach([ShortcutAction.flagPick, .flagReject, .unflag]) { mouseItem($0) }
            }
            Menu("Set Color Label") {
                ForEach([ShortcutAction.labelRed, .labelYellow, .labelGreen, .labelBlue]) { mouseItem($0) }
                item(.labelPurple)
                if !model.customLabels.isEmpty {
                    Divider()
                    ForEach(model.customLabels, id: \.self) { name in
                        Button(name) { model.setCustomLabel(name) }
                            .disabled(!model.canPerform(.clearLabel))
                    }
                }
                Divider()
                item(.clearLabel)
            }
            mouseItem(.toggleMark)
            // Library's keyword set (LIB-21): its nine keywords on the selection, toggled, and the set chosen.
            Menu("Keyword Set") {
                Picker("Keyword Set", selection: Binding(
                    get: { model.libraryPanels.activeSet?.name ?? "" },
                    set: { model.libraryPanels.chooseKeywordSet($0) },
                )) {
                    ForEach(model.libraryPanels.keywordSets) { Text($0.name).tag($0.name) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(model.module != .library || model.isModalDialogOpen)
                Divider()
                ForEach(ShortcutAction.allCases.filter { $0.keywordSetNumber != nil }) { action in
                    let keyword = action.keywordSetNumber
                        .flatMap { model.libraryPanels.activeSet?.keyword(forShortcut: $0) }
                    Button("\(keyword?.name ?? action.title)    \(action.combos.first?.display ?? "")") {
                        model.perform(action)
                    }
                    .disabled(!model.canPerform(action))
                }
            }
            item(.editCaptureTime)
            Toggle(ShortcutAction.autoAdvance.title, isOn: Binding(
                get: { model.autoAdvance },
                set: { _ in model.perform(.autoAdvance) },
            ))
            .disabled(!model.canPerform(.autoAdvance))
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
            Menu("Group By") {
                ForEach(ShortcutAction.allCases.filter { $0.groupKey != nil }) { action in
                    toggle(action, isOn: model.libraryViews.groupKey == action.groupKey)
                }
                Divider()
                item(.tighterMoments)
                item(.looserMoments)
                toggle(.unpickedMoments, isOn: model.showsUnpickedMoments)
                Divider()
                item(.toggleGroup)
                item(.openAllGroups)
                item(.closeAllGroups)
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
            commandItem(.toggleRightPanel)
            toggle(.showPhotosInSubfolders, isOn: model.library.includesSubfolders)
            item(.showRecentlyTrashed)
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

    /// A menu item carrying the first of the action's keys with ⌘, which menus can: an action whose first
    /// key is a single key, as F8 for the right panel is, and which has a ⌘ key besides.
    private func commandItem(_ action: ShortcutAction) -> some View {
        Button(action.title) { model.perform(action) }
            .keyboardShortcut(action.combos.first(where: \.command)?.keyboardShortcut)
            .disabled(!model.canPerform(action))
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
