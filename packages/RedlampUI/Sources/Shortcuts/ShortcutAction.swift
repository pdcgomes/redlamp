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

    public init(_ key: Key, shift: Bool = false, option: Bool = false, command: Bool = false) {
        self.key = key
        self.shift = shift
        self.option = option
        self.command = command
    }

    public static func char(
        _ character: Character,
        shift: Bool = false,
        option: Bool = false,
        command: Bool = false,
    ) -> KeyCombo {
        KeyCombo(.character(character), shift: shift, option: option, command: command)
    }

    /// `⇧⌘C`, `Tab`, `F6`, `←`.
    public var display: String {
        var text = ""
        if option {
            text += "⌥"
        }
        if shift {
            text += "⇧"
        }
        if command {
            text += "⌘"
        }
        switch key {
        case let .character(character): text += character == " " ? "Space" : String(character).uppercased()
        case .tab: text += "Tab"
        case .escape: text += "Esc"
        case .delete: text += "⌫"
        case .space: text += "Space"
        case .left: text += "←"
        case .right: text += "→"
        case .up: text += "↑"
        case .down: text += "↓"
        case let .function(number): text += "F\(number)"
        }
        return text
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
        switch key {
        case let .character(character): return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
        case .left: return KeyboardShortcut(.leftArrow, modifiers: modifiers)
        case .right: return KeyboardShortcut(.rightArrow, modifiers: modifiers)
        default: return nil
        }
    }
}

public enum ShortcutCategory: String, CaseIterable, Sendable {
    case view = "View"
    case panels = "Panels"
    case navigation = "Navigation"
    case develop = "Develop"
    case tools = "Tools"
    case masking = "Masking"
    case rating = "Rating & Flags"
    case file = "File & Edit"
}

/// Every Develop-module shortcut, modelled on Lightroom Classic.
///
/// Single source of truth: the key monitor, the menus and the Keyboard Shortcuts sheet all
/// read this. Shortcuts for tools that are not built yet are listed with their phase, so the
/// full map is visible from day one.
public enum ShortcutAction: String, CaseIterable, Sendable, Identifiable {
    // View
    case beforeAfter, nextCompareLayout, previousCompareLayout
    case toggleZoom, zoomIn, zoomOut
    case clipping, rawClipping, colorAssessment, infoOverlay, lightsOut, fullScreenPreview, toggleToolbar

    // Panels
    case toggleSidePanels, toggleAllPanels, toggleFilmstrip, toggleLeftPanel, toggleRightPanel
    case panelBasic, panelToneCurve, panelColorMixer, panelColorGrading, panelDetail
    case panelLens, panelTransform, panelEffects, panelCalibration

    /// Navigation
    case previousPhoto, nextPhoto

    // Develop
    case undo, redo, copySettings, pasteSettings, pastePrevious, resetAll
    case autoTone, autoWhiteBalance, toggleBlackAndWhite, whiteBalanceSelector
    case newSnapshot, newPreset, virtualCopy
    case previousSetting, nextSetting, increaseSetting, decreaseSetting, findAdjustment

    // Tools
    case editTool, cropTool, healTool, maskingTool, cropAspectLock
    case brushMask, linearMask, radialMask, colorRangeMask, luminanceRangeMask, depthRangeMask

    /// Masking
    case maskOverlay, maskOverlayColor, maskPins, deleteMask, cancel

    // Rating & flags
    case rating0, rating1, rating2, rating3, rating4, rating5
    case decreaseRating, increaseRating
    case flagPick, flagReject, unflag
    case labelRed, labelYellow, labelGreen, labelBlue

    /// File & Edit
    case openFolder, export, showShortcuts, filmLooks

    public var id: String {
        rawValue
    }

    public var category: ShortcutCategory {
        switch self {
        case .beforeAfter, .nextCompareLayout, .previousCompareLayout,
             .toggleZoom, .zoomIn, .zoomOut, .clipping, .rawClipping, .colorAssessment, .infoOverlay, .lightsOut,
             .fullScreenPreview, .toggleToolbar:
            .view
        case .toggleSidePanels, .toggleAllPanels, .toggleFilmstrip, .toggleLeftPanel, .toggleRightPanel,
             .panelBasic, .panelToneCurve, .panelColorMixer, .panelColorGrading, .panelDetail,
             .panelLens, .panelTransform, .panelEffects, .panelCalibration:
            .panels
        case .previousPhoto, .nextPhoto:
            .navigation
        case .undo, .redo, .copySettings, .pasteSettings, .pastePrevious, .resetAll, .autoTone,
             .autoWhiteBalance, .toggleBlackAndWhite, .whiteBalanceSelector, .newSnapshot, .newPreset,
             .virtualCopy, .previousSetting, .nextSetting, .increaseSetting, .decreaseSetting, .findAdjustment:
            .develop
        case .editTool, .cropTool, .healTool, .maskingTool, .cropAspectLock, .brushMask, .linearMask,
             .radialMask, .colorRangeMask, .luminanceRangeMask, .depthRangeMask:
            .tools
        case .maskOverlay, .maskOverlayColor, .maskPins, .deleteMask, .cancel:
            .masking
        case .rating0, .rating1, .rating2, .rating3, .rating4, .rating5, .decreaseRating, .increaseRating,
             .flagPick, .flagReject, .unflag, .labelRed, .labelYellow, .labelGreen, .labelBlue:
            .rating
        case .openFolder, .export, .showShortcuts, .filmLooks:
            .file
        }
    }

