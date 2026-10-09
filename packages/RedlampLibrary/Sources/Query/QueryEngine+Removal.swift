import Foundation

/// A term of a query that finds none of a source's photos, and how many of them the query finds
/// without it (LIB-18): what the filter bar offers to take out.
public struct QueryRemoval: Sendable, Hashable {
    /// The term: one of the rules at the query's top (`QueryRules`), and its place among them.
    public let rule: QueryRules.Rule
    public let index: Int
    /// The query without it.
    public let query: LibraryQuery
    /// The source's photos the query finds without it.
    public let count: Int

    public init(rule: QueryRules.Rule, index: Int, query: LibraryQuery, count: Int) {
        self.rule = rule
        self.index = index
        self.query = query
        self.count = count
    }

    /// The term as the language writes it.
    public var term: String {
        LibraryQuery(rule).description
    }
}

public extension QueryEngine {
    /// For `query`, when it finds none of `source`'s photos: the term at its top whose removal brings
    /// back the most of them, from one count of the column store for each term; of terms that bring
    /// back as many, the one written last. Nil when the query finds photos, when no term's removal
    /// alone brings any back, or when its terms needn't all match (`OR`), since then taking one out
    /// finds fewer. `moments` is the source's Tighter–Looser setting, as `list(_:matching:sort:moments:)`
    /// takes it. Runs on the caller's task, which cancels it, as the filter bar's is when the query
    /// changes.
    func removal(
        from query: LibraryQuery, in source: PhotoSource, moments: MomentSetting = MomentSetting(),
    ) async throws -> QueryRemoval? {
        if await loadedSnapshot() == nil {
            try await load()
        }
        guard let (store, vocabulary, generation) = snapshot() else { return nil }
        let rules = QueryRules(query)
        guard rules.match != .any else { return nil }
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
        var best: QueryRemoval?
        for (index, rule) in rules.rules.enumerated() where LibraryQuery(rule).searchable != nil {
            var rest = rules
            rest.rules.remove(at: index)
            let without = LibraryQuery(rest)
            let found = try await count(without)
            if found > 0, found >= best?.count ?? 0 {
                best = QueryRemoval(rule: rule, index: index, query: without, count: found)
            }
        }
        try Task.checkCancellation()
        return best
    }
}
