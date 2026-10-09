@_spi(Harness) import RedlampUI
import SwiftUI

/// The menu bar, built from `ShortcutAction` so menus, keys and the ⌘/ sheet always agree.
/// Items are enabled when `canPerform` says so, as the command palette dims its rows. What they show is read from
/// `menu` alone, never from the model: SwiftUI makes the whole main menu again whenever anything read here changes.
struct AppCommands: Commands {
    let model: EditorModel
    let menu: MenuBarState
    let updates: Updates?
    let onWelcome: () -> Void
    let onWhatsNew: () -> Void
    let onOpen: () -> Void
    let onExport: () -> Void
    let onExportWithPrevious: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some Commands {
        #if DEBUG || REDLAMP_PROFILING
            let started = MenuBarProbe.shared.rebuilding()
            defer { MenuBarProbe.shared.built(since: started) }
        #endif
        return menus
    }

    /// In parts, each type-checked on its own: as one body, the menus come near the Debug build's limit for a body on
    /// CI's slower Mac.
    @CommandsBuilder private var menus: some Commands {
        appAndFileMenus
        editMenu
        CommandMenu("Library") { libraryItems }
        CommandMenu("Photo") {
            photoFileItems
            Divider()
            photoSettingsItems
            Divider()
            photoStackAndSelectionItems
            Divider()
            photoMarkingItems
        }
        viewMenu
        windowAndHelpMenus
    }

