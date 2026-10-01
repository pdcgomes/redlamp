import Foundation

/// One entry in the hint bar: "Reset ⌘ ⌫".
@_spi(Harness) public struct PaletteHint: Hashable, Sendable {
    public var title: String
    public var keys: [String]
    /// A held ⇧ or ⌥.
    public var isActive = false

    public init(_ title: String, _ keys: [String], isActive: Bool = false) {
        self.title = title
        self.keys = keys
        self.isActive = isActive
    }
}

/// Text with keycaps in it, for tips and the line beside the hint bar.
@_spi(Harness) public enum PaletteTipPart: Hashable, Sendable {
    case text(String)
    case keys([String])
}

@_spi(Harness) public extension CommandPaletteModel {
    /// The keys that work right now, for the hint bar.
    var hints: [PaletteHint] {
        switch level {
        case let .slider(_, typed):
            return [
                PaletteHint("×10", ["⇧"], isActive: heldModifiers.contains(.shift)),
                PaletteHint("Fine", ["⌥"], isActive: heldModifiers.contains(.option)),
                PaletteHint("Reset", ["⌘", "⌫"]),
                PaletteHint(typed.isEmpty ? "Done" : "Set", ["↵"]),
                PaletteHint("Back", ["Esc"]),
            ]
        case let .list(page, _, _):
            var hints: [PaletteHint] = []
            if let page, page.previews, !rows.isEmpty {
                hints.append(PaletteHint("Preview", ["↑", "↓"]))
            }
            if let item = selectedItem {
                hints.append(PaletteHint(item.kind.verb, ["↵"]))
            }
            hints.append(PaletteHint(isNested ? "Back" : "Close", ["Esc"]))
            return hints
        }
    }

    /// Beside the hint bar: a tip at the top level, where you are in a picker.
    var leading: [PaletteTipPart] {
        switch level {
        case .slider:
            return []
        case let .list(page?, _, _):
            if let title = previewingTitle {
                return [.text("\(page.title) · Previewing \(title)")]
            }
            return [.text(page.title)]
        case let .list(nil, query, _):
            if scope == .sliders, query.isEmpty {
                return [.text("Sliders only ·"), .keys(["⌫"]), .text("searches everything")]
            }
            return PaletteTips.all[tip % PaletteTips.all.count]
        }
    }
}

/// The tips the top level shows, a different one each time the palette opens: tricks no
/// single row shows.
@_spi(Harness) public enum PaletteTips {
    public static let all: [[PaletteTipPart]] = [
        [.text("Type a value after a name:"), .keys(["exposure 0.7"])],
        [.keys(["⌘", "F"]), .text("searches sliders only")],
        [.text("In a slider, type a name to jump to another")],
        [.text("Arrow through looks and recipes to preview them")],
        [.text("The keys beside a command work without the palette")],
        [.text("Hold"), .keys(["⇧"]), .text("or"), .keys(["⌥"]), .text("for bigger or finer steps")],
    ]

    static let defaultsKey = "commandPaletteNextTip"

    /// The tip to show now; the next call returns the one after it.
    public static func next(_ defaults: UserDefaults = .standard) -> Int {
        let index = defaults.integer(forKey: defaultsKey) % all.count
        defaults.set((index + 1) % all.count, forKey: defaultsKey)
        return index
    }

    /// Makes `index` the next tip shown (the harness's tip picker).
    public static func setNext(_ index: Int, _ defaults: UserDefaults = .standard) {
        defaults.set(index % all.count, forKey: defaultsKey)
    }
}

/// The palette's own keys, for the ⌘/ sheet.
@_spi(Harness) public enum PaletteKeyReference {
    public static let keys: [PaletteHint] = [
        PaletteHint("Open the command palette", ["⌘", "K"]),
        PaletteHint("Search sliders only", ["⌘", "F"]),
        PaletteHint("Move the highlight, or preview a choice", ["↑", "↓"]),
        PaletteHint("Adjust, run, open or apply", ["↵"]),
        PaletteHint("Back, or close", ["Esc"]),
        PaletteHint("Slider: step", ["←", "→"]),
        PaletteHint("Slider: ×10 or finer steps", ["⇧", "⌥"]),
        PaletteHint("Slider: previous or next slider", ["↑", "↓"]),
        PaletteHint("Slider: reset", ["⌘", "⌫"]),
        PaletteHint("Slider: done", ["↵"]),
    ]
}
