import SwiftUI

/// A key plus modifiers, as typed. `key` is the unshifted character or a named key.
public struct KeyCombo: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        case character(Character)
        case tab, escape, delete, space, left, right, up, down
        case function(Int)
    }

    public var key: Key
    public var shift: Bool
    public var option: Bool
    public var command: Bool
    /// Only a preset's or a person's keys have it (Photo Mechanic rates with ⌃1 to ⌃5).
    public var control: Bool

    public init(_ key: Key, shift: Bool = false, option: Bool = false, command: Bool = false, control: Bool = false) {
        self.key = key
        self.shift = shift
        self.option = option
        self.command = command
        self.control = control
    }

    public static func char(
        _ character: Character,
        shift: Bool = false,
        option: Bool = false,
        command: Bool = false,
        control: Bool = false,
    ) -> KeyCombo {
        KeyCombo(.character(character), shift: shift, option: option, command: command, control: control)
    }

    /// `⇧⌘C`, `Tab`, `F6`, `←`.
    public var display: String {
        keys.joined()
    }

    /// One entry per key, modifiers first: `["⇧", "⌘", "C"]`, as keycaps draw them.
    public var keys: [String] {
        var keys: [String] = []
        if control {
            keys.append("⌃")
        }
        if option {
            keys.append("⌥")
        }
        if shift {
            keys.append("⇧")
        }
        if command {
            keys.append("⌘")
        }
        switch key {
        case let .character(character): keys.append(character == " " ? "Space" : String(character).uppercased())
        case .tab: keys.append("Tab")
        case .escape: keys.append("Esc")
        case .delete: keys.append("⌫")
        case .space: keys.append("Space")
        case .left: keys.append("←")
        case .right: keys.append("→")
        case .up: keys.append("↑")
        case .down: keys.append("↓")
        case let .function(number): keys.append("F\(number)")
        }
        return keys
    }

    /// The SwiftUI shortcut for menu items (only combos with ⌘ go through menus).
    public var keyboardShortcut: KeyboardShortcut? {
        guard command else { return nil }
        var modifiers: EventModifiers = [.command]
        if shift {
            modifiers.insert(.shift)
        }
        if option {
            modifiers.insert(.option)
        }
        if control {
            modifiers.insert(.control)
        }
        switch key {
        case let .character(character): return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
        case .left: return KeyboardShortcut(.leftArrow, modifiers: modifiers)
        case .right: return KeyboardShortcut(.rightArrow, modifiers: modifiers)
        case .up: return KeyboardShortcut(.upArrow, modifiers: modifiers)
        case .down: return KeyboardShortcut(.downArrow, modifiers: modifiers)
        // A menu item matches the Delete key's U+007F, not SwiftUI's `.delete`, U+0008.
        case .delete: return KeyboardShortcut(KeyEquivalent("\u{7F}"), modifiers: modifiers)
        default: return nil
        }
    }
}

public enum ShortcutCategory: String, CaseIterable, Sendable {
    case modules = "Modules"
    case library = "Library"
    case view = "View"
    case panels = "Panels"
    case navigation = "Navigation"
    case develop = "Develop"
    case tools = "Tools"
    case masking = "Masking"
    case rating = "Rating & Flags"
    case file = "File & Edit"
}

/// Every shortcut of the Library and Develop modules, modelled on Lightroom Classic.
///
/// Single source of truth: the key monitor, the menus and the Keyboard Shortcuts sheet all
/// read this. Shortcuts for tools that are not built yet are listed with their phase, so the
/// full map is visible from day one.
public enum ShortcutAction: String, CaseIterable, Sendable, Identifiable {
    /// Modules
    case libraryModule, developModule, previousModule, gridView, loupeView, compareView, surveyView

