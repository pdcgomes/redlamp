import Foundation

/// A key as the preferences keep it (LIB-36): the modifiers' symbols in the Mac's order, then the unshifted
/// character or the key's name, as `⇧⌘e`, `tab`, `⌥delete`, `⌃⌘1` or `f6`.
extension KeyCombo: Codable {
    private static let names: [(String, Key)] = [
        ("tab", .tab), ("escape", .escape), ("delete", .delete), ("space", .space),
        ("left", .left), ("right", .right), ("up", .up), ("down", .down),
    ]

    public var stored: String {
        var text = ""
        if control {
            text += "⌃"
        }
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
        case let .character(character): text.append(character)
        case let .function(number): text += "f\(number)"
        default: text += Self.names.first { $0.1 == key }?.0 ?? ""
        }
        return text
    }

    public init?(stored: String) {
        var rest = Substring(stored)
        var control = false, option = false, shift = false, command = false
        while let first = rest.first, rest.count > 1, "⌃⌥⇧⌘".contains(first) {
            switch first {
            case "⌃": control = true
            case "⌥": option = true
            case "⇧": shift = true
            default: command = true
            }
            rest.removeFirst()
        }
        let key: Key
        if rest.count == 1, let character = rest.first {
            key = .character(character)
        } else if let named = Self.names.first(where: { $0.0 == rest })?.1 {
            key = named
        } else if rest.hasPrefix("f"), let number = Int(rest.dropFirst()), (1 ... 20).contains(number) {
            key = .function(number)
        } else {
            return nil
        }
        self.init(key, shift: shift, option: option, command: command, control: control)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let combo = KeyCombo(stored: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a key: \(text)")
        }
        self = combo
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stored)
    }
}
