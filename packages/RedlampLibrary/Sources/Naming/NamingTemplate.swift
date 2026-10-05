import Foundation

/// A naming template (LIB-25): the grammar renaming, importing, batch export (EDT-16) and capture
/// sessions (TET-01) share to make file names from a photo's fields, as
/// docs/plans/2026-10-05-library-design.md describes under Naming templates.
///
/// Text is kept as it is written, and tokens in braces put in a field: `{date:yyyyMMdd}-{sequence:4}`.
/// A token takes values after colons and modifiers after bars, applied left to right:
/// `{camera|lower}`, `{original|range:-4..}`, `{title|default:Untitled}`. A value holding `:`, `|`,
/// braces or spaces at its ends goes in quotes, and a quote in it is doubled: `{title|after:" - "}`.
/// A brace in the name itself is doubled: `{{` and `}}`. Backslashes have no meaning of their own, so
/// a regular expression is written as it reads: `{original|regex:"^IMG_(\d+)$":"Photo $1"}`.
///
/// `description` is the template's canonical text, which parses back to the same template.
public struct NamingTemplate: Sendable, Hashable, CustomStringConvertible {
    public enum Part: Sendable, Hashable {
        /// Text written as it is, never empty.
        case text(String)
        case token(NamingToken)
    }

    /// Adjacent texts are one part.
    public var parts: [Part]

    /// At most this many tokens, so the tokens a photo left empty fit a `NamingTokenSet`.
    public static let maximumTokens = 64

    public init(_ parts: [Part]) {
        var merged: [Part] = []
        for part in parts {
            switch (part, merged.last) {
            case let (.text(text), _) where text.isEmpty:
                continue
            case let (.text(text), .text(previous)?):
                merged[merged.count - 1] = .text(previous + text)
            default:
                merged.append(part)
            }
        }
        self.parts = merged
    }

    /// The tokens, in order: a photo's empty tokens are numbered by their place here.
    public var tokens: [NamingToken] {
        parts.compactMap { part in
            guard case let .token(token) = part else { return nil }
            return token
        }
    }

