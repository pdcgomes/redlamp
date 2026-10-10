import Foundation

/// A Lua table as Lightroom Classic writes its smart collections' rules into the catalog (LIB-29):
/// `s = { { criteria = "rating", operation = ">=", value = 3 }, combine = "intersect" }`. The text is
/// read as data, never run: only constructors of strings, numbers, booleans and tables are taken.
struct LuaTable: Sendable, Hashable {
    /// The values without keys, in their order, `nil` among them left out.
    var items: [LuaValue] = []
    /// The values with names or other keys (`criteria = …`, `["value 2"] = …`), by their keys' text.
    var fields: [String: LuaValue] = [:]

    subscript(key: String) -> LuaValue? {
        fields[key]
    }

    /// The text of `key`'s value, a number's as Lua would print a whole number.
    func text(_ key: String) -> String? {
        switch fields[key] {
        case let .string(text): text
        case let .number(number): number.rounded() == number && abs(number) < 1e15 ? String(Int64(number))
            : String(number)
        case let .bool(value): value ? "true" : "false"
        case .table, nil: nil
        }
    }

    func number(_ key: String) -> Double? {
        switch fields[key] {
        case let .number(number): number
        case let .string(text): Double(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }
}

indirect enum LuaValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case table(LuaTable)

    var table: LuaTable? {
        if case let .table(table) = self {
            return table
        }
        return nil
    }
}

/// Why a Lua table's text couldn't be read, and where.
struct LuaTableError: Error, Sendable, Hashable, CustomStringConvertible {
    let message: String
    /// The byte the reading stopped at.
    let offset: Int

    var description: String {
        "\(message) at byte \(offset)"
    }
}

extension LuaTable {
    /// Tables inside tables deeper than this are refused, so text made to nest without end can't exhaust the stack.
    static let deepest = 64

    /// The table `text` holds: `{ … }`, or one assigned to a name (`s = { … }`) or returned (`return { … }`),
    /// with comments and spaces around it.
    init(parsing text: String) throws(LuaTableError) {
        var reader = LuaReader(Array(text.utf8))
        self = try reader.document()
    }
}

/// Reads a table constructor from UTF-8 bytes, one token at a time.
private struct LuaReader {
    let bytes: [UInt8]
    var at = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func document() throws(LuaTableError) -> LuaTable {
        skipSpace()
        if word(at: at) == "return" {
            at += 6
        } else if let name = word(at: at) {
            let start = at
            at += name.utf8.count
            skipSpace()
            guard peek == UInt8(ascii: "=") else { throw LuaTableError(message: "a table was expected", offset: start) }
            at += 1
        }
        skipSpace()
        guard peek == UInt8(ascii: "{") else { throw LuaTableError(message: "a table was expected", offset: at) }
        let table = try table(depth: 0)
        skipSpace()
        if peek == UInt8(ascii: ";") {
            at += 1
            skipSpace()
        }
        guard at == bytes.count else { throw LuaTableError(message: "text after the table", offset: at) }
        return table
    }

    private var peek: UInt8? {
        at < bytes.count ? bytes[at] : nil
    }

    // MARK: - Values

    private mutating func table(depth: Int) throws(LuaTableError) -> LuaTable {
        guard depth < LuaTable.deepest else { throw LuaTableError(message: "tables nested too deeply", offset: at) }
        at += 1
        var table = LuaTable()
        var positional: [Int: LuaValue] = [:]
        var next = 1
        while true {
            skipSpace()
            guard let byte = peek else { throw LuaTableError(message: "the table isn't closed", offset: at) }
            if byte == UInt8(ascii: "}") {
                at += 1
                break
            }
            if byte == UInt8(ascii: "[") && !isLongBracket(at) {
                at += 1
                skipSpace()
                let key = try value(depth: depth)
                skipSpace()
                try expect("]")
                skipSpace()
                try expect("=")
                let value = try value(depth: depth)
                switch key {
                case let .number(number) where number.rounded() == number && number >= 1 && number < 1e9:
                    if let value {
                        positional[Int(number)] = value
                    }
                case let .some(key):
                    if let value, let text = Self.keyText(key) {
                        table.fields[text] = value
                    }
                case nil:
                    throw LuaTableError(message: "a key can't be nil", offset: at)
                }
            } else if let name = word(at: at), !["nil", "true", "false"].contains(name), isAssignment(after: name) {
                at += name.utf8.count
                skipSpace()
                try expect("=")
                if let value = try value(depth: depth) {
                    table.fields[name] = value
                }
            } else {
                if let value = try value(depth: depth) {
                    positional[next] = value
                }
                next += 1
            }
            skipSpace()
            if peek == UInt8(ascii: ",") || peek == UInt8(ascii: ";") {
                at += 1
            } else if peek != UInt8(ascii: "}") {
                throw LuaTableError(message: "a comma or the table's end was expected", offset: at)
            }
        }
        table.items = positional.sorted { $0.key < $1.key }.map(\.value)
        return table
    }

