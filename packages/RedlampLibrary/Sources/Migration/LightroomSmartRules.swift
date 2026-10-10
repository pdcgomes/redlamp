import Foundation

/// A Lightroom Classic smart collection in the library's query language (LIB-29): its rules, as the
/// catalog keeps them (`LuaTable`), each made a term, its groups matching all, any or none of them.
/// It's all or nothing: a smart collection with a rule the language can't say isn't brought across,
/// since leaving the rule out would find other photos than Lightroom's.
public struct LightroomSmartQuery: Sendable, Hashable {
    /// The query, in its canonical text; nil when a rule doesn't map.
    public var query: String?
    /// Where the query finds photos a little differently from Lightroom's rules, in words.
    public var differences: [String] = []
    /// Why it isn't brought across: each rule that doesn't map, in words.
    public var reasons: [String] = []
}

enum LightroomSmartRules {
    /// `rules`, the text of a smart collection's rules, in the query language.
    static func query(_ rules: String) -> LightroomSmartQuery {
        let table: LuaTable
        do {
            table = try LuaTable(parsing: rules)
        } catch {
            return LightroomSmartQuery(reasons: ["its rules can't be read (\(error))"])
        }
        var mapper = RuleMapper()
        let query = mapper.group(table)
        guard mapper.reasons.isEmpty, let query else {
            return LightroomSmartQuery(differences: mapper.differences, reasons: mapper.reasons)
        }
        return LightroomSmartQuery(query: query.description, differences: mapper.differences)
    }
}

/// Makes each rule a term, collecting what doesn't map and what maps with a difference.
private struct RuleMapper {
    var differences: [String] = []
    var reasons: [String] = []

    /// A group of rules: matching all of them (`intersect`), any (`union`) or none (`exclude`).
    mutating func group(_ table: LuaTable) -> LibraryQuery? {
        var terms: [LibraryQuery] = []
        for item in table.items {
            guard let rule = item.table else {
                reasons.append("a rule isn't a table of criteria")
                continue
            }
            let term = rule["criteria"] == nil && (rule["combine"] != nil || !rule.items.isEmpty)
                ? group(rule) : self.rule(rule)
            if let term {
                terms.append(term)
            }
        }
        guard !terms.isEmpty else { return .all }
        switch table.text("combine")?.lowercased() {
        case "union": return LibraryQuery.joined(terms, or: true)
        case "exclude": return .not(LibraryQuery.joined(terms, or: true))
        case "intersect", nil: return LibraryQuery.joined(terms, or: false)
        case let other?:
            reasons.append("its rules are combined as “\(other)”, which Redlamp doesn't know")
            return nil
        }
    }

    // MARK: - Rules

