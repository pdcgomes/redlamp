import Foundation

/// A field's value that completion offers (LIB-18) and the command palette lists (LIB-19), with the
/// text it's matched by: the levels above its own name, then its own name, and the other names it
/// goes by (a keyword's synonyms, a trait's word).
struct RankedName: Sendable, Hashable {
    var field: LibraryQuery.Field
    var value: String
    /// What comes before its own name, a slash after each level: a keyword's or a collection's levels
    /// above it, a folder's parent.
    var context: String
    var name: String
    var others: [String]

    init(
        _ field: LibraryQuery.Field, _ value: String, name: String? = nil, context: String = "",
        others: [String] = [],
    ) {
        self.field = field
        self.value = value
        self.name = name ?? value
        self.context = context
        self.others = others
    }

    /// A keyword or a collection at `path` (`KeywordPath`'s text, which the index keeps canonical),
    /// matched by its decoded levels.
    static func levels(_ field: LibraryQuery.Field, path: String, others: [String] = []) -> RankedName {
        guard path.contains("%") else {
            guard let slash = path.lastIndex(of: "/") else { return RankedName(field, path, others: others) }
            let name = path.index(after: slash)
            return RankedName(field, path, name: String(path[name...]), context: String(path[..<name]), others: others)
        }
        let levels = path.split(separator: "/").map { KeywordPath.decode($0) }
        guard let last = levels.last else { return RankedName(field, path, others: others) }
        return RankedName(field, path, name: last, context: levels.dropLast().map { $0 + "/" }.joined(), others: others)
    }

    /// A folder at `path`, matched by its parent's path and its own name.
    static func folder(_ path: String) -> RankedName {
        guard let slash = path.lastIndex(of: "/"), path.index(after: slash) < path.endIndex else {
            return RankedName(.folder, path)
        }
        let name = path.index(after: slash)
        return RankedName(.folder, path, name: String(path[name...]), context: String(path[..<name]))
    }

    /// The word of its text that folds to `folded` (`FoldedText`), as the name writes it: `Zürich` for
    /// `zurich`, and a plural's word without its `s` for the word without it.
    func spelling(of folded: String) -> String? {
        for text in [context + name] + others {
            var word = ""
            for character in text + " " {
                if character.isLetter {
                    word.append(character)
                    continue
                }
                let bytes = String(decoding: FoldedText(word).bytes, as: UTF8.self)
                if !word.isEmpty, bytes == folded {
                    return word
                }
                if !word.isEmpty, bytes == folded + "s", word.last == "s" || word.last == "S" {
                    return String(word.dropLast())
                }
                word = ""
            }
        }
        return nil
    }
}

/// How a name holds what's typed, best first.
enum NameMatch: Int, Sendable, Hashable, Comparable {
    /// At its start, or at its own name's: a keyword's last level, a folder's name.
    case start
    /// At the start of one of its words.
    case word
    /// Inside a word.
    case inside
    /// Its letters in order.
    case inOrder
    /// A word of it is a typo or two from what's typed.
    case typo

    static func < (lhs: NameMatch, rhs: NameMatch) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A name ranked for what's typed.
struct RankedMatch: Sendable, Hashable {
    let field: LibraryQuery.Field
    let value: String
    let match: NameMatch
    /// For a typo, how many: 1, or 2 from eight letters; 0 otherwise.
    let typos: Int
    /// For a typo, the name's word it's a typo of, folded: what was meant.
    let twin: String?
}

/// Ranks names as completion offers them and the palette lists them (LIB-18, LIB-19). A name holding
/// the text as typed comes first, by where it holds it: at its start or its own name's, at a word's
/// start, inside a word; then one holding its letters in order, scored as fzf's first algorithm
/// scores them (16 a letter, more at a word's start and in a run, less for each gap), kept within a
/// floor of the best match (`MatchQuality`): half its score, 40% of its tightness (the characters
/// typed over the span they're spread across) and 40% of how much of its name it covers, so letters
/// scattered across a name are left out. After all of those come the names with a word a typo from
/// the text (two from eight letters; text of four letters or more, letters only): an extra, missing,
/// wrong or swapped letter, never the word's first, a plural's `s` aside. Each is scored as its
/// correctly spelt twin, that word, would be: by typos, then where the word is, and it counts toward
/// the floor as that. Ties go to the shorter name, then the field asked for first, then the order the
/// names are given in. Text and names are folded as the language folds them (`FoldedText`), and a
/// match never starts or ends inside a character.
///
/// Names holding the text at their start or a word's are looked up by its first two bytes
/// (`WordStarts`), as are the typos' twins; names are scanned for the rest only while those don't
/// fill the list, and then only those holding in order what was typed a key before (`ScanCache`).
enum NameRanking {
    /// A match by letters in order is kept from this share of the best match's tightness and coverage.
    static let floor = 0.4
    /// The twins tried for text with a typo, the closest first.
    static let twinLimit = 6

