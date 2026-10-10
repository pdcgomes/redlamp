import Foundation

/// The library's keyword list (LIB-21): every keyword its photos have, from the index, and every
/// keyword the definitions keep, with the keywords containing them, in a hierarchy with counts.
public struct KeywordList: Sendable {
    public struct Keyword: Sendable, Hashable, Identifiable {
        public let path: KeywordPath
        /// Photos that have it.
        public let photos: Int
        /// Photos that have it or a keyword inside it, each once: the count the list shows.
        public let count: Int
        public let options: KeywordOptions
        /// The definitions keep it, so it stays in the list without photos.
        public let isDefined: Bool
        /// The keywords directly inside it, in the list's order.
        public let children: [KeywordPath]

        public var id: KeywordPath {
            path
        }

        public var name: String {
            path.name
        }
    }

    public let keywords: [KeywordPath: Keyword]
    /// The keywords at the top of the list, in its order.
    public let roots: [KeywordPath]

    /// `counts` from the index (`IndexQueries.keywordCounts`) and `definitions`. A keyword of the
    /// index that no photo has, that contains none that one has and that the definitions don't keep,
    /// is a leftover and isn't in the list.
    public init(counts: [KeywordPath: KeywordCount], definitions: KeywordDefinitions) {
        var present = Set<KeywordPath>()
        for (path, count) in counts where count.count > 0 {
            present.insert(path)
        }
        for path in definitions.keywords.keys {
            present.insert(path)
        }
        for path in Array(present) {
            present.formUnion(path.ancestors)
        }
        var children: [KeywordPath?: [KeywordPath]] = [:]
        for path in present {
            children[path.parent, default: []].append(path)
        }
        for key in Array(children.keys) {
            children[key]?.sort(by: Self.inOrder)
        }
        var keywords: [KeywordPath: Keyword] = [:]
        keywords.reserveCapacity(present.count)
        for path in present {
            let count = counts[path] ?? KeywordCount()
            keywords[path] = Keyword(
                path: path, photos: count.photos, count: count.count, options: definitions.options(path),
                isDefined: definitions.keywords[path] != nil, children: children[path] ?? [],
            )
        }
        self.keywords = keywords
        roots = children[nil] ?? []
    }

    public subscript(path: KeywordPath) -> Keyword? {
        keywords[path]
    }

    /// The keywords directly inside `parent`, or at the top of the list, in its order.
    public func children(of parent: KeywordPath?) -> [Keyword] {
        (parent.map { keywords[$0]?.children ?? [] } ?? roots).compactMap { keywords[$0] }
    }

    /// Every keyword, each before the keywords inside it, each level in the list's order.
    public var ordered: [Keyword] {
        var ordered: [Keyword] = []
        ordered.reserveCapacity(keywords.count)
        var pending = roots.reversed().compactMap { keywords[$0] }
        while let next = pending.popLast() {
            ordered.append(next)
            pending += next.children.reversed().compactMap { keywords[$0] }
        }
        return ordered
    }

    /// The keywords named `name`, ignoring case, the most used first.
    public func named(_ name: String) -> [KeywordPath] {
        guard let name = KeywordPath.canonical(name) else { return [] }
        return keywords.values.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            .sorted { ($0.count, $1.path) > ($1.count, $0.path) }.map(\.path)
    }

    /// The keyword `text` names: one at its path; else, for a single name, the keyword so named or
    /// with it as a synonym, ignoring case, the most used if several are; nil when none is.
    public func resolve(_ text: String) -> KeywordPath? {
        guard let path = KeywordPath(text) else { return nil }
        if keywords[path] != nil {
            return path
        }
        if let match = keywords.keys.first(where: { $0.text.caseInsensitiveCompare(path.text) == .orderedSame }) {
            return match
        }
        guard path.names.count == 1 else { return nil }
        if let named = named(path.name).first {
            return named
        }
        return keywords.values.filter { keyword in
            keyword.options.synonyms.contains { $0.caseInsensitiveCompare(path.name) == .orderedSame }
        }.max { ($0.count, $1.path) < ($1.count, $0.path) }?.path
    }

    /// Whether `lhs` comes before `rhs` among the keywords of one level: by their names as the Finder
    /// orders them (numbers by value, then accents, case and width), then by their texts.
    public static func inOrder(_ lhs: KeywordPath, _ rhs: KeywordPath) -> Bool {
        let order = FinderOrder.compare(lhs.name, rhs.name)
        return order != 0 ? order < 0 : lhs < rhs
    }
}
