import Foundation

/// A term of a query that finds none of a source's photos, with a name of the library's a typo or two
/// from a word of its text put in that word's place, and how many of the photos that finds (LIB-18):
/// what the filter bar offers beside the term whose removal brings back the most ("Did you mean
/// Lisbon?").
public struct QuerySuggestion: Sendable, Hashable {
    /// The term: one of the rules at the query's top (`QueryRules`), and its place among them.
    public let rule: QueryRules.Rule
    public let index: Int
    /// The term with the name's word in place of the misspelt one.
    public let replacement: QueryRules.Rule
    /// The name's word as the library writes it: `Lisbon` for `lisbom`.
    public let name: String
    /// The typos between the word typed and the name's: 1, or 2 from eight letters.
    public let typos: Int
    /// The query with the replacement.
    public let query: LibraryQuery
    /// The source's photos it finds.
    public let count: Int

    public init(
        rule: QueryRules.Rule, index: Int, replacement: QueryRules.Rule, name: String, typos: Int,
        query: LibraryQuery, count: Int,
    ) {
        self.rule = rule
        self.index = index
        self.replacement = replacement
        self.name = name
        self.typos = typos
        self.query = query
        self.count = count
    }

    /// The replacement as the language writes it.
    public var term: String {
        LibraryQuery(replacement).description
    }
}

public extension QueryEngine {
    /// For `query`, when it finds none of `source`'s photos: a term at its top with a word, of four
    /// letters or more, letters only, a typo or two from a word of one of the library's names
    /// (`NameRanking`) that its field matches (free text: keywords, folders, cameras, lenses and
    /// places), with that word in its place, when that brings photos back. The fewest typos win, then
    /// the most photos. Nil when the query finds photos, no such word brings any back, or its terms
    /// needn't all match (`OR`). `moments` is the source's Tighter–Looser setting, as
    /// `list(_:matching:sort:moments:)` takes it. Runs on the caller's task, which cancels it, as the
    /// filter bar's is when the query changes; each word tried costs a count of the column store.
    func suggestion(
        for query: LibraryQuery, in source: PhotoSource, moments: MomentSetting = MomentSetting(),
    ) async throws -> QuerySuggestion? {
        if await loadedSnapshot() == nil {
            try await load()
        }
        guard let (store, vocabulary, generation) = snapshot() else { return nil }
        let rules = QueryRules(query)
        guard rules.match == .all else { return nil }
        let photos = try await rows(of: source, in: store, vocabulary: vocabulary, generation: generation)
        let scope = MomentScope(source: source, setting: moments)
        func count(_ query: LibraryQuery) async throws -> Int {
            try Task.checkCancellation()
            guard let searchable = query.searchable else { return photos.count }
            var found = try await matches(
                for: searchable, in: store, vocabulary: vocabulary, generation: generation, moments: scope,
            )
            found.formIntersection(photos)
            return found.count
        }
        guard !photos.isEmpty, try await count(query) == 0 else { return nil }
        let tables = [vocabulary.rankedNames(), NameTable.fixed, storeNames(of: store)]
        var tried = Set<QueryRules.Rule>()
        var best: QuerySuggestion?
        for (index, rule) in rules.rules.enumerated() {
            for word in Self.words(of: rule) {
                for match in NameRanking.typos(of: word.text, in: tables, fields: word.fields, limit: 8) {
                    guard let twin = match.twin, best.map({ match.typos <= $0.typos }) ?? true else { continue }
                    let name = Self.name(match, vocabulary: vocabulary).spelling(of: twin) ?? twin
                    let replacement = Self.parsed(word.replacing(name))
                    guard tried.insert(replacement).inserted else { continue }
                    var rest = rules
                    rest.rules[index] = replacement
                    let replaced = LibraryQuery(rest)
                    let found = try await count(replaced)
                    guard found > 0 else { continue }
                    if let best, best.typos == match.typos, best.count >= found {
                        continue
                    }
                    best = QuerySuggestion(
                        rule: rule, index: index, replacement: replacement, name: name, typos: match.typos,
                        query: replaced, count: found,
                    )
                }
            }
        }
        try Task.checkCancellation()
        return best
    }
}

