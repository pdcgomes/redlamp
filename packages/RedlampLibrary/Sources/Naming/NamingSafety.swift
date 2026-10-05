import Foundation

/// Names that are safe on macOS's disks, on network shares and on Windows: none of
/// `/ : \ * ? " < > |` or control characters (Finder shows a `:` as `/`, and SMB refuses all of
/// them), no invisible direction marks that make a name read differently from what it holds, no
/// leading dot (a hidden file) or space and no trailing space, no device name Windows keeps, in
/// Unicode's composed form (NFC, as APFS compares names), and no longer in UTF-8 than the limit.
struct NamingSafety: Sendable, Hashable {
    let replacement: Unicode.Scalar
    let space: Unicode.Scalar?

    init(_ options: NamingOptions) {
        replacement = options.illegalCharacters.character
        space = options.spaces?.character
    }

    /// The names Windows keeps for devices, with or without an extension.
    static let reservedNames: Set<String> = Set(["CON", "PRN", "AUX", "NUL"] + (1 ... 9).flatMap { [
        "COM\($0)",
        "LPT\($0)",
    ] })

    /// `value` with each character no name holds replaced and direction marks dropped, and whether that
    /// changed it.
    func clean(_ value: String) -> (String, changed: Bool) {
        var plain = true
        for byte in value.utf8 where byte >= 0x80 || Self.isIllegal(byte) || byte == 0x20 && space != nil {
            plain = false
            break
        }
        if plain {
            return (value, false)
        }
        var cleaned = String.UnicodeScalarView()
        var changed = false
        for scalar in value.unicodeScalars {
            if Self.isDropped(scalar) {
                changed = true
            } else if scalar.value < 0x80 && Self.isIllegal(UInt8(scalar.value)) || (0x80 ... 0x9F)
                .contains(scalar.value)
                || scalar.value == 0x2028 || scalar.value == 0x2029 {
                cleaned.append(replacement)
                changed = true
            } else if scalar == " ", let space {
                cleaned.append(space)
                changed = true
            } else {
                cleaned.append(scalar)
            }
        }
        return (String(cleaned), changed)
    }

    /// The finished base name, from clean parts: its ends trimmed, composed, kept clear of device
    /// names and cut to `maximumBytes` of UTF-8.
    func finish(_ base: String, maximumBytes: Int) -> (String, NamingAdjustments) {
        var adjustments: NamingAdjustments = []
        var name = Substring(base)
        while let first = name.unicodeScalars.first, first == "." || first.properties.isWhitespace {
            name = Substring(name.unicodeScalars.dropFirst())
            adjustments.insert(.trimmed)
        }
        while let last = name.unicodeScalars.last, last.properties.isWhitespace {
            name = Substring(name.unicodeScalars.dropLast())
            adjustments.insert(.trimmed)
        }
        var finished = String(name)
        if finished.utf8.contains(where: { $0 >= 0x80 }) {
            finished = finished.precomposedStringWithCanonicalMapping
        }
        if finished.utf8.count <= 4, Self.reservedNames.contains(finished.uppercased()) {
            finished.unicodeScalars.append(replacement)
            adjustments.insert(.reserved)
        }
        if finished.utf8.count > maximumBytes {
            finished = Self.cut(finished, toBytes: maximumBytes)
            while let last = finished.unicodeScalars.last, last.properties.isWhitespace {
                finished.unicodeScalars.removeLast()
            }
            adjustments.insert(.shortened)
        }
        return (finished, adjustments)
    }

    /// The longest start of `value` within `bytes` of UTF-8 that ends between characters.
    static func cut(_ value: String, toBytes bytes: Int) -> String {
        guard value.utf8.count > bytes else { return value }
        var used = 0
        var end = value.startIndex
        for index in value.indices {
            let next = value.index(after: index)
            let length = value.utf8.distance(from: index, to: next)
            guard used + length <= bytes else { break }
            used += length
            end = next
        }
        return String(value[..<end])
    }

    private static func isIllegal(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x00 ... 0x1F, 0x7F, UInt8(ascii: "/"), UInt8(ascii: ":"), UInt8(ascii: "\\"), UInt8(ascii: "*"),
             UInt8(ascii: "?"), UInt8(ascii: "\""), UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "|"):
            true
        default:
            false
        }
    }

    /// Marks that change which way text reads, and the byte-order mark.
    private static func isDropped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069, 0xFEFF: true
        default: false
        }
    }
}