    /// Library
    case cycleGridStyle, largerThumbnails, smallerThumbnails, showInFinder, showPhotosInSubfolders
    case showRecentlyTrashed, putBack, putBackBatch
    case showAllPhotographs, showPreviousImport, showMarked, showRejected
    case newCollection, newSmartCollection, newCollectionSet, addToCollection, addToTargetCollection
    case removeFromCollection
    case toggleFilterBar, toggleFilters, lockFilters
    case sortByFolder, sortByCaptureTime, sortByName, sortByRating, sortByEditTime, sortByModified, sortByFileSize
    case reverseSort
    case groupByNone, groupByMoment, groupByDay, groupByFolder, groupByCamera, groupByLens, groupByOrientation
    case groupByMomentCamera, tighterMoments, looserMoments, toggleGroup, openAllGroups, closeAllGroups
    case unpickedMoments
    case toggleStack, stackPhotos, unstackPhotos, moveToStackTop, openAllStacks, closeAllStacks
    case removeFromStack, splitStack, moveUpInStack, moveDownInStack
    case keywordSet1, keywordSet2, keywordSet3, keywordSet4, keywordSet5, keywordSet6, keywordSet7, keywordSet8
    case keywordSet9
    case importKeywords, exportKeywords, editCaptureTime
    case renamePhotos, moveToFolder, copyToFolder, keywordPainter, moveEditsAndMetadata
    case acceptHealthProposals, keepAnyway, listAgain, locateMissingPhoto, removeMissingPhotos

    // View
    case beforeAfter, nextCompareLayout, previousCompareLayout
    case toggleZoom, zoomIn, zoomOut
    case clipping, rawClipping, colorAssessment, labReadout, infoOverlay, lightsOut, fullScreenPreview, toggleToolbar

    // Panels
    case toggleSidePanels, toggleAllPanels, toggleFilmstrip, toggleLeftPanel, toggleRightPanel
    case panelBasic, panelToneCurve, panelColorMixer, panelColorGrading, panelDetail
    case panelLens, panelTransform, panelEffects, panelCalibration

    /// Navigation
    case previousPhoto, nextPhoto, selectAllPhotos, deselectOtherPhotos, previousGroup, nextGroup

    // Develop
    case undo, redo, copySettings, copySettingsAgain, pasteSettings, pastePrevious, resetAll
    case syncSettings, syncSettingsAgain, undoSync, toggleAutoSync
    case autoTone, autoWhiteBalance, toggleBlackAndWhite, whiteBalanceSelector, calibrateFromTarget
    case newSnapshot, newPreset, virtualCopy
    case previousSetting, nextSetting, increaseSetting, decreaseSetting, findAdjustment

    // Tools
    case editTool, cropTool, healTool, maskingTool, cropAspectLock, rotateLeft, rotateRight
    case brushMask, linearMask, radialMask, colorRangeMask, luminanceRangeMask, depthRangeMask

    /// Masking
    case maskOverlay, maskOverlayColor, maskPins, deleteMask, cancel

    // Rating & flags
    case rating0, rating1, rating2, rating3, rating4, rating5
    case decreaseRating, increaseRating
    case flagPick, flagReject, unflag
    case labelRed, labelYellow, labelGreen, labelBlue, labelPurple, clearLabel
    case toggleMark, autoAdvance

    /// File & Edit
    case openFolder, importPhotos, export, exportWithPrevious, mergeFocusStack, editFocusStack, showShortcuts
    case importFromLightroom
    case filmLooks
    case commandPalette, sendFeedback
    case testCamera

    public var id: String {
        rawValue
    }