    private mutating func rule(_ rule: LuaTable) -> LibraryQuery? {
        let criteria = rule.text("criteria") ?? ""
        let operation = rule.text("operation") ?? "=="
        let said = Self.describe(rule)
        func unmapped(_ why: String) -> LibraryQuery? {
            reasons.append("“\(said)”: \(why)")
            return nil
        }
        switch criteria.lowercased() {
        case "rating":
            return numeric("rating", rule, said: said)
        case "pick":
            let value = rule.number("value").map { Int($0.rounded()) }
            let flag = switch value {
            case 1: "pick"
            case -1: "reject"
            case 0: "none"
            default: String?.none
            }
            guard let flag else { return unmapped("Redlamp has no such flag") }
            return equality("flag:\(flag)", operation, said: said)
        case "labelcolor":
            let value = (rule.text("value") ?? "").lowercased()
            let colours = ["red", "yellow", "green", "blue", "purple"]
            let term = colours.contains(value) ? "label:\(value)" : value == "none" ? "label:none"
                : value == "custom" || value == "other" ? "-label:none,red,yellow,green,blue,purple" : nil
            guard let term else { return unmapped("Redlamp has no label “\(value)”") }
            return equality(term, operation, said: said)
        case "labeltext":
            guard ["==", "!="].contains(operation), let name = rule.text("value").flatMap(LightroomCatalogReader.text)
            else { return unmapped("Redlamp finds a label by its whole name only") }
            return equality("label:\(Self.value(name))", operation, said: said)
        case "keywords":
            return words("kw", rule, said: said, parts: true, empty: "keywords")
        case "collection":
            return words("collection", rule, said: said, parts: true, empty: nil)
        case "folder":
            return words("in", rule, said: said, parts: false, empty: nil)
        case "filename":
            return words("name", rule, said: said, parts: false, empty: nil)
        case "all", "anysearchable", "searchable":
            return words(nil, rule, said: said, parts: false, empty: nil)
        case "title", "caption", "creator", "copyright":
            return words(criteria.lowercased(), rule, said: said, parts: false, empty: criteria.lowercased())
        case "location", "sublocation":
            return words("sublocation", rule, said: said, parts: false, empty: nil)
        case "city", "state", "country":
            return words(criteria.lowercased(), rule, said: said, parts: false, empty: nil)
        case "isocountrycode", "countrycode":
            return words("countrycode", rule, said: said, parts: false, empty: nil)
        case "camera", "cameramodel":
            return words("camera", rule, said: said, parts: false, empty: nil, exact: true)
        case "lens":
            return words("lens", rule, said: said, parts: false, empty: nil, exact: true)
        case "isospeedrating", "iso":
            return numeric("iso", rule, said: said)
        case "aperture":
            return numeric("f", rule, said: said)
        case "focallength":
            return numeric("focal", rule, said: said)
        case "shutterspeed":
            return numeric("shutter", rule, said: said)
        case "capturetime":
            return date(rule, said: said)
        case "fileformat", "filetype":
            let format = (rule.text("value") ?? "").uppercased()
            let term = switch format {
            case "RAW": "type:raw"
            case "DNG": "ext:dng"
            case "JPG", "JPEG": "type:jpeg"
            case "TIF", "TIFF": "type:tiff"
            case "PNG": "type:png"
            case "HEIC", "HEIF": "type:heic"
            case "PSD": "ext:psd"
            default: String?.none
            }
            guard let term else { return unmapped("Redlamp has no \(format.isEmpty ? "such" : format) files") }
            return equality(term, operation, said: said)
        case "aspectratio":
            let shape = (rule.text("value") ?? "").lowercased()
            guard ["portrait", "landscape", "square"].contains(shape) else {
                return unmapped("Redlamp has no shape “\(shape)”")
            }
            return equality("orientation:\(shape)", operation, said: said)
        case "hasgpsdata", "gps", "hasgps":
            let yes = ["istrue", "==", "true"].contains(operation.lowercased()) && rule.text("value") != "false"
                || rule["value"] == .bool(true)
            return parsed(yes ? "has:gps" : "-has:gps", said: said)
        default:
            return unmapped(Self.missing[criteria.lowercased()] ?? "Redlamp has no “\(criteria)” to search by")
        }
    }

    /// What Redlamp keeps nothing of, by the criteria Lightroom names it with.
    private static let missing: [String: String] = [
        "touchtime": "Redlamp keeps no edit dates",
        "hasadjustments": "Lightroom's edits stay in Lightroom",
        "developpreset": "Lightroom's edits stay in Lightroom",
        "treatment": "Lightroom's edits stay in Lightroom",
        "processversion": "Lightroom's edits stay in Lightroom",
        "importdate": "Redlamp keeps no import dates to search by",
        "copyname": "virtual copies stay in Lightroom",
        "virtualcopy": "virtual copies stay in Lightroom",
        "copystatus": "virtual copies stay in Lightroom",
        "metadatastatus": "Redlamp keeps no metadata status",
        "smartpreview": "Redlamp has no smart previews",
        "haspreview": "Redlamp has no smart previews",
        "person": "Redlamp has no faces to search by",
        "faces": "Redlamp has no faces to search by",
        "sharedtoweb": "Redlamp shares nothing to the web",
        "likes": "Redlamp shares nothing to the web",
        "comments": "Redlamp shares nothing to the web",
    ]

