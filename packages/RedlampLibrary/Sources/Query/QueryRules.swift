import Foundation

/// A query as rows of rules, as the filter bar's attributes and columns and a smart collection's
/// editor show it (LIB-06, LIB-18): photos matching all, any or none of the rules, each rule free
/// text, a filter or a group of rules of its own. The text and rule forms convert into each other:
/// `LibraryQuery(rules)` and `QueryRules(query)`, and a query the parser read comes back from its
/// rules as it was.
public struct QueryRules: Sendable, Hashable {
    public enum Match: String, Sendable, Hashable, CaseIterable {
        case all, any, none
    }

    public enum Rule: Sendable, Hashable {
        /// Free text, which a photo contains or, with `contains` false, doesn't.
        case text(String, contains: Bool)
        /// A filter, or with `negated` the photos it leaves out (`-flag:reject`).
        case filter(LibraryQuery.Filter, negated: Bool)
        case group(QueryRules)
    }

    public var match: Match
    public var rules: [Rule]

    public init(match: Match = .all, rules: [Rule] = []) {
        self.match = match
        self.rules = rules
    }

    /// `query`'s rules: an `AND` matches all of its terms, an `OR` any, and `-` before an `OR` none.
    public init(_ query: LibraryQuery) {
        switch query {
        case .all:
            self.init()
        case let .and(queries):
            self.init(match: .all, rules: queries.map(Rule.init))
        case let .or(queries):
            self.init(match: .any, rules: queries.map(Rule.init))
        case let .not(.or(queries)):
            self.init(match: .none, rules: queries.map(Rule.init))
        default:
            self.init(match: .all, rules: [Rule(query)])
        }
    }

    /// The rules read from `text`, as the parser reads it.
    public init(parsing text: String, asYouType: Bool = false) throws(LibraryQueryError) {
        try self.init(LibraryQuery(parsing: text, asYouType: asYouType))
    }

    /// The filters at the top that are on `field` and keep photos (not `-`), with where each is.
    public func filters(on field: LibraryQuery.Field) -> [(index: Int, filter: LibraryQuery.Filter)] {
        guard match == .all else { return [] }
        return rules.enumerated().compactMap { index, rule in
            guard case let .filter(filter, negated: false) = rule, filter.field == field else { return nil }
            return (index, filter)
        }
    }

    /// These rules with the top's filters on `field` that keep photos replaced by `filter` where the
    /// first of them was, or at the end; nil takes them out. Rules that don't all have to match become a
    /// group of their own first, so the new filter narrows what they find.
    public func replacingFilters(on field: LibraryQuery.Field, with filter: LibraryQuery.Filter?) -> QueryRules {
        var rules = self
        if match != .all, !self.rules.isEmpty {
            rules = QueryRules(match: .all, rules: [.group(self)])
        }
        let existing = rules.filters(on: field).map(\.index)
        var place = existing.first ?? rules.rules.count
        for index in existing.reversed() {
            rules.rules.remove(at: index)
        }
        place = min(place, rules.rules.count)
        if let filter {
            rules.rules.insert(.filter(filter, negated: false), at: place)
        }
        return QueryRules(LibraryQuery(rules))
    }
}

public extension QueryRules.Rule {
    /// `query` as one rule: text and filters, `-` before either, and a group for anything else.
    init(_ query: LibraryQuery) {
        switch query {
        case let .text(text): self = .text(text, contains: true)
        case let .not(.text(text)): self = .text(text, contains: false)
        case let .filter(filter): self = .filter(filter, negated: false)
        case let .not(.filter(filter)): self = .filter(filter, negated: true)
        case .all, .and, .or, .not(.or): self = .group(QueryRules(query))
        case let .not(inner): self = .group(QueryRules(match: .none, rules: [QueryRules.Rule(inner)]))
        }
    }
}

public extension LibraryQuery {
    /// The query `rules` make: an empty set of rules finds every photo.
    init(_ rules: QueryRules) {
        let queries = rules.rules.map(LibraryQuery.init)
        switch rules.match {
        case .all:
            self = .joined(queries, or: false)
        case .any:
            self = .joined(queries, or: true)
        case .none:
            self = queries.isEmpty ? .all : .not(.joined(queries, or: true))
        }
    }

    init(_ rule: QueryRules.Rule) {
        switch rule {
        case let .text(text, contains): self = contains ? .text(text) : .not(.text(text))
        case let .filter(filter, negated): self = negated ? .not(.filter(filter)) : .filter(filter)
        case let .group(rules): self = LibraryQuery(rules)
        }
    }
}

extension QueryRules: CustomStringConvertible {
    /// The rules' query as the language writes it.
    public var description: String {
        LibraryQuery(self).description
    }
}
