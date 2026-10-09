import Foundation
import RedlampDocument

public extension LibraryQuery {
    /// Reads `text`, or throws its first error with the characters at fault.
    ///
    /// As you type (`asYouType`), what isn't finished at the end of the text is left out instead of
    /// being an error: a field without its value (`rating:`), a dangling `-`, `OR` or `AND`, a last
    /// value that isn't valid yet (`flag:pi`, `date:2019-0`) and a comma with nothing after it; a
    /// quote or parentheses still open at the end are taken as closed. Errors anywhere else throw.
    init(parsing text: String, asYouType: Bool = false) throws(LibraryQueryError) {
        var parser = LibraryQueryParser(text, asYouType: asYouType)
        self = try parser.parse()
    }

    /// `queries` joined by `AND`, or by `OR`: groups of the same kind are taken apart, and a single
    /// query is itself.
    static func joined(_ queries: [LibraryQuery], or: Bool) -> LibraryQuery {
        let flat = queries.flatMap { query -> [LibraryQuery] in
            switch query {
            case let .and(inner) where !or: inner
            case let .or(inner) where or: inner
            default: [query]
            }
        }
        if flat.count == 1 {
            return flat[0]
        }
        return flat.isEmpty ? .all : or ? .or(flat) : .and(flat)
    }
}

/// The grammar of docs/plans/2026-10-05-library-design.md, read by recursive descent over the
/// query's characters, so errors carry character offsets.
struct LibraryQueryParser {
    private let characters: [Character]
    private let asYouType: Bool
    private var position = 0

    init(_ text: String, asYouType: Bool) {
        characters = Array(text)
        self.asYouType = asYouType
    }

    mutating func parse() throws(LibraryQueryError) -> LibraryQuery {
        try sequence(depth: 0) ?? .all
    }

    // MARK: - Terms

    /// The terms up to the end, or to the `)` closing the group `depth` deep: runs of terms joined by
    /// `OR`, each run an `and`. Nil when nothing in it can be used yet.
    private mutating func sequence(depth: Int) throws(LibraryQueryError) -> LibraryQuery? {
        var alternatives: [[LibraryQuery]] = [[]]
        var pending: (word: String, range: Range<Int>)?
        while true {
            skipSpaces()
            if isAtEnd || characters[position] == ")" {
                if !isAtEnd, depth == 0 {
                    throw failure(position ..< position + 1, "this ) has no ( before it")
                }
                if let pending, !(asYouType && isAtEnd) {
                    throw failure(pending.range, "\(pending.word) needs a term after it")
                }
                break
            }
            let word = bareWord()
            if word.text == "OR" || word.text == "AND" {
                if pending != nil || alternatives[alternatives.count - 1].isEmpty {
                    throw failure(word.range, "\(word.text) needs a term before it")
                }
                position = word.range.upperBound
                pending = (word.text, word.range)
                if word.text == "OR" {
                    alternatives.append([])
                }
                continue
            }
            if let term = try term() {
                alternatives[alternatives.count - 1].append(term)
            }
            pending = nil
        }
        let runs = alternatives.filter { !$0.isEmpty }.map { LibraryQuery.joined($0, or: false) }
        return runs.isEmpty ? nil : LibraryQuery.joined(runs, or: true)
    }

    /// `-`, a group, quoted text, a filter or a word. Nil when it's unfinished at the end, as you type.
    private mutating func term() throws(LibraryQueryError) -> LibraryQuery? {
        let start = position
        switch characters[position] {
        case "-":
            let next = position + 1
            if next == characters.count || characters[next].isWhitespace || characters[next] == ")" {
                position = next
                if isUnfinished {
                    return nil
                }
                throw failure(start ..< next, "- needs a term after it")
            }
            position = next
            return try term().map(LibraryQuery.not)
        case "(":
            position += 1
            let inner = try sequence(depth: 1)
            if isAtEnd {
                guard asYouType else { throw failure(start ..< start + 1, "this ( isn't closed") }
                return inner
            }
            position += 1
            guard let inner else { throw failure(start ..< position, "there's nothing between these parentheses") }
            return inner
        case "\"":
            let quoted = quoted()
            if !quoted.closed, !asYouType {
                throw failure(quoted.range, "this quote isn't closed")
            }
            if quoted.text.isEmpty {
                if !quoted.closed {
                    return nil
                }
                throw failure(quoted.range, "there's nothing between these quotes")
            }
            return .text(quoted.text)
        default:
            while position < characters.count, !Self.endsWord(characters[position]), comparison(at: position) == nil {
                position += 1
            }
            let name = String(characters[start ..< position])
            guard let (comparison, length) = comparison(at: position) else { return .text(name) }
            return try filter(named: name, at: start ..< position, comparison, length: length)
        }
    }

