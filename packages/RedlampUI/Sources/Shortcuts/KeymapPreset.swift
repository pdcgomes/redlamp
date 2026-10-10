import Foundation

/// Keys for people coming from another app (LIB-36): Redlamp's own, which are Lightroom Classic's, or those
/// Photo Mechanic and Adobe Bridge publish for the actions Redlamp has. A preset changes only what the other app
/// gives a key; an action whose key it takes gives it up, and every other action keeps Redlamp's key.
public enum KeymapPreset: String, CaseIterable, Sendable, Identifiable {
    case lightroomClassic, photoMechanic, bridge

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .lightroomClassic: "Lightroom Classic"
        case .photoMechanic: "Photo Mechanic"
        case .bridge: "Adobe Bridge"
        }
    }

    /// What the preset changes, for Settings.
    public var summary: String {
        switch self {
        case .lightroomClassic:
            "Redlamp's own keys, which are Lightroom Classic's."
        case .photoMechanic:
            "Stars on ⌃0 to ⌃5 as well as 0 to 5, labels on ⌘1 to ⌘5 and ⌘0, T for the mark, ⌘G to import, ⌘Y "
                + "to copy, ⌘B to add to the target collection, ⌃⌘X to export and ⌘F for the filter bar. The "
                + "Develop panels move to ⌃⌘1 to ⌃⌘9."
        case .bridge:
            "Stars on ⌘0 to ⌘5 and labels on ⌘6 to ⌘9 as well as the single keys, ⌥⌫ to reject, ⌘R to open "
                + "in Develop, ⇧⌘R to rename, ⌘B for Survey, Space for full screen, ⌘= and ⌘- for the "
                + "thumbnails and ⌘\\ for the grid's style. The Develop panels move to ⌃⌘1 to ⌃⌘9."
        }
    }

    /// Where the keys come from.
    public var source: URL? {
        switch self {
        case .lightroomClassic: nil
        case .photoMechanic: URL(string: "https://docs.camerabits.com/support/solutions/articles/48000317772")
        case .bridge: URL(string: "https://helpx.adobe.com/bridge/desktop/get-started/keyboard-shortcuts.html")
        }
    }

    public func combos(for action: ShortcutAction) -> [KeyCombo] {
        Self.overrides[self]?[action] ?? action.defaultCombos
    }

    private static let overrides: [KeymapPreset: [ShortcutAction: [KeyCombo]]] = [
        .photoMechanic: photoMechanicKeys,
        .bridge: bridgeKeys,
    ]

    /// The Develop panels where ⌘1 to ⌘9 are the other app's stars or labels.
    private static let panelsOnControl: [ShortcutAction: [KeyCombo]] = Dictionary(uniqueKeysWithValues: [
        ShortcutAction.panelBasic, .panelToneCurve, .panelColorMixer, .panelColorGrading, .panelDetail, .panelLens,
        .panelTransform, .panelEffects, .panelCalibration,
    ].enumerated().map { index, action in
        (action, [KeyCombo.char(Character("\(index + 1)"), command: true, control: true)])
    })

    private static func digits(_ actions: [ShortcutAction], from first: Int) -> [(ShortcutAction, Character)] {
        actions.enumerated().map { ($1, Character("\(first + $0)")) }
    }

    private static let ratings: [ShortcutAction] = [.rating0, .rating1, .rating2, .rating3, .rating4, .rating5]

    /// Camera Bits, "Keyboard Shortcuts: macOS": stars on Control-0 to 5 (and 0 to 5 with single keys on), color
    /// classes on Command-1 to 8 and Command-0, T toggles the tag, Command-G ingests, Command-Y copies or moves,
    /// Command-B adds to the selected collection, Command-Control-X exports, Command-F finds, F1 views all items
    /// and F3 the tagged. Its first five color classes are Redlamp's five labels, in Lightroom's order; Command-M
    /// (Rename) is the Mac's Minimize, so renaming keeps F2.
    private static let photoMechanicKeys: [ShortcutAction: [KeyCombo]] = {
        var keys = panelsOnControl
        for (action, digit) in digits(ratings, from: 0) {
            keys[action] = [.char(digit, control: true), .char(digit)]
        }
        for (action, digit) in digits([.labelRed, .labelYellow, .labelGreen, .labelBlue, .labelPurple], from: 1) {
            keys[action] = [.char(digit, command: true)]
        }
        keys[.clearLabel] = [.char("0", command: true)]
        keys[.toggleMark] = [.char("t")]
        keys[.toggleToolbar] = [KeyCombo(.function(5))]
        keys[.importPhotos] = [.char("g", command: true)]
        keys[.stackPhotos] = []
        keys[.copyToFolder] = [.char("y", command: true)]
        keys[.addToTargetCollection] = [.char("b", command: true)]
        keys[.showMarked] = [KeyCombo(.function(3))]
        keys[.showAllPhotographs] = [KeyCombo(.function(1))]
        keys[.export] = [.char("x", command: true, control: true), .char("e", shift: true, command: true)]
        keys[.toggleFilterBar] = [.char("f", command: true), .char("\\")]
        return keys
    }()

    /// Adobe, "Adobe Bridge keyboard shortcuts" (10 April 2026), "Label and rate files" and "Preview images", and
    /// Julieanne Kost, "20+ Tips, Tricks and Shortcuts for Working with Adobe Bridge" (2017): stars on Command-0
    /// to 5 and labels on Command-6 to 9 (single keys with the modifier dropped in Preferences), Option-Delete
    /// rejects, Command-R opens Camera Raw, Command-Shift-R renames, Command-B is Review mode, the space bar Full
    /// Screen Preview, Command-plus and minus the thumbnails' size and Command-\ the Content panel's views.
    /// Purple has no key; Command-comma and period step the rating there, but Command-comma is Settings on the Mac.
    private static let bridgeKeys: [ShortcutAction: [KeyCombo]] = {
        var keys = panelsOnControl
        for (action, digit) in digits(ratings, from: 0) {
            keys[action] = [.char(digit, command: true), .char(digit)]
        }
        for (action, digit) in digits([.labelRed, .labelYellow, .labelGreen, .labelBlue], from: 6) {
            keys[action] = [.char(digit, command: true), .char(digit)]
        }
        keys[.flagReject] = [KeyCombo(.delete, option: true), .char("x")]
        keys[.developModule] = [.char("r", command: true), .char("2", option: true, command: true)]
        keys[.showInFinder] = []
        keys[.renamePhotos] = [.char("r", shift: true, command: true), KeyCombo(.function(2))]
        keys[.resetAll] = []
        keys[.surveyView] = [.char("b", command: true), .char("n")]
        keys[.showMarked] = []
        keys[.fullScreenPreview] = [KeyCombo(.space), .char("f")]
        keys[.toggleZoom] = [.char("z")]
        keys[.largerThumbnails] = [.char("=", command: true), .char("=")]
        keys[.smallerThumbnails] = [.char("-", command: true), .char("-")]
        keys[.cycleGridStyle] = [.char("\\", command: true), .char("j")]
        return keys
    }()
}