    // MARK: - Kinds of rules

    /// A term, or the photos without it for `!=`.
    private mutating func equality(_ term: String, _ operation: String, said: String) -> LibraryQuery? {
        switch operation {
        case "==", "=", "is": return parsed(term, said: said)
        case "!=", "isNot", "isnot": return parsed(
                term.hasPrefix("-") ? String(term.dropFirst()) : "-(\(term))",
                said: said,
            )
        default:
            reasons.append("“\(said)”: Redlamp has no “\(operation)” for it")
            return nil
        }
    }

    /// A number compared, or between two.
    private mutating func numeric(_ field: String, _ rule: LuaTable, said: String) -> LibraryQuery? {
        let operation = rule.text("operation") ?? "=="
        guard let value = Self.number(rule, "value") else {
            reasons.append("“\(said)”: its value isn't a number")
            return nil
        }
        let text = Self.format(value)
        switch operation {
        case "==", "=": return parsed("\(field):\(text)", said: said)
        case "!=": return parsed("\(field)!=\(text)", said: said)
        case ">", ">=", "<", "<=": return parsed("\(field)\(operation)\(text)", said: said)
        case "in", "between":
            guard let other = Self.number(rule, "value2") else {
                reasons.append("“\(said)”: its range has no end")
                return nil
            }
            let (low, high) = (min(value, other), max(value, other))
            return parsed("\(field):\(Self.format(low))..\(Self.format(high))", said: said)
        default:
            reasons.append("“\(said)”: Redlamp has no “\(operation)” for numbers")
            return nil
        }
    }

    /// Text: words any or all of which a field contains, or none of; or whether it's empty. `parts` says the
    /// field matches whole names (keywords, collections) where Lightroom matches parts of them too; `exact`,
    /// that Lightroom's `==` is a whole name where Redlamp's term finds it inside longer ones.
    private mutating func words(
        _ field: String?, _ rule: LuaTable, said: String, parts: Bool, empty: String?, exact: Bool = false,
    ) -> LibraryQuery? {
        let operation = rule.text("operation") ?? "any"
        let text = rule.text("value") ?? ""
        switch operation.lowercased() {
        case "empty", "notempty":
            guard let empty else {
                reasons.append("“\(said)”: Redlamp can't find where it's empty")
                return nil
            }
            return parsed(operation.lowercased() == "empty" ? "-has:\(empty)" : "has:\(empty)", said: said)
        case "beginswith", "endswith":
            reasons.append("“\(said)”: Redlamp finds text anywhere in a field, not at its start or end")
            return nil
        default:
            break
        }
        let words = Self.words(text)
        guard !words.isEmpty else { return .all }
        func term(_ word: String) -> String {
            field.map { "\($0):\(Self.value(word))" } ?? Self.value(word)
        }
        var included: [String] = []
        var excluded: [String] = []
        for word in words {
            if word.hasPrefix("!"), word.count > 1 {
                excluded.append(String(word.dropFirst()))
            } else if word.hasPrefix("+") || word.hasSuffix("+") {
                reasons.append("“\(said)”: Redlamp finds text anywhere in a field, not at its start or end")
                return nil
            } else {
                included.append(word)
            }
        }
        var terms: [String]
        switch operation.lowercased() {
        case "any", "contains":
            terms = included.isEmpty ? [] : [included.count == 1 ? term(included[0])
                : "(\(included.map(term).joined(separator: " OR ")))"]
        case "all", "words", "==", "is":
            terms = included.map(term)
        case "noneof", "notcontains", "!=":
            terms = included.map { "-" + term($0) }
        default:
            reasons.append("“\(said)”: Redlamp has no “\(operation)” for text")
            return nil
        }
        terms += excluded.map { "-" + term($0) }
        if parts, operation.lowercased() != "==" {
            differences.append("“\(said)”: Redlamp finds whole \(field == "kw" ? "keywords" : "names"), where "
                + "Lightroom also finds parts of them")
        } else if operation.lowercased() == "words" {
            differences.append("“\(said)”: Redlamp also finds the words inside longer ones")
        } else if exact, ["==", "is"].contains(operation.lowercased()) {
            differences.append("“\(said)”: Redlamp also finds longer names holding it")
        }
        return parsed(terms.joined(separator: " "), said: said)
    }

