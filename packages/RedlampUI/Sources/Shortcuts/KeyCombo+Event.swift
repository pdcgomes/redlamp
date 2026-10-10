import AppKit

extension KeyCombo {
    /// The function keys by key code, F1 to F20.
    private static let functionKeys: [UInt16: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12,
        105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
    ]

    /// The function keys the Develop key monitor reads itself (`KeyboardShortcuts`).
    static let monitoredFunctionKeys: Set<Int> = [2, 5, 6, 7, 8]

    /// A key press as the key monitor reads one: the unshifted key, so ⇧1 reads as 1 with ⇧ held, and its
    /// modifiers. Nil for a key no action can have: Return, Enter, Home, End, Page Up and Down, and keys that
    /// type nothing.
    public init?(event: NSEvent) {
        let flags = event.modifierFlags
        let key: Key
        switch event.keyCode {
        case 48: key = .tab
        case 53: key = .escape
        case 51, 117: key = .delete
        case 49: key = .space
        case 123: key = .left
        case 124: key = .right
        case 125: key = .down
        case 126: key = .up
        case 36, 76, 115, 119, 116, 121: return nil
        default:
            if let number = Self.functionKeys[event.keyCode] {
                key = .function(number)
            } else {
                guard let characters = event.characters(byApplyingModifiers: []), let first = characters.first,
                      !first.isNewline, first.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0xF700 })
                else { return nil }
                key = .character(Character(first.lowercased()))
            }
        }
        self.init(
            key, shift: flags.contains(.shift), option: flags.contains(.option), command: flags.contains(.command),
            control: flags.contains(.control),
        )
    }

    /// The modifiers held, as keycaps draw them, in the Mac's order.
    static func symbols(of flags: NSEvent.ModifierFlags) -> [String] {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }.map(\.1)
    }

    /// Whether the Develop key monitor reads the key: no ⌘ or ⌃, and not a function key it doesn't know.
    var isMonitored: Bool {
        guard !command, !control else { return false }
        if case let .function(number) = key {
            return Self.monitoredFunctionKeys.contains(number)
        }
        return true
    }

    /// ⌘ with an arrow, which text fields and lists keep for moving to a line's or a list's ends.
    var isTextNavigation: Bool {
        guard command else { return false }
        switch key {
        case .left, .right, .up, .down: return true
        default: return false
        }
    }
}
