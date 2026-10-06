import Foundation
import RedlampEngineAPI

/// What the palette searches: everything (⌘K), or only sliders (⌘F).
@_spi(Harness) public enum PaletteScope: String, Sendable, Hashable {
    case all, sliders
}

/// A page of choices the palette opens into.
@_spi(Harness) public enum PalettePage: String, CaseIterable, Sendable, Hashable {
    case whiteBalance, treatment, baseLook, recipes, compare, snapshots, history, filterPresets

    public var title: String {
        switch self {
        case .whiteBalance: "White Balance"
        case .treatment: "Treatment"
        case .baseLook: "Base Look"
        case .recipes: "Recipes"
        case .compare: "Before / After"
        case .snapshots: "Snapshots"
        case .history: "History"
        case .filterPresets: "Filter Presets"
        }
    }

    var symbol: String {
        switch self {
        case .whiteBalance: "thermometer.medium"
        case .treatment: "circle.lefthalf.filled"
        case .baseLook: "camera.filters"
        case .recipes: "wand.and.stars"
        case .compare: "rectangle.2.swap"
        case .snapshots: "camera"
        case .history: "clock.arrow.circlepath"
        case .filterPresets: "line.3.horizontal.decrease.circle"
        }
    }

    var keywords: [String] {
        switch self {
        case .whiteBalance: ["wb", "temperature", "preset", "daylight", "tungsten"]
        case .treatment: ["color", "black and white", "b&w", "monochrome"]
        case .baseLook: ["profile", "look", "film", "lut"]
        case .recipes: ["preset", "presets", "look", "film", "style"]
        case .compare: ["compare", "before", "after", "split", "side by side"]
        case .snapshots: ["snapshot", "saved"]
        case .history: ["undo", "steps", "revert"]
        case .filterPresets: ["filter", "saved filter", "preset", "search", "library"]
        }
    }

    /// Whether moving through the page previews each choice on the photo.
    var previews: Bool {
        self != .compare && self != .filterPresets
    }
}

/// What a palette row does.
@_spi(Harness) public enum PaletteItemKind: Hashable, Sendable {
    case action(ShortcutAction)
    case slider(ParameterID)
    case page(PalettePage)
    /// Typed in the search: "exposure 0.7".
    case setValue(ParameterID, Double)
    case whiteBalance(WhiteBalanceMode)
    case treatment(Treatment)
    case baseLook(String)
    case recipe(String)
    /// `nil` turns Before / After off.
    case compareLayout(CompareLayout?)
    case snapshot(UUID)
    case historyStep(Int)
    /// A saved filter of the Library filter bar, by its preset's ID.
    case filterPreset(String)
    /// A custom label, by its name, on the photos a label's key reaches (LIB-15).
    case customLabel(String)

    /// What ↵ does, for the hint bar.
    var verb: String {
        switch self {
        case .action: "Run"
        case .slider: "Adjust"
        case .page: "Open"
        case .setValue: "Set"
        case .historyStep, .snapshot: "Go"
        default: "Apply"
        }
    }

    /// Ties in search go to pages, then sliders, actions and choices.
    var rank: Int {
        switch self {
        case .setValue: 0
        case .page: 1
        case .slider: 2
        case .action: 3
        default: 4
        }
    }

    var isChoice: Bool {
        rank == 4
    }
}

/// One row of the palette.
@_spi(Harness) public struct PaletteItem: Identifiable, Hashable, Sendable {
    public var kind: PaletteItemKind
    public var title: String
    public var context: String
    public var symbol: String
    /// Words search matches besides the title and context.
    var keywords: [String] = []

    public var id: PaletteItemKind {
        kind
    }
}

/// Rows under an optional heading.
@_spi(Harness) public struct PaletteSection: Identifiable, Sendable {
    public var title: String?
    public var items: [PaletteItem]

    public var id: String {
        title ?? ""
    }
}

/// One level of the palette's navigation stack.
@_spi(Harness) public enum PaletteLevel: Hashable, Sendable {
    /// A list of rows: the top-level search (`page` nil) or a picker.
    case list(page: PalettePage?, query: String, selection: Int)
    /// The slider bar, with what's been typed into its value field.
    case slider(ParameterID, typed: String)
}

/// The modifier keys that change what an arrow key does.
@_spi(Harness) public struct PaletteModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = PaletteModifiers(rawValue: 1)
    public static let option = PaletteModifiers(rawValue: 2)
    public static let command = PaletteModifiers(rawValue: 4)
}

/// The keys the palette handles itself; everything else edits the text.
@_spi(Harness) public enum PaletteKey: Hashable, Sendable {
    case up, down
    case left(PaletteModifiers), right(PaletteModifiers)
    case submit
    case escape
    /// ⌫ in an empty field.
    case deleteBackward
    /// ⌘⌫.
    case reset
}

@_spi(Harness) public enum PaletteCloseReason: String, Hashable, Sendable {
    case escape, toggle, clickOutside, ran, applied, done
}

@_spi(Harness) public enum PaletteBackKey: String, Hashable, Sendable {
    case escape, delete, letter
}

/// What the palette did. The harness's log and checklist, and the tests, read these.
@_spi(Harness) public enum PaletteEvent: Hashable, Sendable {
    case opened(PaletteScope)
    case closed(PaletteCloseReason)
    case scopeRemoved
    case highlighted(PaletteItemKind)
    case ran(ShortcutAction)
    case unavailable(PaletteItemKind)
    case pushed(PalettePage)
    case openedSlider(ParameterID)
    case wentBack(PaletteBackKey)
    case nudged(ParameterID, to: Double, PaletteModifiers)
    case steppedSlider(ParameterID)
    case setValue(ParameterID, Double)
    case invalidValue(String)
    case reset(ParameterID)
    case searchedFromSlider(String)
    case applied(PaletteItemKind)
    case previewed(PaletteItemKind?)
    case historyStep(String)
}