    /// `field`, its comparison and its values, from the comparison at `position`.
    private mutating func filter(
        named name: String, at nameRange: Range<Int>, _ comparison: LibraryQuery.Comparison, length: Int,
    ) throws(LibraryQueryError) -> LibraryQuery? {
        let operatorRange = position ..< position + length
        let written = String(characters[operatorRange])
        guard !name.isEmpty else { throw failure(operatorRange, "a field's name is missing before \(written)") }
        guard let field = LibraryQuery.Field(name: name) else { throw failure(nameRange, "\(name) isn't a field") }
        if comparison.isOrdering, !field.isOrdered {
            throw failure(operatorRange, "\(name) can't be compared with \(written)")
        }
        position = operatorRange.upperBound

        guard let items = try values(named: name, at: nameRange) else { return nil }

        let reachesEnd = isUnfinished
        var values: [LibraryQuery.Value] = []
        for (index, item) in items.enumerated() {
            do {
                try values.append(LibraryQueryValues.value(item.text, for: field))
            } catch {
                if asYouType, reachesEnd, index == items.count - 1 {
                    break
                }
                throw failure(item.range, error.message)
            }
        }
        guard !values.isEmpty else { return nil }
        if comparison.isOrdering {
            if values.count > 1 {
                throw failure(
                    items[0].range.lowerBound ..< items[values.count - 1].range.upperBound,
                    "a comparison takes one value",
                )
            }
            switch values[0] {
            case .numberRange, .dateRange: throw failure(items[0].range, "a comparison takes one value, not a range")
            default: break
            }
        }
        return .filter(LibraryQuery.Filter(field, comparison, values))
    }

    /// The values written after `name`'s comparison, each with where it's written; nil when the query is being typed
    /// and none is written yet.
    private mutating func values(
        named name: String, at nameRange: Range<Int>,
    ) throws(LibraryQueryError) -> [(text: String, range: Range<Int>)]? {
        var items: [(text: String, range: Range<Int>)] = []
        while true {
            if isAtEnd || Self.endsValue(characters[position]) {
                if items.isEmpty {
                    if isUnfinished {
                        return nil
                    }
                    throw failure(nameRange.lowerBound ..< position, "\(name) needs a value")
                }
                if isUnfinished {
                    break
                }
                throw failure(position - 1 ..< position, "a value is missing after this comma")
            }
            if characters[position] == "\"" {
                let quoted = quoted()
                if !quoted.closed, !asYouType {
                    throw failure(quoted.range, "this quote isn't closed")
                }
                if quoted.text.isEmpty {
                    if !quoted.closed {
                        break
                    }
                    throw failure(quoted.range, "there's nothing between these quotes")
                }
                items.append((quoted.text, quoted.range))
            } else {
                let start = position
                while position < characters.count, !Self.endsValue(characters[position]),
                      !",\"(".contains(characters[position]) {
                    position += 1
                }
                guard position > start else {
                    throw failure(position ..< position + 1, "a value is missing before this")
                }
                items.append((String(characters[start ..< position]), start ..< position))
            }
            guard position < characters.count, characters[position] == "," else { break }
            position += 1
        }
        return items
    }

    // MARK: - Characters

    private var isAtEnd: Bool {
        position >= characters.count
    }

    /// As you type, nothing but spaces follows: what's being read is still being typed.
    private var isUnfinished: Bool {
        asYouType && characters[min(position, characters.count)...].allSatisfy(\.isWhitespace)
    }

    private mutating func skipSpaces() {
        while position < characters.count, characters[position].isWhitespace {
            position += 1
        }
    }

    /// The characters from `position` up to a space, a parenthesis or a quote, without moving on.
    private func bareWord() -> (text: String, range: Range<Int>) {
        var end = position
        while end < characters.count, !Self.endsWord(characters[end]) {
            end += 1
        }
        return (String(characters[position ..< end]), position ..< end)
    }

    /// Quoted text from the `"` at `position`, with `\"` and `\\` read as `"` and `\`, and whether
    /// its closing quote was there.
    private mutating func quoted() -> (text: String, range: Range<Int>, closed: Bool) {
        let start = position
        position += 1
        var text = ""
        while position < characters.count {
            let character = characters[position]
            if character == "\\", position + 1 < characters.count, "\"\\".contains(characters[position + 1]) {
                text.append(characters[position + 1])
                position += 2
                continue
            }
            position += 1
            if character == "\"" {
                return (text, start ..< position, true)
            }
            text.append(character)
        }
        return (text, start ..< position, false)
    }