    public var category: ShortcutCategory {
        switch self {
        case .libraryModule, .developModule, .previousModule, .gridView, .loupeView, .compareView, .surveyView:
            .modules
        case .cycleGridStyle, .largerThumbnails, .smallerThumbnails, .showInFinder, .showPhotosInSubfolders,
             .showRecentlyTrashed, .putBack, .putBackBatch,
             .showAllPhotographs, .showPreviousImport, .showMarked, .showRejected,
             .newCollection, .newSmartCollection, .newCollectionSet, .addToCollection, .addToTargetCollection,
             .removeFromCollection,
             .toggleFilterBar, .toggleFilters, .lockFilters, .sortByFolder, .sortByCaptureTime, .sortByName,
             .sortByRating, .sortByEditTime, .sortByModified, .sortByFileSize, .reverseSort,
             .groupByNone, .groupByMoment, .groupByDay, .groupByFolder, .groupByCamera, .groupByLens,
             .groupByOrientation, .groupByMomentCamera, .tighterMoments, .looserMoments, .toggleGroup,
             .openAllGroups, .closeAllGroups, .unpickedMoments,
             .toggleStack, .stackPhotos, .unstackPhotos, .moveToStackTop, .openAllStacks, .closeAllStacks,
             .removeFromStack, .splitStack, .moveUpInStack, .moveDownInStack,
             .keywordSet1, .keywordSet2, .keywordSet3, .keywordSet4, .keywordSet5, .keywordSet6, .keywordSet7,
             .keywordSet8, .keywordSet9, .importKeywords, .exportKeywords, .editCaptureTime, .renamePhotos,
             .moveToFolder, .copyToFolder, .keywordPainter, .moveEditsAndMetadata, .acceptHealthProposals, .keepAnyway,
             .listAgain, .locateMissingPhoto, .removeMissingPhotos:
            .library
        case .beforeAfter, .nextCompareLayout, .previousCompareLayout,
             .toggleZoom, .zoomIn, .zoomOut, .clipping, .rawClipping, .colorAssessment, .labReadout, .infoOverlay,
             .lightsOut, .fullScreenPreview, .toggleToolbar:
            .view
        case .toggleSidePanels, .toggleAllPanels, .toggleFilmstrip, .toggleLeftPanel, .toggleRightPanel,
             .panelBasic, .panelToneCurve, .panelColorMixer, .panelColorGrading, .panelDetail,
             .panelLens, .panelTransform, .panelEffects, .panelCalibration:
            .panels
        case .previousPhoto, .nextPhoto, .selectAllPhotos, .deselectOtherPhotos, .previousGroup, .nextGroup:
            .navigation
        case .undo, .redo, .copySettings, .copySettingsAgain, .pasteSettings, .pastePrevious, .resetAll, .autoTone,
             .syncSettings, .syncSettingsAgain, .undoSync, .toggleAutoSync,
             .autoWhiteBalance, .toggleBlackAndWhite, .whiteBalanceSelector, .calibrateFromTarget, .newSnapshot,
             .newPreset, .virtualCopy, .previousSetting, .nextSetting, .increaseSetting, .decreaseSetting,
             .findAdjustment:
            .develop
        case .editTool, .cropTool, .healTool, .maskingTool, .cropAspectLock, .rotateLeft, .rotateRight, .brushMask,
             .linearMask,
             .radialMask, .colorRangeMask, .luminanceRangeMask, .depthRangeMask:
            .tools
        case .maskOverlay, .maskOverlayColor, .maskPins, .deleteMask, .cancel:
            .masking
        case .rating0, .rating1, .rating2, .rating3, .rating4, .rating5, .decreaseRating, .increaseRating,
             .flagPick, .flagReject, .unflag, .labelRed, .labelYellow, .labelGreen, .labelBlue, .labelPurple,
             .clearLabel, .toggleMark, .autoAdvance:
            .rating
        case .openFolder, .importPhotos, .export, .exportWithPrevious, .mergeFocusStack, .editFocusStack,
             .showShortcuts, .filmLooks, .commandPalette, .sendFeedback:
            .file
        case .importFromLightroom:
            .file
        case .testCamera:
            .file
        }
    }

