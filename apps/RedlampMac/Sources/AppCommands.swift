@_spi(Harness) import RedlampUI
import SwiftUI

/// The menu bar, built from `ShortcutAction` so menus, keys and the ⌘/ sheet always agree, with the keys as
/// Settings › Shortcuts has them (LIB-36). Items are enabled when `canPerform` says so, as the command palette dims
/// its rows. What they show is read from `menu` and the keymap alone, never from the model: SwiftUI makes the whole
/// main menu again whenever anything read here changes.
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
        CommandGroup(after: .appInfo) {
            if let updates {
                Button("Check for Updates…") { updates.check() }
                    .disabled(!updates.canCheck)
            }
        }

        CommandGroup(replacing: .newItem) {
            item(.openFolder, perform: onOpen)
            item(.importPhotos)
            item(.importFromLightroom)
            item(.importKeywords)
            item(.exportKeywords)
            Divider()
            item(.newCollection)
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
        item(.renamePhotos)
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
        item(.locateMissingPhoto)
        item(.removeMissingPhotos)
        // The Library menu's item, ahead of this one, carries the key.
        item(.renamePhotos, keyed: false)
        item(.moveToFolder)
        item(.copyToFolder)
        Divider()
        item(.addToCollection)
        item(.addToTargetCollection)
        item(.removeFromCollection)
    }

    /// The edit's settings, auto settings, rotation, snapshots and copies.
    @ViewBuilder private var photoSettingsItems: some View {
        item(.copySettings)
        item(.copySettingsAgain)
        item(.pasteSettings)
        item(.pastePrevious)
        item(.syncSettings)
        item(.syncSettingsAgain)
        item(.undoSync)
        toggle(.toggleAutoSync)
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
            item(.removeFromStack)
            item(.splitStack)
            Divider()
            item(.moveToStackTop)
            item(.moveUpInStack)
            item(.moveDownInStack)
            Divider()
            item(.toggleStack)
            item(.openAllStacks)
            item(.closeAllStacks)
        }
        .disabled(shown.isModalDialogOpen)
        Divider()
        item(.previousPhoto)
        item(.nextPhoto)
        item(.previousGroup)
        item(.nextGroup)
        item(.selectAllPhotos)
        item(.deselectOtherPhotos)
    }

    /// Ratings, flags, labels, the mark and keywords: in Library on the whole selection, in Develop on the active
    /// photo (LIB-15).
    @ViewBuilder private var photoMarkingItems: some View {
        let shown = menu.shown
        Menu("Set Rating") {
            ForEach([ShortcutAction.rating0, .rating1, .rating2, .rating3, .rating4, .rating5]) { item($0) }
            Divider()
            item(.decreaseRating)
            item(.increaseRating)
        }
        Menu("Set Flag") {
            ForEach([ShortcutAction.flagPick, .flagReject, .unflag]) { item($0) }
        }
        Menu("Set Color Label") {
            ForEach([ShortcutAction.labelRed, .labelYellow, .labelGreen, .labelBlue]) { item($0) }
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
        item(.toggleMark)
        keywordSetMenu
        item(.editCaptureTime)
        toggle(.autoAdvance)
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
                item(action, titled: action.keywordSetNumber.flatMap { shown.keywords[$0 - 1] })
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
        ForEach([ShortcutAction.gridView, .loupeView, .compareView, .surveyView]) { item($0) }
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
            item(.cycleGridStyle)
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
        item(.largerThumbnails)
        item(.smallerThumbnails)
    }

    /// The filter bar, its presets and the sort.
    @ViewBuilder private var viewFilterItems: some View {
        let shown = menu.shown
        item(.toggleFilterBar)
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
            item(.beforeAfter)
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
            item(.nextCompareLayout)
            item(.previousCompareLayout)
        }
        item(.zoomIn)
        item(.zoomOut)
        toggle(.labReadout)
        commandItem(.toggleRightPanel)
        toggle(.showPhotosInSubfolders)
        item(.showRecentlyTrashed)
        // The Library panel's entries (LIB-23).
        ForEach([ShortcutAction.showAllPhotographs, .showPreviousImport, .showMarked, .showRejected]) { item($0) }
        Menu("Develop Panels") {
            ForEach(Self.developPanels) { item($0) }
        }
        Menu("Filmstrip") {
            item(.toggleFilmstrip)
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

    static let developPanels: [ShortcutAction] = [
        .panelBasic, .panelToneCurve, .panelColorMixer, .panelColorGrading, .panelDetail, .panelLens, .panelTransform,
        .panelEffects, .panelCalibration,
    ]

    /// A menu item for `action`, titled `title` if given. Its first key, if it has ⌘, is the item's key
    /// equivalent unless it isn't `keyed`; a key without ⌘ is shown in the title, because a modifier-free key
    /// equivalent would also fire while typing in a text field.
    private func item(
        _ action: ShortcutAction, titled title: String? = nil, keyed: Bool = true, perform: (() -> Void)? = nil,
    ) -> some View {
        Button(self.title(of: action, titled: title)) {
            if let perform {
                perform()
            } else {
                model.perform(action)
            }
        }
        .keyboardShortcut(keyed ? keyEquivalent(of: action) : nil)
        .disabled(!action.isAvailable || !menu.isEnabled(action))
    }

    /// A menu item carrying the first of the action's keys with ⌘, which menus can: an action whose first
    /// key is a single key, as F8 for the right panel is, and which has a ⌘ key besides.
    private func commandItem(_ action: ShortcutAction) -> some View {
        Button(action.title) { model.perform(action) }
            .keyboardShortcut(action.combos.first(where: \.command)?.keyboardShortcut)
            .disabled(!menu.isEnabled(action))
    }

    /// A menu item with a checkmark while its action is on, and its key as `item`'s.
    private func toggle(_ action: ShortcutAction) -> some View {
        let isOn = menu.isChecked(action)
        return Toggle(title(of: action), isOn: Binding(get: { isOn }, set: { _ in model.perform(action) }))
            .keyboardShortcut(keyEquivalent(of: action))
            .disabled(!menu.isEnabled(action))
    }

    /// The item's key equivalent: the action's first key, if it has ⌘ and isn't another action's in the module
    /// shown, as ⌘N is New Collection's in Library and New Snapshot's in Develop. AppKit gives a key to the first
    /// item that has it, enabled or not.
    private func keyEquivalent(of action: ShortcutAction) -> KeyboardShortcut? {
        let keymap = ShortcutKeymap.current
        guard keymap.menuCarriesKey(of: action, in: menu.shown.module) else { return nil }
        return keymap.combos(for: action).first?.keyboardShortcut
    }

    private func title(of action: ShortcutAction, titled title: String? = nil) -> String {
        let title = title ?? action.plannedPhase.map { "\(action.title) (\($0))" } ?? action.title
        guard let key = action.combos.first, !key.command else { return title }
        return "\(title)    \(key.display)"
    }
}