    /// The comparison written at `index`, and how many characters it takes.
    private func comparison(at index: Int) -> (LibraryQuery.Comparison, Int)? {
        guard index < characters.count else { return nil }
        let next = index + 1 < characters.count ? characters[index + 1] : nil
        switch characters[index] {
        case ":", "=": return (.equal, 1)
        case "!": return next == "=" ? (.notEqual, 2) : nil
        case "<": return next == "=" ? (.lessOrEqual, 2) : (.less, 1)
        case ">": return next == "=" ? (.greaterOrEqual, 2) : (.greater, 1)
        default: return nil
        }
    }

    private static func endsWord(_ character: Character) -> Bool {
        character.isWhitespace || character == "(" || character == ")" || character == "\""
    }

    private static func endsValue(_ character: Character) -> Bool {
        character.isWhitespace || character == ")"
    }

    private func failure(_ range: Range<Int>, _ message: String) -> LibraryQueryError {
        let lower = min(range.lowerBound, characters.count)
        return LibraryQueryError(range: lower ..< max(lower, min(range.upperBound, characters.count)), message: message)
    }
}

/// What each field's values may be.
enum LibraryQueryValues {
    struct Invalid: Error {
        let message: String
    }

    static func value(_ text: String, for field: LibraryQuery.Field) throws(Invalid) -> LibraryQuery.Value {
        switch field {
        case .rating, .iso, .aperture, .focal, .shutter, .megapixels, .aspect:
            try numeric(text, for: field)
        case .date:
            try dates(text)
        case .trait, .flag, .label, .marked, .edited, .missing, .offline, .unreadable:
            try word(text, for: field)
        case .has, .orientation, .ext:
            try attribute(text, for: field)
        case .keyword, .camera, .lens, .folder, .name, .collection, .title, .caption, .creator, .copyright,
             .sublocation, .city, .state, .country, .countryCode:
            .text(text)
        }
    }

    /// A numeric field's number, or range of numbers.
    private static func numeric(_ text: String, for field: LibraryQuery.Field) throws(Invalid) -> LibraryQuery.Value {
        switch field {
        case .rating:
            return try numbers(text, invalid: "rating is a whole number from 0 to 5") { part in
                part.count == 1 ? Int(part).flatMap { (0 ... 5).contains($0) ? Double($0) : nil } : nil
            }
        case .iso:
            return try numbers(text, invalid: "iso is a number, or a range such as 100..800") { number($0, unit: nil) }
        case .aperture:
            return try numbers(text, invalid: "f is a number, or a range such as 1.4..2.8") { number($0, unit: nil) }
        case .focal:
            return try numbers(text, invalid: "focal is millimetres, or a range such as 24..70") {
                number($0, unit: "mm")
            }
        case .shutter:
            return try numbers(text, invalid: "shutter is seconds, such as 1/250 or 2, or a range") {
                number($0, unit: "s")
            }
        case .megapixels:
            return try numbers(text, invalid: "megapixels is a number, such as 24, or a range such as 24..45") {
                number($0, unit: "mp")
            }
        case .aspect:
            return try numbers(
                text,
                invalid: "aspect is the long side over the short, such as 1.5 or 3:2, or a range",
            ) {
                ratio($0)
            }
        default:
            throw Invalid(message: "\(field.rawValue) isn't a number")
        }
    }

    /// A trait, a flag, a label or yes or no.
    private static func word(_ text: String, for field: LibraryQuery.Field) throws(Invalid) -> LibraryQuery.Value {
        let lowered = text.lowercased()
        switch field {
        case .trait:
            guard let trait = LibraryQuery.Trait(rawValue: lowered) else {
                let names = LibraryQuery.Trait.allCases.map(\.rawValue)
                throw Invalid(
                    message: "is takes a trait: \(names.dropLast().joined(separator: ", ")) or \(names.last ?? "")",
                )
            }
            return .trait(trait)
        case .flag:
            switch lowered {
            case "pick": return .flag(.pick)
            case "reject": return .flag(.reject)
            case "none": return .flag(nil)
            default: throw Invalid(message: "flag is pick, reject or none")
            }
        case .label:
            if lowered == "none" {
                return .label(nil)
            }
            return ColorLabel(rawValue: lowered).map { .label($0) } ?? .text(text)
        case .marked, .edited, .missing, .offline, .unreadable:
            switch lowered {
            case "yes": return .bool(true)
            case "no": return .bool(false)
            default: throw Invalid(message: "\(field.rawValue) is yes or no")
            }
        default:
            return .text(text)
        }
    }