    public var title: String {
        switch self {
        case .libraryModule: "Library"
        case .developModule: "Develop"
        case .previousModule: "Previous Module"
        case .gridView: "Grid"
        case .loupeView: "Loupe"
        case .compareView: "Compare (Loupe for Now)"
        case .surveyView: "Survey (Loupe for Now)"
        case .cycleGridStyle: "Cycle Grid View Style"
        case .largerThumbnails: "Increase Thumbnail Size"
        case .smallerThumbnails: "Decrease Thumbnail Size"
        case .showInFinder: "Show in Finder"
        case .showPhotosInSubfolders: "Show Photos in Subfolders"
        case .showRecentlyTrashed: "Show Recently Trashed"
        case .putBack: "Put Back"
        case .putBackBatch: "Put Back Whole Batch"
        case .showAllPhotographs: "Show All Photographs"
        case .showPreviousImport: "Show Previous Import"
        case .showMarked: "Show Marked"
        case .showRejected: "Show Rejected"
        case .newCollection: "New Collection…"
        case .newSmartCollection: "New Smart Collection…"
        case .newCollectionSet: "New Collection Set…"
        case .addToCollection: "Add to Collection…"
        case .addToTargetCollection: "Add to Target Collection"
        case .removeFromCollection: "Remove from Collection"
        case .toggleFilterBar: "Show / Hide Filter Bar"
        case .toggleFilters: "Enable Filters"
        case .lockFilters: "Lock Filters"
        case .sortByFolder: "Sort by Folder Order"
        case .sortByCaptureTime: "Sort by Capture Time"
        case .sortByName: "Sort by File Name"
        case .sortByRating: "Sort by Rating"
        case .sortByEditTime: "Sort by Edit Time"
        case .sortByModified: "Sort by Modified Date"
        case .sortByFileSize: "Sort by File Size"
        case .reverseSort: "Reverse Sort Order"
        case .groupByNone: "No Grouping"
        case .groupByMoment: "Group by Moment"
        case .groupByDay: "Group by Day"
        case .groupByFolder: "Group by Folder"
        case .groupByCamera: "Group by Camera"
        case .groupByLens: "Group by Lens"
        case .groupByOrientation: "Group by Orientation"
        case .groupByMomentCamera: "Group by Moment, then Camera"
        case .tighterMoments: "Tighter Moments"
        case .looserMoments: "Looser Moments"
        case .toggleGroup: "Open / Close Group"
        case .openAllGroups: "Open All Groups"
        case .closeAllGroups: "Close All Groups"
        case .unpickedMoments: "Only Moments without a Pick"
        case .toggleStack: "Open / Close Stack"
        case .stackPhotos: "Group into Stack"
        case .unstackPhotos: "Unstack"
        case .moveToStackTop: "Move to Top of Stack"
        case .openAllStacks: "Open All Stacks"
        case .closeAllStacks: "Close All Stacks"
        case .removeFromStack: "Remove from Stack"
        case .splitStack: "Split Stack"
        case .moveUpInStack: "Move Up in Stack"
        case .moveDownInStack: "Move Down in Stack"
        case .keywordSet1, .keywordSet2, .keywordSet3, .keywordSet4, .keywordSet5, .keywordSet6, .keywordSet7,
             .keywordSet8, .keywordSet9:
            "Keyword Set: Keyword \(keywordSetNumber ?? 0)"
        case .importKeywords: "Import Keywords…"
        case .exportKeywords: "Export Keywords…"
        case .editCaptureTime: "Edit Capture Time…"
        case .renamePhotos: "Rename Photos…"
        case .moveToFolder: "Move to Folder…"
        case .copyToFolder: "Copy to Folder…"
        case .keywordPainter: "Keyword Painter"
        case .moveEditsAndMetadata: "Move Edits and Metadata…"
        case .acceptHealthProposals: "Accept Health Proposals…"
        case .keepAnyway: "Keep Anyway"
        case .listAgain: "List Again in Library Health"
        case .locateMissingPhoto: "Locate…"
        case .removeMissingPhotos: "Remove from Library"
        case .beforeAfter: "Before / After"
        case .nextCompareLayout: "Next Before / After Layout"
        case .previousCompareLayout: "Previous Before / After Layout"
        case .toggleZoom: "Toggle Zoom (Fit ↔ 100%)"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .clipping: "Show Clipping"
        case .rawClipping: "Show Sensor Clipping"
        case .colorAssessment: "Color Assessment View"
        case .labReadout: "Show L*a*b* Values"
        case .infoOverlay: "Cycle Info Overlay"
        case .lightsOut: "Cycle Lights Out"
        case .fullScreenPreview: "Full Screen Preview"
        case .toggleToolbar: "Show / Hide Toolbar"
        case .toggleSidePanels: "Hide Side Panels"
        case .toggleAllPanels: "Hide All Panels"
        case .toggleFilmstrip: "Show / Hide Filmstrip"
        case .toggleLeftPanel: "Show / Hide Left Panel"
        case .toggleRightPanel: "Show / Hide Right Panel"
        case .panelBasic: "Basic Panel"
        case .panelToneCurve: "Tone Curve Panel"
        case .panelColorMixer: "Color Mixer Panel"
        case .panelColorGrading: "Color Grading Panel"
        case .panelDetail: "Detail Panel"
        case .panelLens: "Lens Corrections Panel"
        case .panelTransform: "Transform Panel"
        case .panelEffects: "Effects Panel"
        case .panelCalibration: "Calibration Panel"
        case .previousPhoto: "Previous Photo"
        case .nextPhoto: "Next Photo"
        case .previousGroup: "Previous Group"
        case .nextGroup: "Next Group"
        case .undo: "Undo"
        case .redo: "Redo"
        case .copySettings: "Copy Settings…"
        case .copySettingsAgain: "Copy Settings with Last Choice"
        case .syncSettings: "Sync Settings…"
        case .syncSettingsAgain: "Sync Settings with Last Choice"
        case .undoSync: "Undo Sync Settings"
        case .toggleAutoSync: "Auto Sync"
        case .selectAllPhotos: "Select All Photos"
        case .deselectOtherPhotos: "Deselect Other Photos"
        case .pasteSettings: "Paste Settings"
        case .pastePrevious: "Paste Settings from Previous"
        case .resetAll: "Reset All Settings"
        case .autoTone: "Auto Settings"
        case .autoWhiteBalance: "Auto White Balance"
        case .toggleBlackAndWhite: "Convert to Black & White"
        case .whiteBalanceSelector: "White Balance Selector"
        case .calibrateFromTarget: "Calibrate from Target"
        case .newSnapshot: "New Snapshot"
        case .newPreset: "New Recipe…"
        case .virtualCopy: "Create Virtual Copy"
        case .previousSetting: "Select Previous Setting"
        case .nextSetting: "Select Next Setting"
        case .increaseSetting: "Increase Setting (⇧ larger)"
        case .decreaseSetting: "Decrease Setting (⇧ larger)"
        case .editTool: "Edit"
        case .cropTool: "Crop & Straighten"
        case .healTool: "Healing"
        case .maskingTool: "Masking"
        case .cropAspectLock: "Lock Crop Aspect"
        case .rotateLeft: "Rotate Left"
        case .rotateRight: "Rotate Right"
        case .brushMask: "Brush Mask"
        case .linearMask: "Linear Gradient Mask"
        case .radialMask: "Radial Gradient Mask"
        case .colorRangeMask: "Color Range Mask"
        case .luminanceRangeMask: "Luminance Range Mask"
        case .depthRangeMask: "Depth Range Mask"
        case .maskOverlay: "Show / Hide Mask Overlay"
        case .maskOverlayColor: "Cycle Mask Overlay Color"
        case .maskPins: "Show / Hide Pins or Spots"
        case .deleteMask: "Delete Selected Mask or Spot"
        case .cancel: "Cancel / Leave Tool"
        case .rating0: "Clear Rating"
        case .rating1: "1 Star"
        case .rating2: "2 Stars"
        case .rating3: "3 Stars"
        case .rating4: "4 Stars"
        case .rating5: "5 Stars"
        case .decreaseRating: "Decrease Rating"
        case .increaseRating: "Increase Rating"
        case .flagPick: "Flag as Pick"
        case .flagReject: "Flag as Rejected"
        case .unflag: "Unflag"
        case .labelRed: "Red Label"
        case .labelYellow: "Yellow Label"
        case .labelGreen: "Green Label"
        case .labelBlue: "Blue Label"
        case .labelPurple: "Purple Label"
        case .clearLabel: "No Label"
        case .toggleMark: "Mark / Unmark"
        case .autoAdvance: "Auto Advance"
        case .openFolder: "Open Folder…"
        case .importPhotos: "Import Photos…"
        case .importFromLightroom: "Import from Lightroom Classic…"
        case .export: "Export…"
        case .exportWithPrevious: "Export with Previous"
        case .mergeFocusStack: "Merge to Focus Stack…"
        case .editFocusStack: "Edit Focus Stack…"
        case .showShortcuts: "Keyboard Shortcuts"
        case .filmLooks: "Film Looks"
        case .findAdjustment: "Find Adjustment…"
        case .commandPalette: "Command Palette…"
        case .testCamera: "Test Your Camera…"
        case .sendFeedback: "Report a Bug or Send Feedback…"
        }
    }