    static func rank(
        _ text: String, in tables: [NameTable], fields: [LibraryQuery.Field], limit: Int,
    ) -> [RankedMatch] {
        let typed = TypedName(text)
        guard !typed.bytes.isEmpty, limit > 0, !fields.isEmpty else { return [] }
        let wanted = FieldSet(fields)
        var top = TopMatches(limit: limit)
        for (number, table) in tables.enumerated() {
            table.findAtStarts(typed, fields: wanted, table: number, into: &top)
        }
        var best = holdingQuality(top, typed, tables)
        var ordered: [OrderedMatch] = []
        if top.count < limit, typed.bytes.count > 1 {
            for (number, table) in tables.enumerated() {
                table.scan(
                    typed,
                    fields: wanted,
                    table: number,
                    limit: limit,
                    best: &best,
                    top: &top,
                    ordered: &ordered,
                )
            }
        }
        var twins: [Twin] = []
        var typos: [TwinMatch] = []
        if top.count < limit, typed.typos > 0 {
            twins = Twin.closest(tables.flatMap { $0.twins(of: typed, fields: wanted.bits) }, to: typed.bytes.count)
            for (number, table) in tables.enumerated() {
                table.findTwins(twins, fields: wanted, table: number, into: &typos)
            }
        }
        best.keepBest(holdingQuality(top, typed, tables))
        for match in typos {
            let score = Twin.score(length: twins[match.twin].bytes.count)
            best.keepBest(MatchQuality(score: score, tightness: 1, coverage: match.coverage))
        }
        let kept = ordered.filter { $0.quality.isWithinFloor(of: best) }.sorted { $0.precedes($1) }
        var found = Found(tables: tables, limit: limit)
        for match in top.kept {
            found.add(Int(match.table), Int(match.entry), match.match)
        }
        for match in kept {
            found.add(match.place.table, match.place.entry, .inOrder)
        }
        found.addTypos(typos, twins: twins)
        return found.matches
    }

    /// How well the names holding the text as typed hold it: as tightly as can be, the first's score,
    /// and the most of its name any covers.
    private static func holdingQuality(_ top: TopMatches, _ typed: TypedName, _ tables: [NameTable]) -> MatchQuality {
        var best = MatchQuality(score: 0, tightness: 0, coverage: 0)
        guard let first = top.kept.first else { return best }
        best.score = tables[Int(first.table)].score(typed, entry: Int(first.entry), at: Int(first.at))
        best.tightness = 1
        for match in top.kept {
            let coverage = tables[Int(match.table)].coverage(of: typed.units.count, entry: Int(match.entry))
            best.coverage = max(best.coverage, coverage)
        }
        return best
    }

    /// Matches gathered best first, one for each name.
    struct Found {
        let tables: [NameTable]
        let limit: Int
        private(set) var matches: [RankedMatch] = []
        private var owners = Set<Int64>()

        init(tables: [NameTable], limit: Int) {
            self.tables = tables
            self.limit = limit
        }