    /// A detail a photo has, an orientation or a kind of file.
    private static func attribute(_ text: String, for field: LibraryQuery.Field) throws(Invalid) -> LibraryQuery.Value {
        let lowered = text.lowercased()
        switch field {
        case .has:
            guard let detail = LibraryQuery.Detail(rawValue: lowered) else {
                throw Invalid(message: "has is gps, keywords, caption, title, xmp, creator, copyright or location")
            }
            return .detail(detail)
        case .orientation:
            if lowered == "none" {
                return .orientation(nil)
            }
            guard let orientation = PhotoOrientation(rawValue: lowered) else {
                throw Invalid(message: "orientation is landscape, portrait, square or none")
            }
            return .orientation(orientation)
        case .ext:
            if let kind = kinds[lowered] {
                return .kind(kind)
            }
            let ext = lowered.hasPrefix(".") ? String(lowered.dropFirst()) : lowered
            guard !ext.isEmpty, !ext.contains("/") else {
                throw Invalid(message: "ext is raw, jpeg, heic, tiff, png or an extension such as cr3")
            }
            return .text(ext)
        default:
            return .text(text)
        }
    }

    /// The kinds of file `ext` names, and what else they're written as.
    static let kinds: [String: PhotoRecord.Kind] = [
        "raw": .raw, "jpeg": .jpeg, "jpg": .jpeg, "heic": .heic, "heif": .heic, "tiff": .tiff, "tif": .tiff,
        "png": .png,
    ]

    /// A number, or a range of numbers with either end open, each read by `read`.
    private static func numbers(
        _ text: String, invalid: String, _ read: (Substring) -> Double?,
    ) throws(Invalid) -> LibraryQuery.Value {
        guard let separator = text.range(of: "..") else {
            guard let value = read(Substring(text)) else { throw Invalid(message: invalid) }
            return .number(value)
        }
        let lowerText = text[..<separator.lowerBound]
        let upperText = text[separator.upperBound...]
        guard !lowerText.isEmpty || !upperText.isEmpty
        else { throw Invalid(message: "a range needs a start or an end") }
        let lower = lowerText.isEmpty ? nil : read(lowerText)
        let upper = upperText.isEmpty ? nil : read(upperText)
        guard lowerText.isEmpty || lower != nil, upperText.isEmpty || upper != nil else {
            throw Invalid(message: invalid)
        }
        if let lower, let upper, lower > upper {
            throw Invalid(message: "this range runs backwards: \(lowerText) is more than \(upperText)")
        }
        return .numberRange(lower, upper)
    }

    /// A ratio of two numbers (`3:2`), or a number as `number` reads it.
    static func ratio(_ text: Substring) -> Double? {
        guard let colon = text.firstIndex(of: ":") else { return number(text, unit: nil) }
        guard let long = decimal(text[..<colon]), let short = decimal(text[text.index(after: colon)...]), short > 0
        else { return nil }
        return long / short
    }

    /// A decimal number (`2.8`, `1e-5`) or a fraction (`1/250`), with `unit` after it or not.
    static func number(_ text: Substring, unit: String?) -> Double? {
        var text = text
        if let unit, text.lowercased().hasSuffix(unit) {
            text = text.dropLast(unit.count)
        }
        guard let slash = text.firstIndex(of: "/") else { return decimal(text) }
        guard let numerator = decimal(text[..<slash]), let denominator = decimal(text[text.index(after: slash)...]),
              denominator > 0
        else { return nil }
        return numerator / denominator
    }

