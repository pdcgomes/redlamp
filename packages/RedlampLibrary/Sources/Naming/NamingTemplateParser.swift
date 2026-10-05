import Foundation

public extension NamingTemplate {
    /// Reads `text`, or throws its first error with the characters at fault.
    ///
    /// As you type (`asYouType`), a token still open at the end of the text is left out instead of
    /// being an error, so a preview follows what's typed; a name that isn't a token or a modifier is
    /// an error once something follows it. Errors anywhere else throw.
    init(parsing text: String, asYouType: Bool = false) throws(NamingTemplateError) {
        var parser = NamingTemplateParser(text, asYouType: asYouType)
        self = try parser.parse()
    }
}

/// The grammar of `NamingTemplate`, read over the template's characters, so errors carry character
/// offsets:
///
/// ```text
/// template := (text | token)*
/// text     := (a character but { and } | "{{" | "}}")+
/// token    := "{" name (":" value)* ("|" name (":" value)*)* "}"
/// value    := bare | quoted                    -- bare: no : | { } or ", its ends' spaces dropped
/// quoted   := '"' (a character but '"' | '""')* '"'
/// ```
struct NamingTemplateParser {
    private let characters: [Character]
    private let asYouType: Bool
    private var position = 0

    init(_ text: String, asYouType: Bool) {
        characters = Array(text)
        self.asYouType = asYouType
    }

    /// A value as written, and where.
    struct Value {
        var text: String
        var range: Range<Int>
        /// Where its text starts, past an opening quote.
        var textStart: Int
    }

    /// A name and its values, as written: a token's, or a modifier's.
    struct Call {
        var name: String
        var nameRange: Range<Int>
        var values: [Value]

        var range: Range<Int> {
            nameRange.lowerBound ..< (values.last?.range.upperBound ?? nameRange.upperBound)
        }
    }

    mutating func parse() throws(NamingTemplateError) -> NamingTemplate {
        do {
            return try template()
        } catch {
            let lower = min(error.range.lowerBound, characters.count)
            throw NamingTemplateError(
                range: lower ..< max(lower, min(error.range.upperBound, characters.count)), message: error.message,
            )
        }
    }

    private mutating func template() throws(NamingTemplateError) -> NamingTemplate {
        var parts: [NamingTemplate.Part] = []
        var text = ""
        var tokens = 0
        while position < characters.count {
            let character = characters[position]
            if character == "{" || character == "}", position + 1 < characters.count,
               characters[position + 1] == character {
                text.append(character)
                position += 2
                continue
            }
            if character == "}" {
                throw Self.failure(
                    position ..< position + 1,
                    "this } doesn't close a token; write }} for a brace in the name",
                )
            }
            guard character == "{" else {
                text.append(character)
                position += 1
                continue
            }
            let start = position
            guard let token = try token() else { break }
            tokens += 1
            if tokens > NamingTemplate.maximumTokens {
                throw Self.failure(
                    start ..< position,
                    "a template holds at most \(NamingTemplate.maximumTokens) tokens",
                )
            }
            if !text.isEmpty {
                parts.append(.text(text))
                text = ""
            }
            parts.append(.token(token))
        }
        if !text.isEmpty {
            parts.append(.text(text))
        }
        return NamingTemplate(parts)
    }

    // MARK: - Tokens

    /// The token from the `{` at `position`; nil when it's still open at the end, as you type.
    private mutating func token() throws(NamingTemplateError) -> NamingToken? {
        let start = position
        position += 1
        var field = NamingField.text
        let checkToken = { (name: String, range: Range<Int>) throws(NamingTemplateError) in
            guard let found = NamingField(name: name) else {
                let names = NamingField.allCases.map(\.rawValue) + NamingField.aliases.keys.sorted()
                throw Self.failure(range, "\(name) isn't a token" + Self.suggestion(for: name, among: names))
            }
            field = found
        }
        guard let head = try call(isToken: true, tokenStart: start, check: checkToken) else { return nil }
        let arguments = try Self.arguments(head, for: field)
        var modifiers: [NamingModifier] = []
        while true {
            guard position < characters.count else {
                if asYouType {
                    return nil
                }
                throw Self.failure(start ..< start + 1, "this { isn't closed: end the token with }")
            }
            if characters[position] == "}" {
                position += 1
                break
            }
            position += 1
            let checkModifier = { (name: String, range: Range<Int>) throws(NamingTemplateError) in
                guard NamingModifier.names.contains(name.lowercased()) else {
                    throw Self.failure(
                        range, "\(name) isn't a modifier" + Self.suggestion(for: name, among: NamingModifier.names),
                    )
                }
            }
            guard let modifier = try call(isToken: false, tokenStart: start, check: checkModifier) else { return nil }
            try modifiers.append(Self.modifier(modifier))
        }
        return NamingToken(field, arguments, modifiers: modifiers)
    }