    /// The names of the job's texts the template asks for: "" for `{text}`, `shoot` for `{text:shoot}`.
    public var textNames: [String] {
        var names: [String] = []
        for token in tokens where token.field == .text {
            let name = token.arguments.first ?? ""
            if !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// The counters the template continues, by name.
    public var counterNames: [String] {
        var names: [String] = []
        for token in tokens where token.field == .counter {
            if let name = token.arguments.first, !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    public var description: String {
        parts.map { part in
            switch part {
            case let .text(text): Self.escaped(text)
            case let .token(token): token.description
            }
        }.joined()
    }

    /// Where each part is in `description`, in characters.
    public var partRanges: [Range<Int>] {
        var start = 0
        return parts.map { part in
            let length = switch part {
            case let .text(text): Self.escaped(text).count
            case let .token(token): token.description.count
            }
            defer { start += length }
            return start ..< start + length
        }
    }

    static func escaped(_ text: String) -> String {
        guard text.contains(where: { $0 == "{" || $0 == "}" }) else { return text }
        return text.replacingOccurrences(of: "{", with: "{{").replacingOccurrences(of: "}", with: "}}")
    }
}

extension NamingTemplate: Codable {
    /// A template is coded as its text.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        do {
            self = try NamingTemplate(parsing: text)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(text): \(error.message)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// A token: the field it puts in the name, the values it takes and the modifiers applied to it.
public struct NamingToken: Sendable, Hashable, CustomStringConvertible {
    public var field: NamingField
    /// As written, without quotes: a date's format, a sequence's digits, a counter's name.
    public var arguments: [String]
    public var modifiers: [NamingModifier]

    public init(_ field: NamingField, _ arguments: [String] = [], modifiers: [NamingModifier] = []) {
        self.field = field
        self.arguments = arguments
        self.modifiers = modifiers
    }

    public var description: String {
        var text = "{" + field.rawValue
        for (index, argument) in arguments.enumerated() {
            text += ":" + Self.quoted(argument, last: index == arguments.count - 1)
        }
        for modifier in modifiers {
            text += "|" + modifier.description
        }
        return text + "}"
    }

    /// `value` bare when it reads back the same, else in quotes with its quotes doubled. An empty
    /// value is written as nothing before another value, and as `""` last.
    static func quoted(_ value: String, last: Bool = true) -> String {
        guard !value.isEmpty else { return last ? "\"\"" : "" }
        let special: Set<Character> = [":", "|", "{", "}", "\""]
        guard value.contains(where: special.contains) || value.first!.isWhitespace || value.last!.isWhitespace
        else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// What a token puts in the name. Dates take a format and a zone, `{date:yyyyMMdd-HHmmss.SS:utc}`;
/// numbers take their digits, `{sequence:4}`.
public enum NamingField: String, Sendable, Hashable, CaseIterable {
    /// When the photo was taken, by the camera's clock (`taken`).
    case date
    /// When the file was last changed.
    case modified
    /// When the job runs: the day of the import, the export or the rename.
    case now
    /// The camera as the library names it: "Nikon Z 6".
    case camera
    /// The camera's maker: "Nikon".
    case make
    /// The camera's model without its maker: "Z 6".
    case model
    case lens
    case iso
    /// The f-number: "2.8" (`f`).
    case aperture
    /// The exposure time: "1-250" for 1/250 s, "2" for two seconds.
    case shutter
    /// The focal length in millimetres: "35".
    case focal
    /// In pixels, once the photo is turned upright.
    case width
    case height
    case title
    case caption
    case creator
    case copyright
    case city
    case state
    case country
    /// A place within the city: a district, a street, a building.
    case sublocation
    /// The last part of each keyword, joined by spaces or the value given (`kw`).
    case keywords
    /// 0 to 5 stars (`stars`).
    case rating
    /// The colour label's name, "Red", or a custom label's.
    case label
    /// "Pick" or "Reject".
    case flag
    /// The file's name as it is now, without its extension (`filename`).
    case name
    /// The file's name before Redlamp first renamed it, without its extension; its name now if it
    /// hasn't been renamed.
    case original
    /// The digits at the end of the original name: 1234 from IMG_1234.
    case number
    /// The file's extension, without its dot (`extension`).
    case ext
    /// The name of the photo's folder, or of the folder a number of levels above it.
    case folder
    /// The photo's number in the job, in its folder or among the photos with its extension (`seq`).
    case sequence
    /// How many photos the job names.
    case total
    /// A named counter that continues from one job and session to the next.
    case counter
    /// Text the job is given: a custom name, a shoot's name.
    case text

    /// The other names tokens go by: the query language's, and other apps'.
    public static let aliases: [String: NamingField] = [
        "taken": .date, "f": .aperture, "stars": .rating, "kw": .keywords, "keyword": .keywords, "filename": .name,
        "extension": .ext, "seq": .sequence,
    ]

    /// The field `name` names, ignoring case: its own name or an alias.
    public init?(name: String) {
        let lowered = name.lowercased()
        guard let field = NamingField(rawValue: lowered) ?? Self.aliases[lowered] else { return nil }
        self = field
    }

    /// How the template editor groups the tokens.
    public enum Category: String, Sendable, Hashable, CaseIterable {
        case dates, camera, metadata, file, numbers, text
    }

    public var category: Category {
        switch self {
        case .date, .modified, .now: .dates
        case .camera, .make, .model, .lens, .iso, .aperture, .shutter, .focal, .width, .height: .camera
        case .title, .caption, .creator, .copyright, .city, .state, .country, .sublocation, .keywords, .rating, .label,
             .flag: .metadata
        case .name, .original, .number, .ext, .folder: .file
        case .sequence, .total, .counter: .numbers
        case .text: .text
        }
    }

    /// An example of the token as it's written, for the editor's list and for error messages.
    public var example: String {
        switch self {
        case .date: "{date:yyyyMMdd-HHmmss.SS}"
        case .modified: "{modified:yyyy-MM-dd}"
        case .now: "{now:yyyyMMdd}"
        case .original: "{original:-4..}"
        case .name: "{name}"
        case .number: "{number:4}"
        case .folder: "{folder:2}"
        case .keywords: "{keywords:\"-\"}"
        case .sequence: "{sequence:4:folder}"
        case .total: "{total}"
        case .counter: "{counter:shoot:4}"
        case .text: "{text:shoot}"
        default: "{\(rawValue)}"
        }
    }
}

/// A change made to a token's value, in the order written.
public enum NamingModifier: Sendable, Hashable, CustomStringConvertible {
    case upper
    case lower
    /// Each word's first letter in capitals and the rest in small letters.
    case title
    /// Some of the value's characters.
    case range(NamingRange)
    /// Every occurrence of the first text replaced by the second, matching case.
    case replace(String, with: String)
    /// Every match of a regular expression (ICU's syntax) replaced by a template, where `$1` is
    /// the first group.
    case regex(String, with: String, ignoringCase: Bool)
    /// Text used when the value is empty; a token with a default is never flagged as empty, so
    /// `default:""` marks one that may be.
    case defaultText(String)
    /// Text put before the value, unless the value is empty.
    case before(String)
    /// Text put after the value, unless the value is empty.
    case after(String)

    /// The modifiers' names, as they're written.
    public static let names = ["upper", "lower", "title", "range", "replace", "regex", "default", "before", "after"]

    public var description: String {
        switch self {
        case .upper: "upper"
        case .lower: "lower"
        case .title: "title"
        case let .range(range): "range:\(range)"
        case let .replace(find, with):
            with.isEmpty ? "replace:\(NamingToken.quoted(find))"
                : "replace:\(NamingToken.quoted(find)):\(NamingToken.quoted(with))"
        case let .regex(pattern, with, ignoringCase):
            "regex:\(NamingToken.quoted(pattern))"
                + (with.isEmpty && !ignoringCase ? "" : ":\(NamingToken.quoted(with, last: !ignoringCase))")
                + (ignoringCase ? ":i" : "")
        case let .defaultText(text): "default:\(NamingToken.quoted(text))"
        case let .before(text): "before:\(NamingToken.quoted(text))"
        case let .after(text): "after:\(NamingToken.quoted(text))"
        }
    }
}

/// Characters by position: from 1 at the start, or from -1 at the end, both ends included and either
/// left out. `5..8` is the fifth to the eighth, `-4..` the last four, `..3` the first three, `2` the
/// second alone.
public struct NamingRange: Sendable, Hashable, CustomStringConvertible {
    public var from: Int?
    public var to: Int?

    public init(from: Int?, to: Int?) {
        self.from = from
        self.to = to
    }

    public var description: String {
        if let from, from == to {
            return String(from)
        }
        return (from.map(String.init) ?? "") + ".." + (to.map(String.init) ?? "")
    }

    /// The characters of `value` the range covers; none when it falls outside.
    func apply(to value: String) -> String {
        guard from != nil || to != nil else { return value }
        let negative = (from ?? 1) < 0 || (to ?? 1) < 0
        let count = negative ? value.count : Int.max
        func offset(_ position: Int) -> Int {
            position > 0 ? position - 1 : count + position
        }
        let start = max(from.map(offset) ?? 0, 0)
        let end = to.map { offset($0) + 1 } ?? Int.max
        guard end > start, let lower = value.index(value.startIndex, offsetBy: start, limitedBy: value.endIndex)
        else { return "" }
        let upper = end == Int.max ? value.endIndex
            : value.index(lower, offsetBy: end - start, limitedBy: value.endIndex) ?? value.endIndex
        return String(value[lower ..< upper])
    }
}

/// Why a template couldn't be read: the characters at fault and what's wrong with them.
public struct NamingTemplateError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Offsets into the template's characters.
    public let range: Range<Int>
    public let message: String

    public init(range: Range<Int>, message: String) {
        self.range = range
        self.message = message
    }

    public var description: String {
        message
    }
}