    /// Digits with a point or not, and an exponent or not: no sign, no `inf` or `nan`.
    private static func decimal(_ text: Substring) -> Double? {
        var digits = 0
        var points = 0
        var exponent: Substring.Index?
        for index in text.indices {
            let character = text[index]
            if character.isASCII, character.isNumber {
                digits += 1
            } else if character == ".", exponent == nil {
                points += 1
            } else if character == "e" || character == "E", exponent == nil, digits > 0 {
                exponent = index
            } else if character == "+" || character == "-", let exponent, text.index(after: exponent) == index {
                continue
            } else {
                return nil
            }
        }
        guard digits > 0, points <= 1 else { return nil }
        if let exponent {
            let power = text[text.index(after: exponent)...].drop { $0 == "+" || $0 == "-" }
            guard !power.isEmpty else { return nil }
        }
        let number = Double(text.hasSuffix(".") ? String(text) + "0" : String(text))
        return number.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func dates(_ text: String) throws(Invalid) -> LibraryQuery.Value {
        let invalid = Invalid(
            message: "dates are written 2024, 2024-06, 2024-06-01 or 2024-06-01T14:30, or today, yesterday or last:30d",
        )
        guard let separator = text.range(of: "..") else {
            guard let date = date(Substring(text), allowingLast: true) else { throw invalid }
            return .date(date)
        }
        let lowerText = text[..<separator.lowerBound]
        let upperText = text[separator.upperBound...]
        guard !lowerText.isEmpty || !upperText.isEmpty
        else { throw Invalid(message: "a range needs a start or an end") }
        let lower = lowerText.isEmpty ? nil : date(lowerText, allowingLast: false)
        let upper = upperText.isEmpty ? nil : date(upperText, allowingLast: false)
        guard lowerText.isEmpty || lower != nil, upperText.isEmpty || upper != nil else {
            if lowerText.lowercased().hasPrefix("last:") || upperText.lowercased().hasPrefix("last:") {
                throw Invalid(message: "last: can't start or end a range")
            }
            throw invalid
        }
        if let first = lower?.absoluteInterval, let last = upper?.absoluteInterval,
           first.lowerBound >= last.upperBound {
            throw Invalid(message: "this range runs backwards: \(lowerText) is after \(upperText)")
        }
        return .dateRange(lower, upper)
    }

    /// `2024`, `2024-06`, `2024-06-01`, a day and a time after a `T` (`2024-06-01T14:30`), `today`,
    /// `yesterday` or, unless in a range, `last:30d`.
    private static func date(_ text: Substring, allowingLast: Bool) -> QueryDate? {
        let lowered = text.lowercased()
        if lowered == "today" {
            return .today
        }
        if lowered == "yesterday" {
            return .yesterday
        }
        if lowered.hasPrefix("last:") {
            let span = lowered.dropFirst(5)
            guard allowingLast, let letter = span.last, let unit = QueryDate.Unit(rawValue: String(letter)),
                  isDigits(span.dropLast()), let count = Int(span.dropLast()), (1 ... 100_000).contains(count)
            else { return nil }
            return .last(count, unit)
        }
        if let separator = text.firstIndex(where: { $0 == "T" || $0 == "t" }) {
            guard case let .day(year, month, day)? = date(text[..<separator], allowingLast: false),
                  let time = time(text[text.index(after: separator)...])
            else { return nil }
            return .time(year, month, day, time)
        }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(parts.count), parts[0].count == 4, isDigits(parts[0]), let year = Int(parts[0]),
              year > 0
        else { return nil }
        guard parts.count > 1 else { return .year(year) }
        guard (1 ... 2).contains(parts[1].count), isDigits(parts[1]), let month = Int(parts[1]),
              (1 ... 12).contains(month)
        else { return nil }
        guard parts.count > 2 else { return .month(year, month) }
        guard (1 ... 2).contains(parts[2].count), isDigits(parts[2]), let day = Int(parts[2]),
              (1 ... QueryCalendar.daysInMonth(year, month)).contains(day)
        else { return nil }
        return .day(year, month, day)
    }

    /// `14`, `14:30` or `14:30:05`: an hour of one or two digits, then minutes and seconds of two.
    private static func time(_ text: Substring) -> QueryTime? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(parts.count), (1 ... 2).contains(parts[0].count), isDigits(parts[0]),
              let hour = Int(parts[0]), hour < 24
        else { return nil }
        guard parts.count > 1 else { return .hour(hour) }
        guard parts[1].count == 2, isDigits(parts[1]), let minute = Int(parts[1]), minute < 60 else { return nil }
        guard parts.count > 2 else { return .minute(hour, minute) }
        guard parts[2].count == 2, isDigits(parts[2]), let second = Int(parts[2]), second < 60 else { return nil }
        return .second(hour, minute, second)
    }

    private static func isDigits(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

private extension QueryDate {
    /// What an absolute date spans, to check a range's ends; nil for one relative to today.
    var absoluteInterval: Range<Int64>? {
        switch self {
        case .year, .month, .day, .time: interval(today: 0)
        case .today, .yesterday, .last: nil
        }
    }
}