    @CommandsBuilder private var appAndFileMenus: some Commands {
        let shown = menu.shown
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
            // ⌘N is New Collection's in Library and New Snapshot's in Develop: AppKit gives a key to the first item
            // that has it, enabled or not.
            item(.newCollection, keyed: shown.module == .library)
            item(.newSmartCollection)
            item(.newCollectionSet)
            Divider()
            item(.export, perform: onExport)
            item(.exportWithPrevious, perform: onExportWithPrevious)
        }
    }

    @CommandsBuilder private var editMenu: some Commands {
        CommandGroup(replacing: .undoRedo) {
            item(.undo)
            item(.redo)
        }

        // Edit ▸ Find: the command palette, and ⌘F for its sliders.
        CommandGroup(replacing: .textEditing) {
            item(.commandPalette)
            item(.findAdjustment)
        }
    }

    @ViewBuilder private var libraryItems: some View {
        mouseItem(.renamePhotos)
        toggle(.keywordPainter)
        Divider()
        // For the folder added to Folders that holds the folder open (LIB-11).
        item(.moveEditsAndMetadata)
        Divider()
        // For the Library Health check shown (LIB-40).
        item(.acceptHealthProposals)
    }

    /// The photos' files, Library Health's decisions and the collections.
    @ViewBuilder private var photoFileItems: some View {
        // Ahead of Reset All Settings (⇧⌘R): AppKit gives ⌘R to the first item whose key is R.
        item(.showInFinder)
        item(.putBack)
        item(.putBackBatch)
        item(.keepAnyway)
        item(.listAgain)
        mouseItem(.renamePhotos)
        item(.moveToFolder)
        Divider()
        item(.addToCollection)
        item(.addToTargetCollection)
        mouseItem(.removeFromCollection)
    }

    /// The edit's settings, auto settings, rotation, snapshots and copies.
    @ViewBuilder private var photoSettingsItems: some View {
        let shown = menu.shown
        item(.copySettings)
        item(.copySettingsAgain)
        item(.pasteSettings)
        item(.pastePrevious)
        item(.syncSettings)
        item(.syncSettingsAgain)
        item(.undoSync)
        Toggle(ShortcutAction.toggleAutoSync.title, isOn: Binding(
            get: { menu.isChecked(.toggleAutoSync) },
            set: { _ in model.perform(.toggleAutoSync) },
        ))
        .keyboardShortcut(ShortcutAction.toggleAutoSync.combos.first?.keyboardShortcut)
        .disabled(!menu.isEnabled(.toggleAutoSync))
        Divider()
        item(.autoTone)
        item(.autoWhiteBalance)
        item(.calibrateFromTarget)
        item(.resetAll)
        Divider()
        item(.rotateLeft)
        item(.rotateRight)
        Divider()
        item(.newSnapshot, keyed: shown.module != .library)
        item(.newPreset)
        item(.virtualCopy)
    }

    /// Focus stacks, stacks, and moving through and selecting the photos.
    @ViewBuilder private var photoStackAndSelectionItems: some View {
        let shown = menu.shown
        item(.mergeFocusStack)
        item(.editFocusStack)
        // Lightroom Classic's Photo ▸ Stacking (LIB-28).
        Menu("Stacking") {
            item(.stackPhotos)
            item(.unstackPhotos)
            mouseItem(.moveToStackTop)
            Divider()
            mouseItem(.toggleStack)
            item(.openAllStacks)
            item(.closeAllStacks)
        }
        .disabled(shown.isModalDialogOpen)
        Divider()
        item(.previousPhoto)
        item(.nextPhoto)
        mouseItem(.previousGroup)
        mouseItem(.nextGroup)
        item(.selectAllPhotos)
        item(.deselectOtherPhotos)
    }

    /// Ratings, flags, labels, the mark and keywords: in Library on the whole selection, in Develop on the active
    /// photo (LIB-15).
    @ViewBuilder private var photoMarkingItems: some View {
        let shown = menu.shown
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
            if !shown.customLabels.isEmpty {
                Divider()
                ForEach(shown.customLabels, id: \.self) { name in
                    Button(name) { model.setCustomLabel(name) }
                        .disabled(!menu.isEnabled(.clearLabel))
                }
            }
            Divider()
            item(.clearLabel)
        }
        mouseItem(.toggleMark)
        keywordSetMenu
        item(.editCaptureTime)
        Toggle(ShortcutAction.autoAdvance.title, isOn: Binding(
            get: { menu.isChecked(.autoAdvance) },
            set: { _ in model.perform(.autoAdvance) },
        ))
        .disabled(!menu.isEnabled(.autoAdvance))
    }

    /// Library's keyword set (LIB-21): its nine keywords on the selection, toggled, and the set chosen.
    private var keywordSetMenu: some View {
        let shown = menu.shown
        return Menu("Keyword Set") {
            Picker("Keyword Set", selection: Binding(
                get: { menu.shown.activeKeywordSet },
                set: { model.libraryPanels.chooseKeywordSet($0) },
            )) {
                ForEach(shown.keywordSets) { Text($0.name).tag($0.name) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(shown.module != .library || shown.isModalDialogOpen)
            Divider()
            ForEach(ShortcutAction.allCases.filter { $0.keywordSetNumber != nil }) { action in
                let keyword = action.keywordSetNumber.flatMap { shown.keywords[$0 - 1] }
                Button("\(keyword ?? action.title)    \(action.combos.first?.display ?? "")") {
                    model.perform(action)
                }
                .disabled(!menu.isEnabled(action))
            }
        }
    }

    @CommandsBuilder private var viewMenu: some Commands {
        CommandGroup(before: .toolbar) {
            viewLibraryItems
            Divider()
            viewFilterItems
        }

        CommandGroup(after: .toolbar) {
            viewPhotoItems
        }
    }

    /// The modules, Library's views, its grid's styles and groups, and the thumbnails' size.
    @ViewBuilder private var viewLibraryItems: some View {
        let shown = menu.shown
        item(.libraryModule)
        item(.developModule)
        item(.previousModule)
        Divider()
        ForEach([ShortcutAction.gridView, .loupeView, .compareView, .surveyView]) { mouseItem($0) }
        Divider()
        Menu("Grid View Style") {
            Picker("Grid View Style", selection: Binding(
                get: { menu.shown.cellStyle },
                set: { model.setCellStyle($0) },
            )) {
                ForEach(GridCellStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(shown.module != .library || shown.isModalDialogOpen)
            Divider()
            mouseItem(.cycleGridStyle)
        }
        Menu("Group By") {
            ForEach(ShortcutAction.allCases.filter { $0.groupKey != nil }) { toggle($0) }
            Divider()
            item(.tighterMoments)
            item(.looserMoments)
            toggle(.unpickedMoments)
            Divider()
            item(.toggleGroup)
            item(.openAllGroups)
            item(.closeAllGroups)
        }
        mouseItem(.largerThumbnails)
        mouseItem(.smallerThumbnails)
    }

    /// The filter bar, its presets and the sort.
    @ViewBuilder private var viewFilterItems: some View {
        let shown = menu.shown
        mouseItem(.toggleFilterBar)
        toggle(.toggleFilters)
        toggle(.lockFilters)
        Menu("Filter Presets") {
            ForEach(shown.filterPresets) { preset in
                Toggle(preset.name, isOn: Binding(
                    get: { menu.shown.filterPreset == preset },
                    set: { _ in model.libraryFilters?.choose(preset) },
                ))
            }
        }
        .disabled(!shown.hasFilters || shown.isModalDialogOpen)
        Menu("Sort") {
            ForEach(ShortcutAction.allCases.filter { $0.sortField != nil }) { toggle($0) }
            Divider()
            item(.reverseSort)
        }
        Divider()
    }

    /// Before and after, the zoom, the panels, the sources shown and the filmstrip.
    @ViewBuilder private var viewPhotoItems: some View {
        let shown = menu.shown
        Menu("Before / After") {
            mouseItem(.beforeAfter)
            Divider()
            Picker("Layout", selection: Binding(
                get: { menu.shown.compareLayout },
                set: { model.showComparison(in: $0) },
            )) {
                ForEach(CompareLayout.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .disabled(!shown.hasSelection || shown.isModalDialogOpen)
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
        toggle(.showPhotosInSubfolders)
        item(.showRecentlyTrashed)
        // The Library panel's entries (LIB-23).
        ForEach([ShortcutAction.showAllPhotographs, .showPreviousImport, .showMarked, .showRejected]) { item($0) }
        Menu("Develop Panels") {
            ForEach(ShortcutAction.allCases.filter { $0.category == .panels && $0.isMenuShortcut }) { item($0) }
        }
        Menu("Filmstrip") {
            mouseItem(.toggleFilmstrip)
            Toggle("Hide Automatically", isOn: Binding(
                get: { menu.shown.filmstripHidesAutomatically },
                set: { model.filmstripHidesAutomatically = $0 },
            ))
            .disabled(shown.isModalDialogOpen)
        }
        Divider()
    }

    @CommandsBuilder private var windowAndHelpMenus: some Commands {
        let shown = menu.shown
        CommandGroup(before: .windowList) {
            item(.filmLooks) { openWindow(id: FilmCatalogView.windowID) }
            Divider()
        }

        CommandGroup(after: .help) {
            Button("Welcome to Redlamp", action: onWelcome)
            Button(WhatsNewWindowController.title, action: onWhatsNew)
            item(.sendFeedback)
            Button("Your Reports…") { FeedbackActions.presentReports(model: model) }
                .disabled(shown.isModalDialogOpen)
            item(.showShortcuts)
            item(.testCamera)
            Divider()
            Button("Support Redlamp") { openURL(SettingsView.supportURL) }
        }
    }

    /// A menu item with the action's ⌘ shortcut, unless it isn't `keyed`.
    private func item(_ action: ShortcutAction, keyed: Bool = true, perform: (() -> Void)? = nil) -> some View {
        Button(action.plannedPhase.map { "\(action.title) (\($0))" } ?? action.title) {
            if let perform {
                perform()
            } else {
                model.perform(action)
            }
        }
        .keyboardShortcut(keyed ? action.combos.first?.keyboardShortcut : nil)
        .disabled(!action.isAvailable || !menu.isEnabled(action))
    }

    /// A menu item carrying the first of the action's keys with ⌘, which menus can: an action whose first
    /// key is a single key, as F8 for the right panel is, and which has a ⌘ key besides.
    private func commandItem(_ action: ShortcutAction) -> some View {
        Button(action.title) { model.perform(action) }
            .keyboardShortcut(action.combos.first(where: \.command)?.keyboardShortcut)
            .disabled(!menu.isEnabled(action))
    }

    /// A menu item for a single-key shortcut: the key is shown in the title, because a
    /// modifier-free key equivalent would also fire while typing in a text field.
    private func mouseItem(_ action: ShortcutAction) -> some View {
        Button("\(action.title)    \(action.combos.first?.display ?? "")") { model.perform(action) }
            .disabled(!menu.isEnabled(action))
    }

    /// A menu item with a checkmark while its action is on, and the action's ⌘ shortcut.
    private func toggle(_ action: ShortcutAction) -> some View {
        let isOn = menu.isChecked(action)
        return Toggle(action.title, isOn: Binding(get: { isOn }, set: { _ in model.perform(action) }))
            .keyboardShortcut(action.combos.first?.keyboardShortcut)
            .disabled(!menu.isEnabled(action))
    }
}
