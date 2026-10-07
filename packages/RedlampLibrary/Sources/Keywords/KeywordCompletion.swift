import Foundation

/// Completion for typing keywords (LIB-21): the keywords whose name, or a word of it, starts with
/// what's typed, then those whose synonyms do, best first. Case, accents and width don't count.
/// Typed as `Portugal > Lis`, the last part completes a keyword's name and the parts before it must
/// start the names of keywords containing it, in order. Categories aren't offered.
///
/// Every name and synonym is folded and filed once, under its start and under each word after its
/// first, in sorted tables of bytes: a completion is a binary search and a walk along the keys that
/// start with what's typed, stopping at the tables below once the ones above give enough.
public struct KeywordCompletion: Sendable {
    /// A keyword completion offers, and why.
    public struct Match: Sendable, Hashable {
        public enum Kind: Int, Sendable, Hashable, Comparable, CaseIterable {
            /// Its name is what's typed.
            case name
            /// Its name starts with it.
            case nameStart
            /// A word of its name does.
            case word
            /// A synonym starts with it.
            case synonym
            /// A word of a synonym does.
            case synonymWord

            public static func < (lhs: Kind, rhs: Kind) -> Bool {
                lhs.rawValue < rhs.rawValue
            }
        }

        public let path: KeywordPath
        /// Photos with it or a keyword inside it.
        public let count: Int
        public let kind: Kind
        /// The synonym that matched, for a match by synonym.
        public let synonym: String?
    }

    /// A keyword as completion knows it.
    public struct Entry: Sendable, Hashable {
        public var path: KeywordPath
        public var synonyms: [String]
        public var count: Int

        public init(path: KeywordPath, synonyms: [String] = [], count: Int = 0) {
            self.path = path
            self.synonyms = synonyms
            self.count = count
        }
    }

    private let entries: [Entry]
    /// Each entry's place when they're ordered as completion offers them within a kind: the most used
    /// first, then by name.
    private let rank: [Int32]
    private let starts: KeyTable
    private let words: KeyTable
    private let synonymStarts: KeyTable
    private let synonymWords: KeyTable

    /// The keywords of `list`, but its categories.
    public init(_ list: KeywordList) {
        self.init(list.keywords.values.filter { !$0.options.isCategory }.map {
            Entry(path: $0.path, synonyms: $0.options.synonyms, count: $0.count)
        })
    }

    public init(_ entries: [Entry]) {
        self.entries = entries
        let order = entries.indices.sorted { lhs, rhs in
            let (left, right) = (entries[lhs], entries[rhs])
            if left.count != right.count {
                return left.count > right.count
            }
            let names = FinderOrder.compare(left.path.name, right.path.name)
            return names != 0 ? names < 0 : left.path < right.path
        }
        var rank = [Int32](repeating: 0, count: entries.count)
        for (place, entry) in order.enumerated() {
            rank[entry] = Int32(place)
        }
        self.rank = rank
        var starts = KeyTable.Builder()
        var words = KeyTable.Builder()
        var synonymStarts = KeyTable.Builder()
        var synonymWords = KeyTable.Builder()
        for (owner, entry) in entries.enumerated() {
            let name = Self.fold(entry.path.name)
            starts.add(Substring(name), owner: owner)
            for start in Self.wordStarts(name) {
                words.add(name[start...], owner: owner)
            }
            for (number, synonym) in entry.synonyms.enumerated() {
                let folded = Self.fold(synonym)
                synonymStarts.add(Substring(folded), owner: owner, synonym: number)
                for start in Self.wordStarts(folded) {
                    synonymWords.add(folded[start...], owner: owner, synonym: number)
                }
            }
        }
        self.starts = starts.table()
        self.words = words.table()
        self.synonymStarts = synonymStarts.table()
        self.synonymWords = synonymWords.table()
    }

    /// How many keywords it completes.
    public var count: Int {
        entries.count
    }

    /// The best `limit` keywords for `text`: by kind of match, then the most used first, then by name.
    public func matches(_ text: String, limit: Int = 10) -> [Match] {
        let parts = text.split { $0 == ">" || $0 == "|" }.map { Self.fold($0.trimmingCharacters(in: .whitespaces)) }
        guard let last = parts.last, !last.isEmpty, limit > 0 else { return [] }
        let containers = parts.dropLast().filter { !$0.isEmpty }
        let query = Array(last.utf8)
        var best: [Int32: (kind: Match.Kind, synonym: Int32)] = [:]
        func accepts(_ owner: Int32) -> Bool {
            containers.isEmpty || Self.contained(entries[Int(owner)].path, by: containers)
        }
        let tables: [(KeyTable, Match.Kind)] = [
            (starts, .nameStart), (words, .word), (synonymStarts, .synonym), (synonymWords, .synonymWord),
        ]
        for (table, kind) in tables {
            guard best.count < limit else { break }
            table.forEach(startingWith: query) { owner, synonym, length in
                guard best[owner] == nil, accepts(owner) else { return }
                best[owner] = (kind == .nameStart && length == query.count ? .name : kind, synonym)
            }
        }
        let ordered = best.sorted { lhs, rhs in
            lhs.value.kind != rhs.value.kind ? lhs.value.kind < rhs.value.kind : rank[Int(lhs.key)] < rank[Int(rhs.key)]
        }
        return ordered.prefix(limit).map { owner, found in
            let entry = entries[Int(owner)]
            return Match(
                path: entry.path, count: entry.count, kind: found.kind,
                synonym: found.synonym >= 0 ? entry.synonyms[Int(found.synonym)] : nil,
            )
        }
    }