    /// A name and its values, from `position` up to the `|` or `}` after them, with `check` run on the
    /// name once something follows it. Nil when the text ends first, as you type.
    private mutating func call(
        isToken: Bool, tokenStart: Int, check: (String, Range<Int>) throws(NamingTemplateError) -> Void,
    ) throws(NamingTemplateError) -> Call? {
        skipSpaces()
        let nameStart = position
        while position < characters.count, characters[position].isLetter || characters[position].isNumber
            || characters[position] == "_" {
            position += 1
        }
        let nameRange = nameStart ..< position
        skipSpaces()
        guard position < characters.count else {
            if asYouType {
                return nil
            }
            throw Self.failure(tokenStart ..< tokenStart + 1, "this { isn't closed: end the token with }")
        }
        if nameRange.isEmpty {
            let what = isToken ? "a token's name" : "a modifier's name"
            switch characters[position] {
            case "}" where isToken && position == tokenStart + 1:
                throw Self.failure(tokenStart ..< position + 1, "a token's name is missing between these braces")
            case ":", "|", "}":
                throw Self.failure(position ..< position + 1, "\(what) is missing before this \(characters[position])")
            default:
                throw Self.failure(
                    position ..< position + 1, "\(what) is a word, such as \(isToken ? "camera" : "upper")",
                )
            }
        }
        let name = String(characters[nameRange])
        try check(name, nameRange)
        guard ":|}".contains(characters[position]) else {
            throw Self.failure(position ..< position + 1, "after \(name) comes :, | or }")
        }
        var values: [Value] = []
        while characters[position] == ":" {
            position += 1
            guard let value = try value(tokenStart: tokenStart) else { return nil }
            values.append(value)
        }
        return Call(name: name, nameRange: nameRange, values: values)
    }

    /// A value from `position`, quoted or bare, up to the `:`, `|` or `}` after it. Nil when the text
    /// ends first, as you type.
    private mutating func value(tokenStart: Int) throws(NamingTemplateError) -> Value? {
        skipSpaces()
        let start = position
        var quoted: String?
        if position < characters.count, characters[position] == "\"" {
            position += 1
            var text = ""
            while true {
                guard position < characters.count else {
                    if asYouType {
                        return nil
                    }
                    throw Self.failure(start ..< position, "this quote isn't closed")
                }
                if characters[position] == "\"" {
                    if position + 1 < characters.count, characters[position + 1] == "\"" {
                        text.append("\"")
                        position += 2
                        continue
                    }
                    position += 1
                    break
                }
                text.append(characters[position])
                position += 1
            }
            quoted = text
        }
        let end = position
        if quoted != nil {
            skipSpaces()
        } else {
            while position < characters.count, !":|}".contains(characters[position]) {
                switch characters[position] {
                case "{":
                    throw Self.failure(position ..< position + 1, "a { can only be in a value in quotes")
                case "\"":
                    throw Self.failure(
                        position ..< position + 1, "a quote can't be inside a value: put the whole value in quotes",
                    )
                default:
                    position += 1
                }
            }
        }
        guard position < characters.count else {
            if asYouType {
                return nil
            }
            throw Self.failure(tokenStart ..< tokenStart + 1, "this { isn't closed: end the token with }")
        }
        guard ":|}".contains(characters[position]) else {
            throw Self.failure(position ..< position + 1, "after a value in quotes comes :, | or }")
        }
        if let quoted {
            return Value(text: quoted, range: start ..< end, textStart: start + 1)
        }
        var lower = start
        var upper = position
        while lower < upper, characters[lower].isWhitespace {
            lower += 1
        }
        while upper > lower, characters[upper - 1].isWhitespace {
            upper -= 1
        }
        return Value(
            text: String(characters[lower ..< upper]), range: lower == upper ? start ..< start : lower ..< upper,
            textStart: lower,
        )
    }