        mutating func add(_ table: Int, _ entry: Int, _ match: NameMatch, typos: Int = 0, twin: String? = nil) {
            let names = tables[table]
            guard matches.count < limit, owners.insert(Int64(table) << 32 | Int64(names.owner(of: entry))).inserted
            else { return }
            matches.append(RankedMatch(
                field: names.field(of: entry), value: names.value(of: entry), match: match, typos: typos, twin: twin,
            ))
        }

        /// Adds names found by a typo: the fewest first, then the twin at a name's start before one at
        /// a word's, then as ties go.
        mutating func addTypos(_ found: [TwinMatch], twins: [Twin]) {
            for match in found.sorted(by: { ($0.typos, $0.match, $0.place) < ($1.typos, $1.match, $1.place) }) {
                let twin = String(decoding: twins[match.twin].bytes, as: UTF8.self)
                add(match.place.table, match.place.entry, .typo, typos: match.typos, twin: twin)
            }
        }
    }

    /// The restricted Damerau-Levenshtein distance between `a` and `b`, an extra, missing, wrong or
    /// swapped letter each counting one; nil past `limit`.
    static func typos(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>, limit: Int) -> Int? {
        let (m, n) = (a.count, b.count)
        guard abs(m - n) <= limit else { return nil }
        guard m > 0, n > 0 else { return max(m, n) }
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: 3 * (n + 1)) { rows -> Int? in
            guard let base = rows.baseAddress else { return nil }
            var twoBack = base
            var previous = base + (n + 1)
            var current = previous + (n + 1)
            for column in 0 ... n {
                previous[column] = column
                twoBack[column] = column
            }
            for row in 1 ... m {
                current[0] = row
                var smallest = row
                for column in 1 ... n {
                    let cost = a[row - 1] == b[column - 1] ? 0 : 1
                    var value = min(previous[column] + 1, current[column - 1] + 1, previous[column - 1] + cost)
                    if row > 1, column > 1, a[row - 1] == b[column - 2], a[row - 2] == b[column - 1] {
                        value = min(value, twoBack[column - 2] + 1)
                    }
                    current[column] = value
                    smallest = min(smallest, value)
                }
                guard smallest <= limit else { return nil }
                (twoBack, previous, current) = (previous, current, twoBack)
            }
            return previous[n] <= limit ? previous[n] : nil
        }
    }
}

// MARK: - What's typed

/// Text as names are ranked by it: folded (`FoldedText`), the bits of the letters and digits it
/// holds, and its characters.
struct TypedName {
    let bytes: ContiguousArray<UInt8>
    let mask: UInt64
    /// Each character's bytes.
    let units: [Range<Int>]
    let isASCII: Bool
    /// The typos a word may be from it: 1 for letters only, four or more; 2 from eight; 0 otherwise.
    let typos: Int

    init(_ text: String) {
        let folded = FoldedText(text)
        bytes = folded.bytes
        mask = folded.bytes.reduce(0) { $0 | NameBytes.bit($1) }
        isASCII = folded.starts == nil
        if let starts = folded.starts {
            var units: [Range<Int>] = []
            var start = 0
            for index in starts.indices.dropFirst() where starts[index] {
                units.append(start ..< index)
                start = index
            }
            self.units = units
        } else {
            units = bytes.indices.map { $0 ..< $0 + 1 }
        }
        let letters = bytes.count >= 4 && bytes.count <= TypoWords.longest
            && bytes.allSatisfy { (0x61 ... 0x7A).contains($0) }
        typos = letters ? bytes.count >= 8 ? 2 : 1 : 0
    }
}

/// The fields asked for, as bits by `LibraryQuery.Field`'s cases, and each one's place among them.
struct FieldSet {
    let bits: UInt64
    private let ranks: ContiguousArray<Int16>

    init(_ fields: [LibraryQuery.Field]) {
        var bits: UInt64 = 0
        var ranks = ContiguousArray<Int16>(repeating: -1, count: 64)
        for (rank, field) in fields.enumerated() {
            let number = Int(NameTable.number(of: field))
            if ranks[number] < 0 {
                ranks[number] = Int16(rank)
                bits |= 1 << UInt64(number)
            }
        }
        self.bits = bits
        self.ranks = ranks
    }