extension NameRanking {
    /// The names of `fields` with a word a typo or two from `text`, whether or not others hold it as
    /// typed: by typos, then where the word is, then as ties go.
    static func typos(of text: String, in tables: [NameTable], fields: [LibraryQuery.Field], limit: Int)
        -> [RankedMatch] {
        let typed = TypedName(text)
        guard typed.typos > 0, limit > 0 else { return [] }
        let wanted = FieldSet(fields)
        let twins = Twin.closest(tables.flatMap { $0.twins(of: typed, fields: wanted.bits) }, to: typed.bytes.count)
        guard !twins.isEmpty else { return [] }
        var matches: [TwinMatch] = []
        for (number, table) in tables.enumerated() {
            table.findTwins(twins, fields: wanted, table: number, into: &matches)
        }
        var found = Found(tables: tables, limit: limit)
        found.addTypos(matches, twins: twins)
        return found.matches
    }
}

extension QueryEngine {
    /// The fields whose names free text finds photos by.
    static let textNameFields: [LibraryQuery.Field] = [
        .keyword, .folder, .camera, .lens, .city, .country, .state, .sublocation,
    ]

    /// The fields whose filters match names completion knows.
    static let nameFields: Set<LibraryQuery.Field> = [
        .keyword, .collection, .folder, .camera, .lens, .label, .city, .country, .state, .sublocation,
    ]

    /// A word of `rule` that may be a misspelt name, the fields whose names it may be, and the rule
    /// with another word in its place.
    struct MisspeltWord {
        var text: String
        var fields: [LibraryQuery.Field]
        var replacing: (String) -> QueryRules.Rule
    }

    /// The words of `rule`'s text, when it's free text a photo holds, or of its values, when it's a
    /// filter keeping photos on a field of names.
    static func words(of rule: QueryRules.Rule) -> [MisspeltWord] {
        switch rule {
        case let .text(text, contains: true):
            words(in: text).map { at, word in
                MisspeltWord(text: word, fields: textNameFields) { name in
                    .text(replacing(at, in: text, with: name), contains: true)
                }
            }
        case let .filter(filter, negated: false) where nameFields.contains(filter.field):
            filter.values.enumerated().flatMap { place, value -> [MisspeltWord] in
                guard case let .text(text) = value else { return [] }
                return words(in: text).map { at, word in
                    MisspeltWord(text: word, fields: [filter.field]) { name in
                        var changed = filter
                        changed.values[place] = .text(replacing(at, in: text, with: name))
                        return .filter(changed, negated: false)
                    }
                }
            }
        default:
            []
        }
    }

    /// The words of `text` with typos: letters only, four or more, and where each is.
    private static func words(in text: String) -> [(Range<String.Index>, String)] {
        var words: [(Range<String.Index>, String)] = []
        var start: String.Index?
        var index = text.startIndex
        while true {
            let isLetter = index < text.endIndex && text[index].isLetter
            if isLetter, start == nil {
                start = index
            } else if !isLetter, let first = start {
                let word = String(text[first ..< index])
                if TypedName(word).typos > 0 {
                    words.append((first ..< index, word))
                }
                start = nil
            }
            guard index < text.endIndex else { break }
            index = text.index(after: index)
        }
        return words
    }

    private static func replacing(_ range: Range<String.Index>, in text: String, with word: String) -> String {
        text.replacingCharacters(in: range, with: word)
    }

    /// `match`'s name, as the ranking matched its text.
    private static func name(_ match: RankedMatch, vocabulary: QueryVocabulary) -> RankedName {
        switch match.field {
        case .keyword:
            .levels(.keyword, path: match.value, others: vocabulary.names.keywordSynonyms[match.value] ?? [])
        case .collection: .levels(.collection, path: match.value)
        case .folder: .folder(match.value)
        default: RankedName(match.field, match.value)
        }
    }

    /// `rule` as the parser reads it again, so a colour's name becomes a colour.
    private static func parsed(_ rule: QueryRules.Rule) -> QueryRules.Rule {
        guard let query = try? LibraryQuery(parsing: LibraryQuery(rule).description) else { return rule }
        return QueryRules.Rule(query)
    }
}
