import Foundation
import RedlampLibrary

/// A smart collection's rules as its editor shows them (LIB-23): rows of a field, a comparison and a value,
/// matching all, any or none of them, and groups of rows of their own. They're the library's rule form
/// (`QueryRules`, LIB-06) with each filter's values as the query language writes them, so the rows and the query's
/// text convert into each other: rules read from a text give that text back.
public struct SmartRules: Sendable, Hashable {
    /// What a row looks at: any of the text the query language's free text matches, or a field.
    public enum Field: Sendable, Hashable {
        case text
        case filter(LibraryQuery.Field)
    }

    public enum Comparison: String, Sendable, Hashable, CaseIterable {
        /// Free text's.
        case contains, doesNotContain
        /// A field's: `:`, a `-` before it, and the language's other comparisons.
        case `is`, isNot, notEqual, less, lessOrEqual, greater, greaterOrEqual

        public var title: String {
            switch self {
            case .contains: "contains"
            case .doesNotContain: "doesn't contain"
            case .is: "is"
            case .isNot: "isn't"
            case .notEqual: "≠"
            case .less: "<"
            case .lessOrEqual: "≤"
            case .greater: ">"
            case .greaterOrEqual: "≥"
            }
        }

        /// The comparisons a row on `field` offers.
        public static func offered(for field: Field) -> [Comparison] {
            switch field {
            case .text: [.contains, .doesNotContain]
            case let .filter(field):
                [.is, .isNot, .notEqual] + (field.isOrdered ? [.less, .lessOrEqual, .greater, .greaterOrEqual] : [])
            }
        }

        var language: LibraryQuery.Comparison {
            switch self {
            case .contains, .doesNotContain, .is, .isNot: .equal
            case .notEqual: .notEqual
            case .less: .less
            case .lessOrEqual: .lessOrEqual
            case .greater: .greater
            case .greaterOrEqual: .greaterOrEqual
            }
        }

        init(_ comparison: LibraryQuery.Comparison, negated: Bool) {
            switch comparison {
            case .equal: self = negated ? .isNot : .is
            case .notEqual: self = .notEqual
            case .less: self = .less
            case .lessOrEqual: self = .lessOrEqual
            case .greater: self = .greater
            case .greaterOrEqual: self = .greaterOrEqual
            }
        }
    }

    /// A field, a comparison and a value, as the language writes the value (`red,blue`, `2024-06..2024-08`).
    public struct Rule: Sendable, Hashable {
        public var field: Field
        public var comparison: Comparison
        public var value: String

        public init(field: Field = .text, comparison: Comparison = .contains, value: String = "") {
            self.field = field
            self.comparison = comparison
            self.value = value
        }
    }

    public enum Row: Sendable, Hashable {
        case rule(Rule)
        case group(SmartRules)
    }

    public var match: QueryRules.Match
    public var rows: [Row]

    public init(match: QueryRules.Match = .all, rows: [Row] = []) {
        self.match = match
        self.rows = rows
    }

    /// The rules a new smart collection starts with: the photos flagged as picks.
    public static let starting = SmartRules(rows: [.rule(Rule(field: .filter(.flag), comparison: .is, value: "pick"))])

    // MARK: - From the text

    public init(_ rules: QueryRules) {
        self.init(match: rules.match, rows: rules.rules.map(Row.init))
    }

    /// The rules of `text`, as the parser reads it.
    public init(parsing text: String) throws(LibraryQueryError) {
        try self.init(QueryRules(parsing: text))
    }

    // MARK: - To the text

    /// The library's rule form; throws the first row whose value the language can't read, in words.
    public func queryRules() throws(SmartRulesError) -> QueryRules {
        var rules: [QueryRules.Rule] = []
        for (place, row) in rows.enumerated() {
            switch row {
            case let .rule(rule):
                do {
                    try rules.append(rule.queryRule())
                } catch {
                    throw SmartRulesError(path: [place], message: error.message)
                }
            case let .group(group):
                do {
                    try rules.append(.group(group.queryRules()))
                } catch {
                    throw SmartRulesError(path: [place] + error.path, message: error.message)
                }
            }
        }
        return QueryRules(match: match, rules: rules)
    }

    /// The query's text, as a smart collection keeps it.
    public func text() throws(SmartRulesError) -> String {
        try LibraryQuery(queryRules()).description
    }

    // MARK: - Editing

    /// The row at `path`: its place in each group, from the top down.
    public subscript(path: [Int]) -> Row? {
        get {
            guard let first = path.first, rows.indices.contains(first) else { return nil }
            guard path.count > 1 else { return rows[first] }
            guard case let .group(group) = rows[first] else { return nil }
            return group[Array(path.dropFirst())]
        }
        set {
            guard let first = path.first, rows.indices.contains(first) else { return }
            if path.count == 1 {
                if let newValue {
                    rows[first] = newValue
                } else {
                    rows.remove(at: first)
                }
                return
            }
            guard case var .group(group) = rows[first] else { return }
            group[Array(path.dropFirst())] = newValue
            rows[first] = .group(group)
        }
    }