    /// The keys as customised (`ShortcutKeymap`), the first shown as the action's key.
    public var combos: [KeyCombo] {
        ShortcutKeymap.current.combos(for: self)
    }

    /// The keys Redlamp comes with, the first shown as primary: Lightroom Classic's.
    public var defaultCombos: [KeyCombo] {
        switch self {
        case .libraryModule: [.char("1", option: true, command: true)]
        case .developModule: [.char("2", option: true, command: true)]
        case .previousModule: [KeyCombo(.up, option: true, command: true)]
        case .gridView: [.char("g")]
        case .loupeView: [.char("e")]
        case .compareView: [.char("c")]
        case .surveyView: [.char("n")]
        // The Library's own meanings of Develop's J, = and - (`isLibraryOnly`).
        case .cycleGridStyle: [.char("j")]
        case .largerThumbnails: [.char("=")]
        case .smallerThumbnails: [.char("-")]
        case .showInFinder: [.char("r", command: true)]
        // In Library, where Develop's Before / After key shows the filter bar, as in Lightroom Classic.
        case .toggleFilterBar: [.char("\\")]
        case .toggleFilters: [.char("l", command: true)]
        case .showPhotosInSubfolders, .showRecentlyTrashed, .putBackBatch, .lockFilters, .sortByFolder,
             .sortByCaptureTime, .sortByName, .sortByRating, .sortByEditTime, .sortByModified, .sortByFileSize,
             .reverseSort, .showAllPhotographs, .showPreviousImport, .showRejected: []
        // Lightroom Classic's Show Quick Collection.
        case .showMarked: [.char("b", command: true)]
        // Lightroom Classic's, in Library, where Develop's New Snapshot and Delete Mask don't reach.
        case .newCollection: [.char("n", command: true)]
        case .removeFromCollection: [KeyCombo(.delete)]
        case .newSmartCollection, .newCollectionSet, .addToCollection, .addToTargetCollection: []
        // Lightroom Classic's keys for the active keyword set's nine keywords.
        case .keywordSet1, .keywordSet2, .keywordSet3, .keywordSet4, .keywordSet5, .keywordSet6, .keywordSet7,
             .keywordSet8, .keywordSet9:
            [.char(Character("\(keywordSetNumber ?? 0)"), option: true)]
        case .importKeywords, .exportKeywords, .editCaptureTime: []
        // Finder's Put Back, in the Trash.
        case .putBack: [KeyCombo(.delete, command: true)]
        // Lightroom Classic has no Group By; its menus, the grid's toolbar and headers, and the palette have them.
        case .groupByNone, .groupByMoment, .groupByDay, .groupByFolder, .groupByCamera, .groupByLens,
             .groupByOrientation, .groupByMomentCamera, .tighterMoments, .looserMoments, .toggleGroup, .openAllGroups,
             .closeAllGroups, .unpickedMoments: []
        // Lightroom Classic's Collapse / Expand Stack, Group into Stack, Unstack and Move to Top of Stack.
        case .toggleStack: [.char("s")]
        case .stackPhotos: [.char("g", command: true)]
        case .unstackPhotos: [.char("g", shift: true, command: true)]
        case .moveToStackTop: [.char("s", shift: true)]
        case .openAllStacks, .closeAllStacks, .removeFromStack, .splitStack: []
        // Lightroom Classic's Move Up and Move Down in Stack, in Library, where ⇧[ and ⇧] don't step the rating and
        // advance as they do in Develop (`isLibraryOnly`).
        case .moveUpInStack: [.char("[", shift: true)]
        case .moveDownInStack: [.char("]", shift: true)]
        case .renamePhotos: [KeyCombo(.function(2))]
        case .moveToFolder, .copyToFolder, .moveEditsAndMetadata, .acceptHealthProposals, .keepAnyway, .listAgain,
             .locateMissingPhoto, .removeMissingPhotos: []
        // Lightroom Classic's Enable Painting.
        case .keywordPainter: [.char("k", option: true, command: true)]
        case .beforeAfter: [.char("\\")]
        case .nextCompareLayout: [.char("y")]
        case .previousCompareLayout: [.char("y", shift: true)]
        case .toggleZoom: [.char("z"), KeyCombo(.space)]
        case .zoomIn: [.char("=", command: true)]
        case .zoomOut: [.char("-", command: true)]
        case .clipping: [.char("j")]
        case .rawClipping: [.char("j", option: true)]
        case .colorAssessment: [.char("l", shift: true)]
        case .labReadout: []
        case .infoOverlay: [.char("i")]
        case .lightsOut: [.char("l")]
        case .fullScreenPreview: [.char("f")]
        case .toggleToolbar: [.char("t"), KeyCombo(.function(5))]
        case .toggleSidePanels: [KeyCombo(.tab)]
        case .toggleAllPanels: [KeyCombo(.tab, shift: true)]
        case .toggleFilmstrip: [KeyCombo(.function(6))]
        case .toggleLeftPanel: [KeyCombo(.function(7))]
        // ⌥⌘→ as Lightroom Classic has it on the Mac, its menu item's.
        case .toggleRightPanel: [KeyCombo(.function(8)), KeyCombo(.right, option: true, command: true)]
        case .panelBasic: [.char("1", command: true)]
        case .panelToneCurve: [.char("2", command: true)]
        case .panelColorMixer: [.char("3", command: true)]
        case .panelColorGrading: [.char("4", command: true)]
        case .panelDetail: [.char("5", command: true)]
        case .panelLens: [.char("6", command: true)]
        case .panelTransform: [.char("7", command: true)]
        case .panelEffects: [.char("8", command: true)]
        case .panelCalibration: [.char("9", command: true)]
        case .previousPhoto: [KeyCombo(.left), KeyCombo(.left, command: true)]
        case .nextPhoto: [KeyCombo(.right), KeyCombo(.right, command: true)]
        case .previousGroup: [KeyCombo(.left, option: true)]
        case .nextGroup: [KeyCombo(.right, option: true)]
        case .undo: [.char("z", command: true)]
        case .redo: [.char("z", shift: true, command: true)]
        case .copySettings: [.char("c", shift: true, command: true)]
        case .copySettingsAgain: [.char("c", shift: true, option: true, command: true)]
        case .syncSettings: [.char("s", shift: true, command: true)]
        case .syncSettingsAgain: [.char("s", shift: true, option: true, command: true)]
        case .undoSync: []
        case .toggleAutoSync: [.char("a", shift: true, option: true, command: true)]
        // Lightroom's ⌘A and ⌘D with Option: without it they would take Select All from text fields.
        case .selectAllPhotos: [.char("a", option: true, command: true)]
        case .deselectOtherPhotos: [.char("d", option: true, command: true)]
        case .pasteSettings: [.char("v", shift: true, command: true)]
        case .pastePrevious: [.char("v", option: true, command: true)]
        case .resetAll: [.char("r", shift: true, command: true)]
        case .autoTone: [.char("u", command: true)]
        case .autoWhiteBalance: [.char("u", shift: true, command: true)]
        case .toggleBlackAndWhite: [.char("v")]
        case .whiteBalanceSelector: [.char("w")]
        case .calibrateFromTarget: []
        case .newSnapshot: [.char("n", command: true)]
        case .newPreset: [.char("n", shift: true, command: true)]
        case .virtualCopy: [.char("'", command: true)]
        case .previousSetting: [.char(",")]
        case .nextSetting: [.char(".")]
        case .increaseSetting: [.char("=")]
        case .decreaseSetting: [.char("-")]
        case .editTool: [.char("d")]
        case .cropTool: [.char("r")]
        case .healTool: [.char("q")]
        case .maskingTool: [.char("w", shift: true)]
        case .cropAspectLock: [.char("a")]
        case .rotateLeft: [.char("[", command: true)]
        case .rotateRight: [.char("]", command: true)]
        case .brushMask: [.char("k")]
        case .linearMask: [.char("m")]
        case .radialMask: [.char("m", shift: true)]
        case .colorRangeMask: [.char("j", shift: true)]
        case .luminanceRangeMask: [.char("q", shift: true)]
        case .depthRangeMask: [.char("z", shift: true)]
        case .maskOverlay: [.char("o")]
        case .maskOverlayColor: [.char("o", shift: true)]
        case .maskPins: [.char("h")]
        case .deleteMask: [KeyCombo(.delete)]
        case .cancel: [KeyCombo(.escape)]
        case .rating0: [.char("0")]
        case .rating1: [.char("1")]
        case .rating2: [.char("2")]
        case .rating3: [.char("3")]
        case .rating4: [.char("4")]
        case .rating5: [.char("5")]
        case .decreaseRating: [.char("[")]
        case .increaseRating: [.char("]")]
        case .flagPick: [.char("p")]
        case .flagReject: [.char("x")]
        case .unflag: [.char("u")]
        case .labelRed: [.char("6")]
        case .labelYellow: [.char("7")]
        case .labelGreen: [.char("8")]
        case .labelBlue: [.char("9")]
        case .labelPurple, .clearLabel, .autoAdvance: []
        case .toggleMark: [.char("b")]
        case .openFolder: [.char("o", command: true)]
        case .importPhotos: [.char("i", shift: true, command: true)]
        case .export: [.char("e", shift: true, command: true)]
        case .exportWithPrevious: [.char("e", shift: true, option: true, command: true)]
        case .mergeFocusStack, .editFocusStack, .sendFeedback: []
        case .importFromLightroom: []
        case .showShortcuts: [.char("/", command: true)]
        case .filmLooks: [.char("l", shift: true, command: true)]
        case .findAdjustment: [.char("f", command: true)]
        case .commandPalette: [.char("k", command: true)]
        case .testCamera: []
        }
    }

