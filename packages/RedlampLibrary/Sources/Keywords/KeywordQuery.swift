import Foundation

/// How the query language finds keywords (LIB-21). `kw:` takes a keyword's path or a part of one: its
/// levels (`Portugal/Lisbon`, decoded as paths are) are a run of a keyword's levels, so a keyword
/// finds the keywords inside it; and a value with a slash in it also names a keyword whose name holds
/// it (`kw:"AC/DC"`). Case doesn't count. A synonym stands for its keyword: `kw:Lisboa` finds what the
/// keyword it belongs to finds, and free text finds the keywords whose synonyms hold it. The column
/// engine and the SQL it's checked against answer through these same functions.
enum KeywordQuery {
    /// A keyword's name as terms compare it: case aside.
    static func key(_ name: some StringProtocol) -> String {
        name.utf8.allSatisfy { $0 < 0x80 } ? name.lowercased() : name.folding(options: .caseInsensitive, locale: nil)
    }

    /// Whether `kw:value` finds the keyword at `path`, synonyms aside.
    static func matches(path: String, value: String) -> Bool {
        let levels = path.split(separator: "/").map { key(KeywordPath.decode($0)) }
        if let wanted = KeywordPath(value)?.names.map(key), contains(levels, run: wanted) {
            return true
        }
        guard value.contains("/"), let name = KeywordPath.canonical(value) else { return false }
        return levels.contains(key(name))
    }

    private static func contains(_ levels: [String], run wanted: [String]) -> Bool {
        guard !wanted.isEmpty, levels.count >= wanted.count else { return false }
        return (0 ... levels.count - wanted.count).contains { start in
            levels[start ..< start + wanted.count].elementsEqual(wanted)
        }
    }

    /// Whether the keyword at `path` is the one at `owner` or inside it.
    static func isWithin(path: String, owner: String) -> Bool {
        path == owner || path.hasPrefix(owner + "/")
    }
}

/// The synonyms of the library's keywords, by keyword path, as terms look them up.
struct KeywordSynonyms: Sendable, Hashable {
    private let owners: [String: [String]]
    /// Each synonym, folded, with its keyword's path.
    private let all: [(synonym: String, owner: String)]

    init(_ synonyms: [String: [String]]) {
        var owners: [String: [String]] = [:]
        var all: [(String, String)] = []
        for (path, names) in synonyms.sorted(by: { $0.key < $1.key }) {
            for name in names {
                let key = KeywordQuery.key(name)
                owners[key, default: []].append(path)
                all.append((key, path))
            }
        }
        self.owners = owners.mapValues { Array(Set($0)).sorted() }
        self.all = all
    }

    var isEmpty: Bool {
        all.isEmpty
    }

    /// The paths of the keywords `value` is a synonym of.
    func owners(of value: String) -> [String] {
        guard !all.isEmpty, let name = KeywordPath.canonical(value) else { return [] }
        return owners[KeywordQuery.key(name)] ?? []
    }

    /// The paths of the keywords with a synonym holding `text`.
    func owners(containing text: String) -> [String] {
        guard !all.isEmpty else { return [] }
        let key = KeywordQuery.key(text)
        guard !key.isEmpty else { return [] }
        return Array(Set(all.filter { $0.synonym.contains(key) }.map(\.owner))).sorted()
    }

    static func == (lhs: KeywordSynonyms, rhs: KeywordSynonyms) -> Bool {
        lhs.owners == rhs.owners
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(owners)
    }
}

/// The library's keywords ready to match `kw:` terms against: each one's levels, folded once, filed by
/// level, and their paths in order, so the keywords inside one are a range.
final class KeywordMatcher: Sendable {
    private let ids: [Int64]
    private let paths: [String]
    private let levels: [[String]]
    private let byLevel: [String: [Int32]]
    let synonyms: KeywordSynonyms

    init(keywords: [Int64: String], synonyms: [String: [String]]) {
        let sorted = keywords.sorted { $0.value.utf8.lexicographicallyPrecedes($1.value.utf8) }
        ids = sorted.map(\.key)
        paths = sorted.map(\.value)
        let levels = paths.map { $0.split(separator: "/").map { KeywordQuery.key(KeywordPath.decode($0)) } }
        var byLevel: [String: [Int32]] = [:]
        for (index, names) in levels.enumerated() {
            for name in Set(names) {
                byLevel[name, default: []].append(Int32(index))
            }
        }
        self.levels = levels
        self.byLevel = byLevel
        self.synonyms = KeywordSynonyms(synonyms)
    }

    /// The IDs of the keywords `kw:value` finds, synonyms included, in order.
    func ids(matching value: String) -> [Int64] {
        var found = Set<Int32>()
        if let wanted = KeywordPath(value)?.names.map(KeywordQuery.key) {
            for candidate in byLevel[wanted[0]] ?? [] where Self.contains(levels[Int(candidate)], run: wanted) {
                found.insert(candidate)
            }
        }
        if value.contains("/"), let name = KeywordPath.canonical(value) {
            found.formUnion(byLevel[KeywordQuery.key(name)] ?? [])
        }
        for owner in synonyms.owners(of: value) {
            found.formUnion(within(owner))
        }
        return found.map { ids[Int($0)] }.sorted()
    }

    /// The IDs of the keywords whose synonyms, or those of a keyword containing them, hold `text`.
    func ids(withSynonymContaining text: String) -> [Int64] {
        var found = Set<Int32>()
        for owner in synonyms.owners(containing: text) {
            found.formUnion(within(owner))
        }
        return found.map { ids[Int($0)] }.sorted()
    }

    /// The keywords at `owner` and inside it: `owner`, and the paths from `owner/` up to those before
    /// `owner0`, as `/` sorts just before `0`.
    private func within(_ owner: String) -> [Int32] {
        let exact = lowerBound(owner)
        let lower = lowerBound(owner + "/")
        let upper = max(lower, lowerBound(owner + "0"))
        let inside = (lower ..< upper).map { Int32($0) }
        return exact < paths.count && paths[exact] == owner ? [Int32(exact)] + inside : inside
    }

    private func lowerBound(_ text: String) -> Int {
        var low = 0
        var high = paths.count
        while low < high {
            let middle = (low + high) / 2
            if paths[middle].utf8.lexicographicallyPrecedes(text.utf8) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private static func contains(_ levels: [String], run wanted: [String]) -> Bool {
        guard levels.count >= wanted.count else { return false }
        return (0 ... levels.count - wanted.count).contains { start in
            levels[start ..< start + wanted.count].elementsEqual(wanted)
        }
    }
}