    public var title: String {
        switch self {
        case .beforeAfter: "Before / After"
        case .nextCompareLayout: "Next Before / After Layout"
        case .previousCompareLayout: "Previous Before / After Layout"
        case .toggleZoom: "Toggle Zoom (Fit ↔ 100%)"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .clipping: "Show Clipping"
        case .rawClipping: "Show Sensor Clipping"
        case .colorAssessment: "Color Assessment View"
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
        case .undo: "Undo"
        case .redo: "Redo"
        case .copySettings: "Copy Settings"
        case .pasteSettings: "Paste Settings"
        case .pastePrevious: "Paste Settings from Previous"
        case .resetAll: "Reset All Settings"
        case .autoTone: "Auto Settings"
        case .autoWhiteBalance: "Auto White Balance"
        case .toggleBlackAndWhite: "Convert to Black & White"
        case .whiteBalanceSelector: "White Balance Selector"
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
        case .brushMask: "Brush Mask"
        case .linearMask: "Linear Gradient Mask"
        case .radialMask: "Radial Gradient Mask"
        case .colorRangeMask: "Color Range Mask"
        case .luminanceRangeMask: "Luminance Range Mask"
        case .depthRangeMask: "Depth Range Mask"
        case .maskOverlay: "Show / Hide Mask Overlay"
        case .maskOverlayColor: "Cycle Mask Overlay Color"
        case .maskPins: "Show / Hide Pins"
        case .deleteMask: "Delete Selected Mask"
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
        case .openFolder: "Open Folder…"
        case .export: "Export…"
        case .showShortcuts: "Keyboard Shortcuts"
        case .filmLooks: "Film Looks"
        case .findAdjustment: "Find Adjustment…"
        }
    }

    /// The keys, first one shown as primary. Lightroom Classic's Develop defaults.
    public var combos: [KeyCombo] {
        switch self {
        case .beforeAfter: [.char("\\")]
        case .nextCompareLayout: [.char("y")]
        case .previousCompareLayout: [.char("y", shift: true)]
        case .toggleZoom: [.char("z"), KeyCombo(.space)]
        case .zoomIn: [.char("=", command: true)]
        case .zoomOut: [.char("-", command: true)]
        case .clipping: [.char("j")]
        case .rawClipping: [.char("j", option: true)]
        case .colorAssessment: [.char("l", shift: true)]
        case .infoOverlay: [.char("i")]
        case .lightsOut: [.char("l")]
        case .fullScreenPreview: [.char("f")]
        case .toggleToolbar: [.char("t"), KeyCombo(.function(5))]
        case .toggleSidePanels: [KeyCombo(.tab)]
        case .toggleAllPanels: [KeyCombo(.tab, shift: true)]
        case .toggleFilmstrip: [KeyCombo(.function(6))]
        case .toggleLeftPanel: [KeyCombo(.function(7))]
        case .toggleRightPanel: [KeyCombo(.function(8))]
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
        case .undo: [.char("z", command: true)]
        case .redo: [.char("z", shift: true, command: true)]
        case .copySettings: [.char("c", shift: true, command: true)]
        case .pasteSettings: [.char("v", shift: true, command: true)]
        case .pastePrevious: [.char("v", option: true, command: true)]
        case .resetAll: [.char("r", shift: true, command: true)]
        case .autoTone: [.char("u", command: true)]
        case .autoWhiteBalance: [.char("u", shift: true, command: true)]
        case .toggleBlackAndWhite: [.char("v")]
        case .whiteBalanceSelector: [.char("w")]
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
        case .openFolder: [.char("o", command: true)]
        case .export: [.char("e", shift: true, command: true)]
        case .showShortcuts: [.char("/", command: true)]
        case .filmLooks: [.char("l", shift: true, command: true)]
        case .findAdjustment: [.char("f", command: true)]
        }
    }

    /// For actions that also accept Shift as a modifier of their behaviour (rating keys
    /// advance to the next photo, setting nudges take larger steps).
    public var acceptsShift: Bool {
        switch self {
        case .rating0, .rating1, .rating2, .rating3, .rating4, .rating5, .decreaseRating, .increaseRating,
             .flagPick, .flagReject, .unflag, .labelRed, .labelYellow, .labelGreen, .labelBlue,
             .increaseSetting, .decreaseSetting:
            true
        default:
            false
        }
    }

    /// Where the feature lands on the roadmap; `nil` once it works.
    public var plannedPhase: String? {
        switch self {
        case .cropTool, .cropAspectLock, .brushMask, .colorRangeMask, .luminanceRangeMask, .virtualCopy:
            "Phase 2"
        case .healTool, .depthRangeMask: "Phase 3"
        default: nil
        }
    }

    public var isAvailable: Bool {
        plannedPhase == nil
    }

    /// Combos with ⌘ are handled by the menu bar; the rest by the Develop key monitor.
    public var isMenuShortcut: Bool {
        combos.first?.command ?? false
    }

    static let byCategory: [(ShortcutCategory, [ShortcutAction])] = ShortcutCategory.allCases.map { category in
        (category, allCases.filter { $0.category == category })
    }

    /// Resolves a key press. Exact matches win; actions that accept Shift also match
    /// with Shift held (and receive `shifted == true`).
    public static func resolve(_ combo: KeyCombo) -> (action: ShortcutAction, shifted: Bool)? {
        if let exact = allCases.first(where: { $0.combos.contains(combo) }) {
            return (exact, combo.shift && exact.acceptsShift)
        }
        guard combo.shift else { return nil }
        var unshifted = combo
        unshifted.shift = false
        if let action = allCases.first(where: { $0.acceptsShift && $0.combos.contains(unshifted) }) {
            return (action, true)
        }
        return nil
    }
}