    // MARK: - Checking tokens and modifiers

    /// `call`'s values, once each is checked for `field`.
    private static func arguments(_ call: Call, for field: NamingField) throws(NamingTemplateError) -> [String] {
        let values = call.values
        func most(_ count: Int, _ what: String) throws(NamingTemplateError) {
            guard values.count > count else { return }
            throw failure(values[count].range.lowerBound - 1 ..< values[values.count - 1].range.upperBound, what)
        }
        switch field {
        case .date, .modified, .now:
            try most(2, "\(field.rawValue) takes a format and a zone, as in {\(field.rawValue):yyyyMMdd-HHmmss:utc}")
            if let format = values.first, !format.text.isEmpty {
                do {
                    _ = try NamingDateFormat(parsing: format.text)
                } catch {
                    let at = format.textStart + error.offset
                    throw failure(at ..< at + error.length, error.message)
                }
            }
            if values.count > 1, NamingZone(parsing: values[1].text) == nil {
                throw failure(
                    values[1].range,
                    "\(values[1].text) isn't a zone: write camera, local, utc, an offset such as +05:30, "
                        + "or a zone such as Europe/Lisbon",
                )
            }
        case .name, .original:
            try most(1, "\(field.rawValue) takes the characters to keep, as in {\(field.rawValue):-4..}")
            if let range = values.first, !range.text.isEmpty, NamingRange(parsing: range.text) == nil {
                throw failure(range.range, rangeMessage(range.text))
            }
        case .number, .total:
            try most(1, "\(field.rawValue) takes its number of digits, as in {\(field.rawValue):4}")
            try digits(values.first)
        case .sequence:
            try most(2, "sequence takes its digits and what it counts in, as in {sequence:4:folder}")
            try digits(values.first)
            if values.count > 1, NamingSequenceScope(parsing: values[1].text) == nil {
                throw failure(
                    values[1].range,
                    "a sequence counts in the job, folder or extension, as in {sequence:4:folder}",
                )
            }
        case .counter:
            try most(2, "counter takes its name and digits, as in {counter:shoot:4}")
            guard let name = values.first, !name.text.isEmpty else {
                throw failure(
                    call.range,
                    "counter needs a name, as in {counter:shoot:4}: each name keeps its own count",
                )
            }
            try digits(values.count > 1 ? values[1] : nil)
        case .folder:
            try most(1, "folder takes how many levels up the folder is, as in {folder:2} for its parent")
            if let level = values.first, !level.text.isEmpty {
                guard level.text.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(level.text),
                      (1 ... 64).contains(number)
                else {
                    throw failure(level.range, "a folder's level is 1 for its own folder, 2 for its parent, and so on")
                }
            }
        case .keywords:
            try most(1, "keywords takes the text to put between them, as in {keywords:\"-\"}")
        case .text:
            try most(1, "text takes the name of the job's text, as in {text:shoot}")
        default:
            try most(0, "{\(field.rawValue)} takes no value")
        }
        return values.map(\.text)
    }

    private static func digits(_ value: Value?) throws(NamingTemplateError) {
        guard let value, !value.text.isEmpty else { return }
        guard value.text.allSatisfy({ $0.isASCII && $0.isNumber }), let digits = Int(value.text),
              (1 ... NamingNumbers.maximumDigits).contains(digits)
        else {
            throw failure(
                value.range,
                "the digits are a number from 1 to \(NamingNumbers.maximumDigits), as in {sequence:4} for 0001",
            )
        }
    }

    private static func rangeMessage(_ text: String) -> String {
        "\(text) isn't a range: write 5..8, 5.., ..3 or -4.., counting from 1 at the start or from -1 at the end"
    }