    /// A value; nil for `nil`.
    private mutating func value(depth: Int) throws(LuaTableError) -> LuaValue? {
        skipSpace()
        guard let byte = peek else { throw LuaTableError(message: "a value was expected", offset: at) }
        switch byte {
        case UInt8(ascii: "{"):
            return try .table(table(depth: depth + 1))
        case UInt8(ascii: "\""), UInt8(ascii: "'"):
            return try .string(quoted())
        case UInt8(ascii: "["):
            guard isLongBracket(at) else { break }
            return try .string(long())
        case UInt8(ascii: "-"):
            at += 1
            skipSpace()
            guard let value = try value(depth: depth), case let .number(number) = value else {
                throw LuaTableError(message: "only a number can be negative", offset: at)
            }
            return .number(-number)
        case UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "."):
            return try .number(number())
        default:
            if let name = word(at: at) {
                at += name.utf8.count
                switch name {
                case "nil": return nil
                case "true": return .bool(true)
                case "false": return .bool(false)
                default: throw LuaTableError(message: "“\(name)” isn't a value", offset: at - name.utf8.count)
                }
            }
        }
        throw LuaTableError(message: "a value was expected", offset: at)
    }

    private static func keyText(_ key: LuaValue) -> String? {
        switch key {
        case let .string(text): text
        case let .number(number): String(number)
        case let .bool(value): value ? "true" : "false"
        case .table: nil
        }
    }