    /// Capture dates: a day, before or after one, a range, or the last days, weeks, months or years.
    private mutating func date(_ rule: LuaTable, said: String) -> LibraryQuery? {
        let operation = rule.text("operation") ?? "=="
        func day(_ key: String) -> String? {
            guard let text = rule.text(key), text.count >= 10 else { return nil }
            let day = String(text.prefix(10))
            return day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? day : nil
        }
        switch operation {
        case "today", "yesterday":
            return parsed("date:\(operation)", said: said)
        case "inLast", "inlast":
            let unit = (rule.text("value2") ?? "days").lowercased()
            let letter: String? = switch unit.prefix(1) {
            case "d": "d"
            case "w": "w"
            case "m": "m"
            case "y": "y"
            default: nil
            }
            guard let count = rule.number("value"), count >= 1, let letter else {
                reasons.append("“\(said)”: its span can't be read")
                return nil
            }
            return parsed("date:last:\(Int(count.rounded()))\(letter)", said: said)
        case "==", "!=", ">", ">=", "<", "<=":
            guard let day = day("value") else {
                reasons.append("“\(said)”: its date can't be read")
                return nil
            }
            let term = switch operation {
            case "==": "date:\(day)"
            case "!=": "-date:\(day)"
            default: "date\(operation)\(day)"
            }
            return parsed(term, said: said)
        case "in", "between":
            guard let from = day("value"), let to = day("value2") else {
                reasons.append("“\(said)”: its dates can't be read")
                return nil
            }
            return parsed("date:\(min(from, to))..\(max(from, to))", said: said)
        default:
            reasons.append("“\(said)”: Redlamp has no “\(operation)” for dates")
            return nil
        }
    }

    /// `text` parsed: the rule as a query.
    private mutating func parsed(_ text: String, said: String) -> LibraryQuery? {
        do {
            return try LibraryQuery(parsing: text)
        } catch {
            reasons.append("“\(said)”: it can't be written in Redlamp's query language (\(error.message))")
            return nil
        }
    }

    // MARK: - Words

    /// The rule as Lightroom's editor shows it, near enough: `rating >= 3`, `keywords any birds`.
    static func describe(_ rule: LuaTable) -> String {
        [rule.text("criteria"), rule.text("operation"), rule.text("value"), rule.text("value2")]
            .compactMap { $0.flatMap(LightroomCatalogReader.text) }.joined(separator: " ")
    }

    /// A text rule's words: split at commas when it has any, else at spaces.
    static func words(_ text: String) -> [String] {
        let separators: CharacterSet = text.contains(",") ? CharacterSet(charactersIn: ",") : .whitespacesAndNewlines
        return text.components(separatedBy: separators).compactMap(LightroomCatalogReader.text)
    }

    static func value(_ text: String) -> String {
        LibraryQuery.needsQuotes(text, inValue: true) ? LibraryQuery.quoted(text) : text
    }

    /// A rule's number: a fraction of a second written `1/250` too.
    static func number(_ rule: LuaTable, _ key: String) -> Double? {
        if let number = rule.number(key) {
            return number
        }
        guard let text = rule.text(key)?.trimmingCharacters(in: .whitespaces) else { return nil }
        let parts = text.split(separator: "/")
        guard parts.count == 2, let top = Double(parts[0]), let bottom = Double(parts[1]),
              bottom != 0 else { return nil }
        return top / bottom
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e9 ? String(Int(value)) : String(value)
    }
}