    private static func modifier(_ call: Call) throws(NamingTemplateError) -> NamingModifier {
        let values = call.values
        let name = call.name.lowercased()
        func count(_ allowed: ClosedRange<Int>, _ usage: String) throws(NamingTemplateError) {
            guard !allowed.contains(values.count) else { return }
            throw failure(call.range, usage)
        }
        switch name {
        case "upper", "lower", "title":
            try count(0 ... 0, "\(name) takes no value")
            return name == "upper" ? .upper : name == "lower" ? .lower : .title
        case "range":
            try count(1 ... 1, "range takes the characters to keep, as in range:-4..")
            guard let range = NamingRange(parsing: values[0].text) else {
                throw failure(values[0].range, rangeMessage(values[0].text))
            }
            return .range(range)
        case "replace":
            try count(1 ... 2, "replace takes the text to find and the text to put instead, as in replace:IMG_:Photo-")
            guard !values[0].text.isEmpty else { throw failure(values[0].range, "the text to replace is missing") }
            return .replace(values[0].text, with: values.count > 1 ? values[1].text : "")
        case "regex":
            try count(
                1 ... 3,
                "regex takes a pattern, what to put instead and i to ignore case, as in regex:\"^IMG_\":\"\":i",
            )
            guard !values[0].text.isEmpty else { throw failure(values[0].range, "the regular expression is missing") }
            let ignoringCase = values.count > 2
            if ignoringCase, values[2].text.lowercased() != "i" {
                throw failure(values[2].range, "the last value of regex is i, to ignore case")
            }
            guard (try? NSRegularExpression(pattern: values[0].text)) != nil else {
                throw failure(values[0].range, "this regular expression isn't valid")
            }
            return .regex(values[0].text, with: values.count > 1 ? values[1].text : "", ignoringCase: ignoringCase)
        default:
            try count(1 ... 1, "\(name) takes its text, as in \(name):\(name == "default" ? "Untitled" : "\" - \"")")
            let text = values[0].text
            return name == "default" ? .defaultText(text) : name == "before" ? .before(text) : .after(text)
        }
    }

    // MARK: - Characters

    private mutating func skipSpaces() {
        while position < characters.count, characters[position].isWhitespace {
            position += 1
        }
    }

    private static func failure(_ range: Range<Int>, _ message: String) -> NamingTemplateError {
        NamingTemplateError(
            range: max(range.lowerBound, 0) ..< max(range.lowerBound, range.upperBound, 0),
            message: message,
        )
    }

    /// "; did you mean camera?" when one of `names` is a few edits from `word`.
    static func suggestion(for word: String, among names: [String]) -> String {
        let lowered = Array(word.lowercased())
        guard lowered.count >= 3 else { return "" }
        let scored = names.filter { $0.count >= 3 }.map { name in (name, distance(lowered, Array(name))) }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 <= min(2, lowered.count / 2) else { return "" }
        return "; did you mean \(best.0)?"
    }

    /// Levenshtein's edit distance.
    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0 ... b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            for (j, y) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}

extension NamingRange {
    /// `5..8`, `5..`, `..3`, `-4..` or `2`; nil for anything else, a position of 0, or a range that
    /// runs backwards.
    init?(parsing text: String) {
        func position(_ text: Substring) -> Int?? {
            guard !text.isEmpty else { return .some(nil) }
            let digits = text.first == "-" ? text.dropFirst() : text
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(text),
                  number != 0
            else { return nil }
            return .some(number)
        }
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let separator = text.range(of: "..") else {
            guard let single = position(Substring(text)), let single else { return nil }
            self.init(from: single, to: single)
            return
        }
        guard let from = position(text[..<separator.lowerBound]), let to = position(text[separator.upperBound...]),
              from != nil || to != nil
        else { return nil }
        if let from, let to, from.signum() == to.signum(), from > to {
            return nil
        }
        self.init(from: from, to: to)
    }
}

/// What a sequence counts in.
enum NamingSequenceScope: Sendable, Hashable {
    case job, folder, fileExtension

    init?(parsing text: String) {
        switch text.lowercased() {
        case "", "job": self = .job
        case "folder": self = .folder
        case "ext", "extension": self = .fileExtension
        default: return nil
        }
    }
}