    // MARK: - Folding

    /// `text` as completion compares it: case, accents and width aside.
    static func fold(_ text: some StringProtocol) -> String {
        QueryText.folded(text)
    }

    /// Where each word of `folded` after its first begins.
    private static func wordStarts(_ folded: String) -> [String.Index] {
        var starts: [String.Index] = []
        var inWord = false
        var index = folded.startIndex
        var first = true
        while index < folded.endIndex {
            let isWord = folded[index].isLetter || folded[index].isNumber
            if isWord, !inWord {
                if !first {
                    starts.append(index)
                }
                first = false
            }
            inWord = isWord
            index = folded.index(after: index)
        }
        return starts
    }

    /// Whether the names of the keywords containing `path` start with `containers` in order.
    private static func contained(_ path: KeywordPath, by containers: [String]) -> Bool {
        var remaining = containers[...]
        for name in path.names.dropLast() {
            guard let next = remaining.first else { break }
            if fold(name).hasPrefix(next) {
                remaining = remaining.dropFirst()
            }
        }
        return remaining.isEmpty
    }
}

/// Folded keys in byte order, each with the entry it's for (and which synonym, or -1), in one buffer.
private struct KeyTable: Sendable {
    private let bytes: [UInt8]
    private let starts: [Int32]
    private let lengths: [Int32]
    private let owners: [Int32]
    private let synonyms: [Int32]

    struct Builder {
        private var keys: [(key: [UInt8], owner: Int32, synonym: Int32)] = []

        mutating func add(_ key: Substring, owner: Int, synonym: Int = -1) {
            guard !key.isEmpty else { return }
            keys.append((Array(key.utf8), Int32(owner), Int32(synonym)))
        }

        func table() -> KeyTable {
            let sorted = keys.sorted { lhs, rhs in
                lhs.key.lexicographicallyPrecedes(rhs.key) || lhs.key == rhs.key && lhs.owner < rhs.owner
            }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(sorted.reduce(0) { $0 + $1.key.count })
            var starts: [Int32] = []
            var lengths: [Int32] = []
            for key in sorted {
                starts.append(Int32(bytes.count))
                lengths.append(Int32(key.key.count))
                bytes += key.key
            }
            return KeyTable(
                bytes: bytes, starts: starts, lengths: lengths, owners: sorted.map(\.owner),
                synonyms: sorted.map(\.synonym),
            )
        }
    }

    /// Calls `body` with the entry, synonym and length of each key that starts with `prefix`, in order.
    func forEach(startingWith prefix: [UInt8], _ body: (Int32, Int32, Int) -> Void) {
        bytes.withUnsafeBufferPointer { bytes in
            prefix.withUnsafeBufferPointer { prefix in
                func compare(_ key: Int) -> Int32 {
                    let length = Int(lengths[key])
                    let shared = min(length, prefix.count)
                    let order = memcmp(bytes.baseAddress! + Int(starts[key]), prefix.baseAddress!, shared)
                    if order != 0 {
                        return order
                    }
                    return length < prefix.count ? -1 : 0
                }
                var low = 0
                var high = starts.count
                while low < high {
                    let middle = (low + high) / 2
                    if compare(middle) < 0 {
                        low = middle + 1
                    } else {
                        high = middle
                    }
                }
                var key = low
                while key < starts.count, compare(key) == 0 {
                    body(owners[key], synonyms[key], Int(lengths[key]))
                    key += 1
                }
            }
        }
    }
}

public extension KeywordList {
    /// The keywords typed in `text` as the keywording field takes them, Lightroom Classic's way:
    /// separated by commas, each a name or a path from the top with `>` or `|` between levels
    /// (`Places > Portugal > Lisbon`), or from the keyword up with `<` (`Lisbon < Portugal`). A slash
    /// is part of a name. A single name the list has, as a keyword's name or a synonym, is that
    /// keyword; a path is the one at that path, the list's or a new one; any other name is a new
    /// keyword at the top of the list.
    func entered(_ text: String) -> [KeywordPath] {
        var found: [KeywordPath] = []
        for term in text.split(separator: ",") {
            var names: [String] = if term.contains("<") {
                term.split(separator: "<").map(String.init).reversed()
            } else {
                term.split { $0 == ">" || $0 == "|" }.map(String.init)
            }
            names = names.compactMap(KeywordPath.canonical)
            guard let path = KeywordPath(names: names) else { continue }
            let resolved = names.count == 1 ? resolve(KeywordPath.encode(names[0])) ?? path : path
            if !found.contains(resolved) {
                found.append(resolved)
            }
        }
        return found
    }
}