    private mutating func number() throws(LuaTableError) -> Double {
        let start = at
        if bytes[at] == UInt8(ascii: "0"), at + 1 < bytes.count, bytes[at + 1] | 0x20 == UInt8(ascii: "x") {
            at += 2
            let digits = at
            while let byte = peek, Self.hexValue(byte) != nil {
                at += 1
            }
            guard at > digits, let value = UInt64(String(decoding: bytes[digits ..< at], as: UTF8.self), radix: 16)
            else { throw LuaTableError(message: "a number was expected", offset: start) }
            return Double(value)
        }
        while let byte = peek, Self.isDigit(byte) || byte == UInt8(ascii: ".") {
            at += 1
        }
        if let byte = peek, byte | 0x20 == UInt8(ascii: "e") {
            at += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") {
                at += 1
            }
            while let byte = peek, Self.isDigit(byte) {
                at += 1
            }
        }
        guard let value = Double(String(decoding: bytes[start ..< at], as: UTF8.self)) else {
            throw LuaTableError(message: "a number was expected", offset: start)
        }
        return value
    }

    /// A string in quotes, its escapes read as Lua reads them.
    private mutating func quoted() throws(LuaTableError) -> String {
        let quote = bytes[at]
        let start = at
        at += 1
        var text: [UInt8] = []
        while true {
            guard let byte = peek, byte != UInt8(ascii: "\n") else {
                throw LuaTableError(message: "the string isn't closed", offset: start)
            }
            at += 1
            if byte == quote {
                break
            }
            guard byte == UInt8(ascii: "\\") else {
                text.append(byte)
                continue
            }
            guard let escaped = peek else { throw LuaTableError(message: "the string isn't closed", offset: start) }
            at += 1
            switch escaped {
            case UInt8(ascii: "n"): text.append(0x0A)
            case UInt8(ascii: "t"): text.append(0x09)
            case UInt8(ascii: "r"): text.append(0x0D)
            case UInt8(ascii: "a"): text.append(0x07)
            case UInt8(ascii: "b"): text.append(0x08)
            case UInt8(ascii: "f"): text.append(0x0C)
            case UInt8(ascii: "v"): text.append(0x0B)
            case UInt8(ascii: "\n"): text.append(0x0A)
            case UInt8(ascii: "z"):
                while let byte = peek, Self.isSpace(byte) {
                    at += 1
                }
            case UInt8(ascii: "x"):
                guard at + 1 < bytes.count, let high = Self.hexValue(bytes[at]), let low = Self.hexValue(bytes[at + 1])
                else { throw LuaTableError(message: "\\x needs two hexadecimal digits", offset: at) }
                text.append(high << 4 | low)
                at += 2
            case UInt8(ascii: "u"):
                try text.append(contentsOf: unicodeEscape())
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                var value = Int(escaped - UInt8(ascii: "0"))
                for _ in 0 ..< 2 {
                    guard let digit = peek, Self.isDigit(digit) else { break }
                    value = value * 10 + Int(digit - UInt8(ascii: "0"))
                    at += 1
                }
                guard value < 256 else { throw LuaTableError(message: "a decimal escape above 255", offset: at) }
                text.append(UInt8(value))
            default:
                text.append(escaped)
            }
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// `\u{XXX}`, after the `u`, as UTF-8.
    private mutating func unicodeEscape() throws(LuaTableError) -> [UInt8] {
        guard peek == UInt8(ascii: "{") else { throw LuaTableError(message: "\\u needs braces", offset: at) }
        at += 1
        var value: UInt32 = 0
        while let byte = peek, let digit = Self.hexValue(byte) {
            value = value &* 16 &+ UInt32(digit)
            at += 1
        }
        guard peek == UInt8(ascii: "}"), let scalar = Unicode.Scalar(value) else {
            throw LuaTableError(message: "\\u{…} isn't a character", offset: at)
        }
        at += 1
        return Array(String(Character(scalar)).utf8)
    }

    /// Whether a long bracket opens at `offset`: `[[` or `[`, `=`s and `[`.
    private func isLongBracket(_ offset: Int) -> Bool {
        var index = offset + 1
        while index < bytes.count, bytes[index] == UInt8(ascii: "=") {
            index += 1
        }
        return index < bytes.count && bytes[index] == UInt8(ascii: "[")
    }

    /// A long string, `[[…]]` or `[==[…]==]`, a line break straight after its opening left out.
    private mutating func long() throws(LuaTableError) -> String {
        let start = at
        at += 1
        var level = 0
        while peek == UInt8(ascii: "=") {
            level += 1
            at += 1
        }
        at += 1
        if peek == UInt8(ascii: "\r") {
            at += 1
        }
        if peek == UInt8(ascii: "\n") {
            at += 1
        }
        let contents = at
        while at < bytes.count {
            if bytes[at] == UInt8(ascii: "]"), closes(at, level: level) {
                let text = String(decoding: bytes[contents ..< at], as: UTF8.self)
                at += level + 2
                return text
            }
            at += 1
        }
        throw LuaTableError(message: "the long string isn't closed", offset: start)
    }

    private func closes(_ offset: Int, level: Int) -> Bool {
        let end = offset + level + 1
        guard end < bytes.count, bytes[end] == UInt8(ascii: "]") else { return false }
        return (offset + 1 ..< end).allSatisfy { bytes[$0] == UInt8(ascii: "=") }
    }

    // MARK: - Words, spaces and comments

    /// The name starting at `offset`, if one does.
    private func word(at offset: Int) -> String? {
        guard offset < bytes.count, Self.isNameStart(bytes[offset]) else { return nil }
        var end = offset + 1
        while end < bytes.count, Self.isNameStart(bytes[end]) || Self.isDigit(bytes[end]) {
            end += 1
        }
        return String(decoding: bytes[offset ..< end], as: UTF8.self)
    }

    /// Whether `name`, starting where the reader is, is followed by a single `=`: a field's key, not a value.
    private func isAssignment(after name: String) -> Bool {
        var copy = self
        copy.at += name.utf8.count
        copy.skipSpace()
        guard copy.peek == UInt8(ascii: "=") else { return false }
        return copy.at + 1 >= bytes.count || bytes[copy.at + 1] != UInt8(ascii: "=")
    }

    private mutating func expect(_ character: Character) throws(LuaTableError) {
        skipSpace()
        guard let ascii = character.asciiValue, peek == ascii else {
            throw LuaTableError(message: "“\(character)” was expected", offset: at)
        }
        at += 1
    }

    mutating func skipSpace() {
        while let byte = peek {
            if Self.isSpace(byte) {
                at += 1
            } else if byte == UInt8(ascii: "-"), at + 1 < bytes.count, bytes[at + 1] == UInt8(ascii: "-") {
                at += 2
                if peek == UInt8(ascii: "["), isLongBracket(at), (try? long()) != nil {
                    continue
                }
                while let byte = peek, byte != UInt8(ascii: "\n") {
                    at += 1
                }
            } else {
                return
            }
        }
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09 ... 0x0D).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
    }

    private static func isNameStart(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte | 0x20) || byte == UInt8(ascii: "_")
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