    /// The keyword ⌥1 to ⌥9 apply from the active keyword set (LIB-21); nil for every other action.
    public var keywordSetNumber: Int? {
        switch self {
        case .keywordSet1: 1
        case .keywordSet2: 2
        case .keywordSet3: 3
        case .keywordSet4: 4
        case .keywordSet5: 5
        case .keywordSet6: 6
        case .keywordSet7: 7
        case .keywordSet8: 8
        case .keywordSet9: 9
        default: nil
        }
    }

    /// For actions that also accept Shift as a modifier of their behaviour (rating keys
    /// advance to the next photo, setting nudges take larger steps).
    public var acceptsShift: Bool {
        switch self {
        case .rating0, .rating1, .rating2, .rating3, .rating4, .rating5, .decreaseRating, .increaseRating,
             .flagPick, .flagReject, .unflag, .labelRed, .labelYellow, .labelGreen, .labelBlue, .toggleMark,
             .increaseSetting, .decreaseSetting:
            true
        default:
            false
        }
    }

    /// Where the feature lands on the roadmap; `nil` once it works.
    public var plannedPhase: String? {
        switch self {
        case .virtualCopy:
            "Phase 2"
        default: nil
        }
    }

    public var isAvailable: Bool {
        plannedPhase == nil
    }

    /// Whether every key the action has is ⌘'s, which the menu bar handles; the key monitor handles the rest.
    public var isMenuShortcut: Bool {
        let combos = combos
        return !combos.isEmpty && combos.allSatisfy(\.command)
    }

    /// The Keyboard Shortcuts sheet's groups: every action with a key.
    @_spi(Harness) public static var byCategory: [(ShortcutCategory, [ShortcutAction])] {
        let keymap = ShortcutKeymap.current
        return ShortcutCategory.allCases.map { category in
            (category, allCases.filter { $0.category == category && !keymap.combos(for: $0).isEmpty })
        }
    }

    /// Resolves a key press in Develop. Exact matches win; actions that accept Shift also match
    /// with Shift held (and receive `shifted == true`).
    public static func resolve(_ combo: KeyCombo) -> (action: ShortcutAction, shifted: Bool)? {
        resolve(combo, in: .develop)
    }

    /// Resolves a key press in `module`, where J, = and - mean what they mean there.
    public static func resolve(_ combo: KeyCombo, in module: AppModule) -> (action: ShortcutAction, shifted: Bool)? {
        ShortcutKeymap.current.resolve(combo, in: module)
    }
}