    /// Puts `row` after the one at `path`, in its group; at the end of the top with an empty path.
    public mutating func insert(_ row: Row, after path: [Int]) {
        guard let last = path.last else {
            rows.append(row)
            return
        }
        guard path.count > 1 else {
            rows.insert(row, at: min(last + 1, rows.count))
            return
        }
        guard case var .group(group) = self[Array(path.dropLast())] else { return }
        group.rows.insert(row, at: min(last + 1, group.rows.count))
        self[Array(path.dropLast())] = .group(group)
    }

    /// Gives the rule at `path` `field`, keeping its comparison where the field offers it.
    public mutating func setField(_ field: Field, at path: [Int]) {
        guard case var .rule(rule)? = self[path], rule.field != field else { return }
        rule.field = field
        let offered = Comparison.offered(for: field)
        if !offered.contains(rule.comparison) {
            rule.comparison = offered[0]
        }
        self[path] = .rule(rule)
    }
}

/// Why a smart collection's rules can't make a query: the row at `path` and what's wrong with it.
public struct SmartRulesError: Error, Sendable, Hashable {
    public var path: [Int]
    public var message: String
}

extension SmartRules.Row {
    init(_ rule: QueryRules.Rule) {
        switch rule {
        case let .text(text, contains):
            self = .rule(SmartRules.Rule(field: .text, comparison: contains ? .contains : .doesNotContain, value: text))
        case let .filter(filter, negated) where negated && filter.comparison != .equal:
            // A row has one comparison: a filter left out by another than `:` is a group that matches none of it.
            self = .group(SmartRules(match: .none, rows: [Self(.filter(filter, negated: false))]))
        case let .filter(filter, negated):
            let written = filter.description
            let value = String(written.dropFirst(filter.field.rawValue.count + filter.comparison.rawValue.count))
            self = .rule(SmartRules.Rule(
                field: .filter(filter.field), comparison: SmartRules.Comparison(filter.comparison, negated: negated),
                value: value,
            ))
        case let .group(rules):
            self = .group(SmartRules(rules))
        }
    }
}

extension SmartRules.Rule {
    /// The rule as the library's rule form has it, its value read as the language reads a filter's.
    func queryRule() throws(SmartRulesError) -> QueryRules.Rule {
        let value = value.trimmingCharacters(in: .whitespaces)
        switch field {
        case .text:
            guard !value.isEmpty else { throw SmartRulesError(path: [], message: "Type the text to look for.") }
            return .text(value, contains: comparison != .doesNotContain)
        case let .filter(field):
            let title = SmartRules.title(of: field)
            guard !value.isEmpty else { throw SmartRulesError(path: [], message: "Give \(title) a value.") }
            let written = field.rawValue + comparison.language.rawValue
            let quoted = "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
            var problem: String?
            for text in [written + value, written + quoted] {
                do {
                    if case let .filter(filter) = try LibraryQuery(parsing: text) {
                        return .filter(filter, negated: comparison == .isNot)
                    }
                } catch {
                    problem = problem ?? error.message
                }
            }
            throw SmartRulesError(
                path: [],
                message: problem.map { "\(title): \($0)" } ?? "\(value) isn't a value of \(title).",
            )
        }
    }
}

public extension SmartRules {
    // swiftlint:disable cyclomatic_complexity
    /// A field's name, as the editor's pop-up shows it: a case for each field, so a new one can't go without a name.
    static func title(of field: LibraryQuery.Field) -> String {
        switch field {
        case .rating: "Rating"
        case .flag: "Flag"
        case .label: "Label"
        case .marked: "Marked"
        case .edited: "Edited"
        case .keyword: "Keyword"
        case .camera: "Camera"
        case .lens: "Lens"
        case .iso: "ISO"
        case .aperture: "Aperture"
        case .focal: "Focal Length"
        case .shutter: "Shutter Speed"
        case .date: "Capture Date"
        case .folder: "Folder"
        case .name: "File Name"
        case .ext: "File Type"
        case .collection: "Collection"
        case .has: "Has"
        case .title: "Title"
        case .caption: "Caption"
        case .missing: "Missing"
        case .offline: "Offline"
        case .unreadable: "Unreadable"
        case .creator: "Creator"
        case .copyright: "Copyright"
        case .sublocation: "Sublocation"
        case .city: "City"
        case .state: "State or Province"
        case .country: "Country"
        case .countryCode: "Country Code"
        case .megapixels: "Megapixels"
        case .aspect: "Aspect Ratio"
        case .orientation: "Orientation"
        case .trait: "Trait"
        }
    }

    // swiftlint:enable cyclomatic_complexity

    /// The fields a row offers, free text first; not whether a photo is missing, which only Library Health's Missing
    /// check lists (DEC-59).
    static let fields: [Field] = [.text] + LibraryQuery.Field.allCases.filter { $0 != .missing }.map(Field.filter)

    static func title(of field: Field) -> String {
        switch field {
        case .text: "Any Text"
        case let .filter(field): title(of: field)
        }
    }
}