    /// Where the field numbered `number` was asked for; -1 when it wasn't.
    @inline(__always)
    func rank(_ number: UInt8) -> Int {
        Int(ranks[Int(number)])
    }

    @inline(__always)
    func contains(_ number: UInt8) -> Bool {
        bits >> UInt64(number) & 1 != 0
    }
}

/// A word a text's typo may be of, and how many typos.
struct Twin: Sendable {
    let bytes: ContiguousArray<UInt8>
    let mask: UInt64
    let typos: Int
    /// Made from a word by leaving a plural's `s` out.
    let isSingular: Bool

    /// The closest of `twins`, each once: fewest typos first, then a word names have before one made
    /// by leaving a plural's `s` out, then nearest in length to the `count` letters typed.
    static func closest(_ twins: [Twin], to count: Int) -> [Twin] {
        var best: [ContiguousArray<UInt8>: Twin] = [:]
        for twin in twins {
            if let kept = best[twin.bytes],
               (kept.typos, kept.isSingular ? 1 : 0) <= (twin.typos, twin.isSingular ? 1 : 0) {
                continue
            }
            best[twin.bytes] = twin
        }
        let sorted = best.values.sorted { lhs, rhs in
            let left = (lhs.typos, lhs.isSingular ? 1 : 0, abs(lhs.bytes.count - count), lhs.bytes.count)
            let right = (rhs.typos, rhs.isSingular ? 1 : 0, abs(rhs.bytes.count - count), rhs.bytes.count)
            return left != right ? left < right : lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
        }
        return Array(sorted.prefix(NameRanking.twinLimit))
    }

    /// A whole word of `length` letters as its own text scores: its first at a word's start, the rest
    /// a run.
    static func score(length: Int) -> Int {
        32 + 20 * (length - 1)
    }
}

/// A name among the tables, ordered as ties are: the shorter first, then the field asked for first,
/// then the tables' and names' order.
struct NamePlace: Comparable {
    var length: Int
    var field: Int
    var table: Int
    var entry: Int

    static func < (lhs: NamePlace, rhs: NamePlace) -> Bool {
        (lhs.length, lhs.field, lhs.table, lhs.entry) < (rhs.length, rhs.field, rhs.table, rhs.entry)
    }
}

/// How well a match places what's typed: its score, its characters over those of the span they're
/// spread across (how tight it is), and over its name's (how much of the name it covers).
struct MatchQuality {
    var score: Int
    var tightness: Double
    var coverage: Double

    /// Whether it's within the floor of `best`: half its score, and `NameRanking.floor` of its
    /// tightness and of its coverage.
    func isWithinFloor(of best: MatchQuality) -> Bool {
        score * 2 >= best.score && tightness >= NameRanking.floor * best.tightness
            && coverage >= NameRanking.floor * best.coverage
    }

    mutating func keepBest(_ other: MatchQuality) {
        score = max(score, other.score)
        tightness = max(tightness, other.tightness)
        coverage = max(coverage, other.coverage)
    }
}

/// A name holding what's typed only by its letters in order.
struct OrderedMatch {
    var place: NamePlace
    var quality: MatchQuality

    func precedes(_ other: OrderedMatch) -> Bool {
        (-quality.score, -quality.tightness, -quality.coverage, place)
            < (-other.quality.score, -other.quality.tightness, -other.quality.coverage, other.place)
    }
}

/// A name with a word one of the twins is: how many typos, where, and how much of the name it covers.
struct TwinMatch {
    var place: NamePlace
    var typos: Int
    var match: NameMatch
    var twin: Int
    var coverage: Double
}

/// A name holding the text as typed, and where.
struct HoldingMatch {
    var match: NameMatch
    var at: Int32
    var length: Int32
    var field: Int16
    var table: Int16
    var entry: Int32

    @inline(__always)
    func precedes(_ other: HoldingMatch) -> Bool {
        (match.rawValue, length, field, table, entry)
            < (other.match.rawValue, other.length, other.field, other.table, other.entry)
    }
}

/// The best names holding the text as typed, one entry for each name they're for.
struct TopMatches {
    let limit: Int
    private(set) var kept: [HoldingMatch] = []
    private(set) var owners: [Int64] = []

    init(limit: Int) {
        self.limit = limit
        kept.reserveCapacity(limit + 1)
        owners.reserveCapacity(limit + 1)
    }

    var count: Int {
        kept.count
    }

    @inline(__always)
    mutating func offer(_ match: HoldingMatch, owner: Int64) {
        if kept.count == limit, let last = kept.last, !match.precedes(last) {
            return
        }
        if let index = owners.firstIndex(of: owner) {
            guard match.precedes(kept[index]) else { return }
            kept.remove(at: index)
            owners.remove(at: index)
        }
        var index = kept.count
        while index > 0, match.precedes(kept[index - 1]) {
            index -= 1
        }
        kept.insert(match, at: index)
        owners.insert(owner, at: index)
        if kept.count > limit {
            kept.removeLast()
            owners.removeLast()
        }
    }
}

// MARK: - Bytes

/// Folded bytes as names are matched by them.
enum NameBytes {
    /// The bit standing for every byte past ASCII.
    static let nonASCII: UInt64 = 1 << 36
    /// The bit a name has when it wasn't ASCII before it was folded, so its characters' starts are
    /// kept (`ß`, folded to `ss`): never one of what's typed.
    static let marked: UInt64 = 1 << 37

    /// The bit of a letter or digit; none for anything else.
    @inline(__always)
    static func bit(_ byte: UInt8) -> UInt64 {
        switch byte {
        case 0x61 ... 0x7A: 1 << UInt64(byte - 0x61)
        case 0x30 ... 0x39: 1 << UInt64(26 + byte - 0x30)
        case 0x80...: nonASCII
        default: 0
        }
    }

    /// A letter, every byte past ASCII counting as one.
    @inline(__always)
    static func isLetter(_ byte: UInt8) -> Bool {
        (0x61 ... 0x7A).contains(byte) || byte >= 0x80
    }

    @inline(__always)
    static func isWordByte(_ byte: UInt8) -> Bool {
        isLetter(byte) || (0x30 ... 0x39).contains(byte)
    }

    /// Whether a word starts at `at` of `name`: at its start or its own name's, after what isn't a
    /// letter or a digit, or where letters give way to digits or digits to letters.
    @inline(__always)
    static func startsWord(_ name: UnsafePointer<UInt8>, at: Int, own: Int) -> Bool {
        guard at > 0, at != own else { return true }
        let before = name[at - 1]
        let byte = name[at]
        return !isWordByte(before) || isWordByte(byte) && isLetter(byte) != isLetter(before)
    }

    /// Sets the bit of the pair `first`, `second` among 128 (`pairs`).
    @inline(__always)
    static func addPair(_ first: UInt8, _ second: UInt8, to pairs: inout (UInt64, UInt64)) {
        let bit = ((UInt32(first) << 8 | UInt32(second)) &* 2_654_435_761) >> 25
        if bit < 64 {
            pairs.0 |= 1 << UInt64(bit)
        } else {
            pairs.1 |= 1 << UInt64(bit - 64)
        }
    }

    /// The pairs of bytes side by side in `bytes`, as `addPair` sets them.
    static func pairs(_ bytes: ContiguousArray<UInt8>) -> (UInt64, UInt64) {
        var pairs: (UInt64, UInt64) = (0, 0)
        for (first, second) in zip(bytes, bytes.dropFirst()) {
            addPair(first, second, to: &pairs)
        }
        return pairs
    }

    /// Whether a word ends at `at` of a name `length` bytes long, a plural's `s` aside.
    @inline(__always)
    static func endsWord(_ name: UnsafePointer<UInt8>, at: Int, length: Int) -> Bool {
        guard at < length, isLetter(name[at]) else { return true }
        return name[at] == 0x73 && (at + 1 == length || !isLetter(name[at + 1]))
    }
}
