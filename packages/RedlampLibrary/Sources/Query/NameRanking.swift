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

    /// A keyword or a collection at `path` (`KeywordPath`'s text), matched by its decoded levels.
    static func levels(_ field: LibraryQuery.Field, path: String, others: [String] = []) -> RankedName {
        guard let levels = KeywordPath(path)?.names else { return RankedName(field, path, others: others) }
        let context = levels.dropLast().map { $0 + "/" }.joined()
        return RankedName(field, path, name: levels[levels.count - 1], context: context, others: others)
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
/// scattered across a name are left out. After all of those come the names with a word a typo from the text (two from
/// eight
/// letters; text of four letters or more, letters only): an extra, missing, wrong or swapped letter,
/// never the word's first, a plural's `s` aside. Each is scored as its correctly spelt twin, that
/// word, would be: by typos, then where the word is, and it counts toward the floor as that. Ties go
/// to the shorter name, then the field asked for first, then the names' order. Text and names are
/// folded as the language folds them (`FoldedText`), and a match never starts or ends inside a
/// character.
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
        var top = TopMatches(limit: limit)
        for (number, table) in tables.enumerated() {
            table.findHolding(typed, fields: fields, table: number, into: &top)
        }
        var late: [LateMatch] = []
        var twins: [Twin] = []
        if top.count < limit {
            if typed.typos > 0 {
                let wanted = fields.reduce(UInt64(0)) { $0 | NameTable.bit($1) }
                twins = Twin.closest(tables.flatMap { $0.twins(of: typed, fields: wanted) }, to: typed.bytes.count)
            }
            let shown = Set(top.owners)
            for (number, table) in tables.enumerated() {
                table.findLate(typed, twins: twins, fields: fields, table: number, skipping: shown, into: &late)
            }
        }
        var best = MatchQuality(score: 0, tightness: 0, coverage: 0)
        if let first = top.kept.first {
            best.score = tables[Int(first.table)].score(typed, entry: Int(first.entry), at: Int(first.at))
        }
        for match in top.kept {
            let coverage = tables[Int(match.table)].coverage(of: typed.units.count, entry: Int(match.entry))
            best.keepBest(MatchQuality(score: 0, tightness: 1, coverage: coverage))
        }
        for match in late {
            if let twin = match.twin {
                let score = Twin.score(length: twins[twin.index].bytes.count)
                best.keepBest(MatchQuality(score: score, tightness: 1, coverage: twin.coverage))
            }
            if let order = match.inOrder {
                best.keepBest(order)
            }
        }
        var inOrder: [(place: NamePlace, quality: MatchQuality)] = []
        var typos: [(place: NamePlace, typos: Int, match: NameMatch, twin: Int)] = []
        for match in late {
            if let order = match.inOrder, order.isWithinFloor(of: best) {
                inOrder.append((match.place, order))
            } else if let twin = match.twin {
                typos.append((match.place, twin.typos, twin.match, twin.index))
            }
        }
        inOrder.sort { lhs, rhs in
            let (left, right) = (lhs.quality, rhs.quality)
            return (-left.score, -left.tightness, -left.coverage, lhs.place)
                < (-right.score, -right.tightness, -right.coverage, rhs.place)
        }
        var found = Found(tables: tables, limit: limit)
        for match in top.kept {
            found.add(Int(match.table), Int(match.entry), match.match)
        }
        for match in inOrder {
            found.add(match.place.table, match.place.entry, .inOrder)
        }
        found.addTypos(typos, twins: twins)
        return found.matches
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

        /// Adds names found by a typo: fewest first, then the twin at a name's start before one at a
        /// word's, then as ties go.
        mutating func addTypos(_ found: [(place: NamePlace, typos: Int, match: NameMatch, twin: Int)], twins: [Twin]) {
            let sorted = found.sorted { lhs, rhs in
                (lhs.typos, lhs.match, lhs.place) < (rhs.typos, rhs.match, rhs.place)
            }
            for match in sorted {
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
    /// The typos a word may be from it: 1 for letters only, four or more; 2 from eight; 0 otherwise.
    let typos: Int

    init(_ text: String) {
        let folded = FoldedText(text)
        bytes = folded.bytes
        mask = folded.bytes.reduce(0) { $0 | NameBytes.bit($1) }
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
            if let kept = best[twin.bytes], (kept.typos, kept.isSingular ? 1 : 0) <= (
                twin.typos,
                twin.isSingular ? 1 : 0,
            ) {
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

/// A name found by its letters in order or by a typo, before the floor.
struct LateMatch {
    var place: NamePlace
    var inOrder: MatchQuality?
    /// The twin of the fewest typos it holds as a word, where, and how much of the name it covers.
    var twin: (typos: Int, match: NameMatch, index: Int, coverage: Double)?
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

    /// Whether a word ends at `at` of a name `length` bytes long, a plural's `s` aside.
    @inline(__always)
    static func endsWord(_ name: UnsafePointer<UInt8>, at: Int, length: Int) -> Bool {
        guard at < length, isLetter(name[at]) else { return true }
        return name[at] == 0x73 && (at + 1 == length || !isLetter(name[at + 1]))
    }
}

// MARK: - Names filed

/// Names folded once (`FoldedText`) and filed for ranking as text is typed: their bytes end to end,
/// with the bits of the letters and digits each holds, of those starting its words and of those
/// starting it and its own name, so most names are ruled out before a byte of theirs is read; and the
/// words they're made of, for typos.
struct NameTable: Sendable {
    /// The entries: each name, then the other names it goes by, a field's together, in the order of
    /// their folded text.
    let count: Int
    private let fields: ContiguousArray<LibraryQuery.Field>
    private let values: [String]
    /// The entry of the name each entry is for: its own, or for another name, the name's.
    private let owners: ContiguousArray<Int32>
    private let text: ContiguousArray<UInt8>
    /// Where each entry's text starts in `text`, and a last for the end.
    private let starts: ContiguousArray<Int32>
    /// Where its own name starts, from its start.
    private let ownStarts: ContiguousArray<Int32>
    private let masks: ContiguousArray<UInt64>
    private let wordMasks: ContiguousArray<UInt64>
    private let startMasks: ContiguousArray<UInt64>
    /// Where characters start, for the entries that aren't ASCII.
    private let characters: [Int32: ContiguousArray<Bool>]
    private let ranges: [LibraryQuery.Field: Range<Int>]
    private let words: TypoWords

    private struct Entry {
        var folded: FoldedText
        var own: Int
        var name: Int
        var isOther: Bool
    }

    init(_ names: [RankedName]) {
        var order: [LibraryQuery.Field] = []
        var byField: [LibraryQuery.Field: [Entry]] = [:]
        for (number, name) in names.enumerated() {
            if byField[name.field] == nil {
                order.append(name.field)
            }
            let context = FoldedText(name.context)
            let folded = Self.joined(context, FoldedText(name.name))
            byField[name.field, default: []].append(
                Entry(folded: folded, own: context.bytes.count, name: number, isOther: false),
            )
            for other in name.others where !other.isEmpty {
                byField[name.field, default: []].append(
                    Entry(folded: FoldedText(other), own: 0, name: number, isOther: true),
                )
            }
        }
        var fields = ContiguousArray<LibraryQuery.Field>()
        var values: [String] = []
        var owners = ContiguousArray<Int32>()
        var text = ContiguousArray<UInt8>()
        var starts = ContiguousArray<Int32>()
        var ownStarts = ContiguousArray<Int32>()
        var masks = ContiguousArray<UInt64>()
        var wordMasks = ContiguousArray<UInt64>()
        var startMasks = ContiguousArray<UInt64>()
        var characters: [Int32: ContiguousArray<Bool>] = [:]
        var ranges: [LibraryQuery.Field: Range<Int>] = [:]
        var words = TypoWords.Builder()
        var entryOfName = ContiguousArray<Int32>(repeating: -1, count: names.count)
        for field in order {
            let entries = byField[field] ?? []
            let sorted = entries.indices.sorted { lhs, rhs in
                let (left, right) = (entries[lhs], entries[rhs])
                if left.isOther != right.isOther {
                    return !left.isOther
                }
                let order = left.folded.bytes.withUnsafeBufferPointer { left in
                    right.folded.bytes.withUnsafeBufferPointer { right in
                        memcmp(left.baseAddress, right.baseAddress, min(left.count, right.count))
                    }
                }
                if order != 0 {
                    return order < 0
                }
                return (left.folded.bytes.count, left.name) < (right.folded.bytes.count, right.name)
            }
            let first = fields.count
            for index in sorted {
                let entry = entries[index]
                let number = Int32(fields.count)
                if !entry.isOther {
                    entryOfName[entry.name] = number
                }
                let owner = entryOfName[entry.name]
                fields.append(field)
                values.append(names[entry.name].value)
                owners.append(owner >= 0 ? owner : number)
                let bytes = entry.folded.bytes
                starts.append(Int32(text.count))
                text.append(contentsOf: bytes)
                ownStarts.append(Int32(entry.own))
                var mask: UInt64 = 0
                if let marks = entry.folded.starts {
                    characters[number] = marks
                    mask |= NameBytes.marked
                }
                var wordMask: UInt64 = 0
                bytes.withUnsafeBufferPointer { bytes in
                    guard let base = bytes.baseAddress else { return }
                    for (at, byte) in bytes.enumerated() {
                        mask |= NameBytes.bit(byte)
                        if entry.folded.starts?[at] ?? true, NameBytes.startsWord(base, at: at, own: entry.own) {
                            wordMask |= NameBytes.bit(byte)
                        }
                    }
                }
                masks.append(mask)
                wordMasks.append(wordMask)
                var startMask = bytes.first.map(NameBytes.bit) ?? 0
                if entry.own < bytes.count {
                    startMask |= NameBytes.bit(bytes[entry.own])
                }
                startMasks.append(startMask)
                words.add(bytes, field: Self.bit(field))
            }
            ranges[field] = first ..< fields.count
        }
        starts.append(Int32(text.count))
        count = fields.count
        self.fields = fields
        self.values = values
        self.owners = owners
        self.text = text
        self.starts = starts
        self.ownStarts = ownStarts
        self.masks = masks
        self.wordMasks = wordMasks
        self.startMasks = startMasks
        self.characters = characters
        self.ranges = ranges
        self.words = words.table()
    }

    /// `context`, then `name`, folded as one.
    private static func joined(_ context: FoldedText, _ name: FoldedText) -> FoldedText {
        guard !context.bytes.isEmpty else { return name }
        var starts: ContiguousArray<Bool>?
        if context.starts != nil || name.starts != nil {
            let left = context.starts ?? ContiguousArray(repeating: true, count: context.bytes.count + 1)
            let right = name.starts ?? ContiguousArray(repeating: true, count: name.bytes.count + 1)
            starts = left.dropLast() + right
        }
        return FoldedText(folded: context.bytes + name.bytes, starts: starts)
    }

    func field(of entry: Int) -> LibraryQuery.Field {
        fields[entry]
    }

    func value(of entry: Int) -> String {
        values[entry]
    }

    func owner(of entry: Int) -> Int {
        Int(owners[entry])
    }

    /// The bit of `field` in a set of fields.
    static func bit(_ field: LibraryQuery.Field) -> UInt64 {
        1 << UInt64(fieldNumbers[field] ?? 63)
    }

    private static let fieldNumbers: [LibraryQuery.Field: Int] = Dictionary(
        uniqueKeysWithValues: LibraryQuery.Field.allCases.enumerated().map { ($1, min($0, 63)) },
    )

    /// The table's arrays, unsafely, for the loops over every name.
    private struct Buffers {
        let text: UnsafePointer<UInt8>
        let starts: UnsafeBufferPointer<Int32>
        let own: UnsafeBufferPointer<Int32>
        let masks: UnsafeBufferPointer<UInt64>
        let wordMasks: UnsafeBufferPointer<UInt64>
        let startMasks: UnsafeBufferPointer<UInt64>
        let owners: UnsafeBufferPointer<Int32>
    }

    private func withBuffers<T>(_ body: (Buffers) -> T) -> T {
        text.withUnsafeBufferPointer { text in
            starts.withUnsafeBufferPointer { starts in
                ownStarts.withUnsafeBufferPointer { own in
                    masks.withUnsafeBufferPointer { masks in
                        wordMasks.withUnsafeBufferPointer { wordMasks in
                            startMasks.withUnsafeBufferPointer { startMasks in
                                owners.withUnsafeBufferPointer { owners in
                                    let empty = UnsafePointer<UInt8>(bitPattern: 1)!
                                    return body(Buffers(
                                        text: text.baseAddress ?? empty, starts: starts, own: own, masks: masks,
                                        wordMasks: wordMasks, startMasks: startMasks, owners: owners,
                                    ))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Ranking

    /// Offers `top` the entries of `fields` holding `typed` as typed, each where it holds it best.
    func findHolding(_ typed: TypedName, fields: [LibraryQuery.Field], table: Int, into top: inout TopMatches) {
        let wanted = typed.mask
        let single = typed.bytes.count == 1 && wanted != 0 && wanted != NameBytes.nonASCII
        typed.bytes.withUnsafeBufferPointer { query in
            guard let query = query.baseAddress else { return }
            withBuffers { buffers in
                let count = typed.bytes.count
                for (rank, field) in fields.enumerated() {
                    guard let range = ranges[field] else { continue }
                    for entry in range {
                        let mask = buffers.masks[entry]
                        guard mask & wanted == wanted else { continue }
                        let start = Int(buffers.starts[entry])
                        let length = Int(buffers.starts[entry + 1]) - start
                        guard length >= count else { continue }
                        let owner = Int64(table) << 32 | Int64(buffers.owners[entry])
                        var found: (match: NameMatch, at: Int)?
                        if single, mask & NameBytes.marked == 0 {
                            // One letter or digit in an ASCII name: its bits say where.
                            found = buffers.startMasks[entry] & wanted != 0 ? (.start, -1)
                                : buffers.wordMasks[entry] & wanted != 0 ? (.word, -1) : (.inside, -1)
                        } else {
                            let marks = mask & NameBytes.marked != 0 ? characters[Int32(entry)] : nil
                            found = Self.place(
                                query, count: count, in: buffers.text + start, length: length,
                                own: Int(buffers.own[entry]), characters: marks,
                            )
                        }
                        guard let found else { continue }
                        top.offer(
                            HoldingMatch(
                                match: found.match, at: Int32(found.at), length: Int32(length), field: Int16(rank),
                                table: Int16(table), entry: Int32(entry),
                            ),
                            owner: owner,
                        )
                    }
                }
            }
        }
    }

    /// Adds to `late` the entries of `fields` holding `typed`'s letters in order, unless
    /// `lettersInOrder` is false, or a word of one of `twins`, but those whose names `skipping` holds.
    func findLate(
        _ typed: TypedName, twins: [Twin], fields: [LibraryQuery.Field], table: Int, skipping: Set<Int64>,
        lettersInOrder: Bool = true, into late: inout [LateMatch],
    ) {
        let wanted = typed.mask
        let ordered = lettersInOrder && typed.bytes.count >= 2
        guard ordered || !twins.isEmpty else { return }
        let twinMasks = twins.map(\.mask)
        typed.bytes.withUnsafeBufferPointer { query in
            guard let query = query.baseAddress else { return }
            withBuffers { buffers in
                for (rank, field) in fields.enumerated() {
                    guard let range = ranges[field] else { continue }
                    for entry in range {
                        let mask = buffers.masks[entry]
                        let holdsLetters = ordered && mask & wanted == wanted
                        guard holdsLetters || twinMasks.contains(where: { mask & $0 == $0 }),
                              !skipping.contains(Int64(table) << 32 | Int64(buffers.owners[entry]))
                        else { continue }
                        let start = Int(buffers.starts[entry])
                        let length = Int(buffers.starts[entry + 1]) - start
                        let own = Int(buffers.own[entry])
                        let marks = mask & NameBytes.marked != 0 ? characters[Int32(entry)] : nil
                        let name = buffers.text + start
                        var found = LateMatch(place: NamePlace(length: length, field: rank, table: table, entry: entry))
                        if holdsLetters {
                            found.inOrder = Self.inOrder(
                                typed, query: query, in: name, length: length, own: own, characters: marks,
                            )
                        }
                        for (index, twin) in twins.enumerated() where mask & twin.mask == twin.mask {
                            if let kept = found.twin, kept.typos < twin.typos || kept.match == .start {
                                break
                            }
                            let match = twin.bytes.withUnsafeBufferPointer { word in
                                Self.word(word, in: name, length: length, own: own, characters: marks)
                            }
                            if let match, found.twin.map({ match < $0.match }) ?? true {
                                found.twin = (twin.typos, match, index, coverage(of: twin.bytes.count, entry: entry))
                            }
                        }
                        if found.inOrder != nil || found.twin != nil {
                            late.append(found)
                        }
                    }
                }
            }
        }
    }

    /// The score of `typed` held as typed at `at` of `entry`, or where it's best held when `at` is
    /// unknown (-1).
    func score(_ typed: TypedName, entry: Int, at: Int) -> Int {
        typed.bytes.withUnsafeBufferPointer { query in
            guard let query = query.baseAddress else { return 0 }
            return withBuffers { buffers in
                let start = Int(buffers.starts[entry])
                let length = Int(buffers.starts[entry + 1]) - start
                let own = Int(buffers.own[entry])
                let marks = buffers.masks[entry] & NameBytes.marked != 0 ? characters[Int32(entry)] : nil
                let name = buffers.text + start
                var at = at
                if at < 0 {
                    at = Self.place(
                        query,
                        count: typed.bytes.count,
                        in: name,
                        length: length,
                        own: own,
                        characters: marks,
                    )?.1 ?? 0
                }
                return Self.score(
                    typed, query: query, in: name, from: at, to: min(at + typed.bytes.count, length), own: own,
                    characters: marks,
                )
            }
        }
    }

    /// The words of `fields`' names within `typed`'s typos of it.
    func twins(of typed: TypedName, fields: UInt64) -> [Twin] {
        words.twins(of: typed, fields: fields)
    }

    /// The share of `entry`'s characters `count` of them are.
    func coverage(of count: Int, entry: Int) -> Double {
        let length = Int(starts[entry + 1] - starts[entry])
        let marks = masks[entry] & NameBytes.marked != 0 ? characters[Int32(entry)] : nil
        let total = marks.map { marks in marks.prefix(length).count { $0 } } ?? length
        return Double(count) / Double(max(total, 1))
    }

    // MARK: Matching

    /// Where `query` is in `name`, its best place first: the name's start or its own name's, a word's
    /// start, inside a word; never starting or ending inside a character.
    @inline(__always)
    private static func place(
        _ query: UnsafePointer<UInt8>, count: Int, in name: UnsafePointer<UInt8>, length: Int, own: Int,
        characters: ContiguousArray<Bool>?,
    ) -> (NameMatch, Int)? {
        @inline(__always) func fits(_ at: Int) -> Bool {
            characters.map { $0[at] && $0[at + count] } ?? true
        }
        if memcmp(name, query, count) == 0, fits(0) {
            return (.start, 0)
        }
        if own > 0, own + count <= length, memcmp(name + own, query, count) == 0, fits(own) {
            return (.start, own)
        }
        var inside: Int?
        var from = 1
        while length - from >= count, let found = memmem(name + from, length - from, query, count) {
            let at = UnsafeRawPointer(name).distance(to: UnsafeRawPointer(found))
            if fits(at) {
                if NameBytes.startsWord(name, at: at, own: own) {
                    return (.word, at)
                }
                inside = inside ?? at
            }
            from = at + 1
        }
        return inside.map { (.inside, $0) }
    }

    /// Where `word` is a whole word of `name`, a plural's `s` aside: at its start or its own name's,
    /// or another word's start.
    @inline(__always)
    private static func word(
        _ word: UnsafeBufferPointer<UInt8>, in name: UnsafePointer<UInt8>, length: Int, own: Int,
        characters: ContiguousArray<Bool>?,
    ) -> NameMatch? {
        let count = word.count
        guard let letters = word.baseAddress, count <= length else { return nil }
        var from = 0
        var match: NameMatch?
        while length - from >= count, let found = memmem(name + from, length - from, letters, count) {
            let at = UnsafeRawPointer(name).distance(to: UnsafeRawPointer(found))
            if characters.map({ $0[at] }) ?? true, NameBytes.startsWord(name, at: at, own: own),
               NameBytes.endsWord(name, at: at + count, length: length) {
                if at == 0 || at == own {
                    return .start
                }
                match = .word
            }
            from = at + 1
        }
        return match
    }

    /// `typed`'s characters in order in `name`, as fzf's first algorithm finds them: forward from the
    /// start, each where it's next found, then back from the last for the tightest span ending there;
    /// and how well they're placed.
    @inline(__always)
    private static func inOrder(
        _ typed: TypedName, query: UnsafePointer<UInt8>, in name: UnsafePointer<UInt8>, length: Int, own: Int,
        characters: ContiguousArray<Bool>?,
    ) -> MatchQuality? {
        var at = 0
        for unit in typed.units {
            guard let found = find(
                query + unit.lowerBound, count: unit.count, in: name, from: at, length: length,
                characters: characters,
            ) else { return nil }
            at = found + unit.count
        }
        let end = at
        var start = end
        for unit in typed.units.reversed() {
            var back = start - unit.count
            while back > 0, memcmp(name + back, query + unit.lowerBound, unit.count) != 0
                || !(characters.map { $0[back] && $0[back + unit.count] } ?? true) {
                back -= 1
            }
            start = back
        }
        let score = score(typed, query: query, in: name, from: start, to: end, own: own, characters: characters)
        let span = characters.map { marks in (start ..< end).count { marks[$0] } } ?? end - start
        let total = characters.map { marks in marks.prefix(length).count { $0 } } ?? length
        let count = Double(typed.units.count)
        return MatchQuality(
            score: score,
            tightness: count / Double(max(span, 1)),
            coverage: count / Double(max(total, 1)),
        )
    }

    @inline(__always)
    private static func find(
        _ unit: UnsafePointer<UInt8>, count: Int, in name: UnsafePointer<UInt8>, from: Int, length: Int,
        characters: ContiguousArray<Bool>?,
    ) -> Int? {
        var from = from
        while length - from >= count {
            let hit = count == 1 ? memchr(name + from, Int32(unit.pointee), length - from)
                : memmem(name + from, length - from, unit, count)
            guard let hit else { return nil }
            let at = UnsafeRawPointer(name).distance(to: UnsafeRawPointer(hit))
            if characters.map({ $0[at] && $0[at + count] }) ?? true {
                return at
            }
            from = at + 1
        }
        return nil
    }

    /// The score of `typed`'s characters matched in order from `from` to `to` of `name`: 16 each, 8
    /// more at a word's start and at least 4 more in a run (twice its bonus for the first), 3 less for
    /// a gap and 1 less for each character more in it.
    private static func score(
        _ typed: TypedName, query: UnsafePointer<UInt8>, in name: UnsafePointer<UInt8>, from: Int, to: Int,
        own: Int, characters: ContiguousArray<Bool>?,
    ) -> Int {
        var score = 0
        var unit = 0
        var run = 0
        var inGap = false
        var at = from
        let units = typed.units
        while at < to {
            if unit < units.count {
                let next = units[unit]
                if at + next.count <= to, memcmp(name + at, query + next.lowerBound, next.count) == 0,
                   characters.map({ $0[at] && $0[at + next.count] }) ?? true {
                    var bonus = NameBytes.startsWord(name, at: at, own: own) ? 8 : 0
                    if run > 0 {
                        bonus = max(bonus, 4)
                    }
                    score += 16 + (unit == 0 ? bonus * 2 : bonus)
                    run += 1
                    unit += 1
                    inGap = false
                    at += next.count
                    continue
                }
            }
            score += inGap ? -1 : -3
            inGap = true
            run = 0
            at += 1
            while let characters, at < to, !characters[at] {
                at += 1
            }
        }
        return score
    }
}

// MARK: - Words for typos

/// The words of letters names are made of, of three to `longest` letters from A to Z, each once,
/// filed by first letter and length with the fields whose names hold them: what a typo may be of.
struct TypoWords: Sendable {
    static let longest = 64

    fileprivate var bytes = ContiguousArray<UInt8>()
    fileprivate var starts = ContiguousArray<Int32>()
    fileprivate var masks = ContiguousArray<UInt64>()
    fileprivate var fields = ContiguousArray<UInt64>()
    /// The words by first letter, then length.
    fileprivate var order = ContiguousArray<Int32>()
    /// Where each first letter's and length's words start in `order`, and a last for the end.
    fileprivate var buckets = ContiguousArray<Int32>()

    fileprivate static func bucket(first: UInt8, length: Int) -> Int {
        Int(first - 0x61) * (longest + 1) + length
    }

    /// The words of `fields`' names within `typed.typos` of it, starting with its first letter: each
    /// word, or one without a plural's `s`, compared with what's typed after the first letter.
    func twins(of typed: TypedName, fields wanted: UInt64) -> [Twin] {
        let budget = typed.typos
        let count = typed.bytes.count
        guard budget > 0, !buckets.isEmpty else { return [] }
        var twins: [Twin] = []
        typed.bytes.withUnsafeBufferPointer { query in
            bytes.withUnsafeBufferPointer { bytes in
                let tail = UnsafeBufferPointer(rebasing: query[1...])
                for length in max(3, count - budget) ... min(Self.longest, count + budget + 1) {
                    let bucket = Self.bucket(first: query[0], length: length)
                    for place in Int(buckets[bucket]) ..< Int(buckets[bucket + 1]) {
                        let word = Int(order[place])
                        guard fields[word] & wanted != 0, (typed.mask & ~masks[word]).nonzeroBitCount <= budget
                        else { continue }
                        let start = Int(starts[word])
                        for form in [length, length - 1] where abs(form - count) <= budget {
                            guard form == length || length > 3 && bytes[start + length - 1] == 0x73 else { continue }
                            let letters = UnsafeBufferPointer(rebasing: bytes[start + 1 ..< start + form])
                            guard let typos = NameRanking.typos(tail, letters, limit: budget), typos > 0 else {
                                continue
                            }
                            let twin = ContiguousArray(bytes[start ..< start + form])
                            twins.append(Twin(
                                bytes: twin, mask: twin.reduce(0) { $0 | NameBytes.bit($1) }, typos: typos,
                                isSingular: form != length,
                            ))
                        }
                    }
                }
            }
        }
        return twins
    }

    struct Builder {
        private var words = TypoWords()
        private var slots = ContiguousArray<Int32>(repeating: -1, count: 1 << 12)
        private var hashes = ContiguousArray<UInt64>()

        /// Files the words of a name's folded `text` as `field`'s.
        mutating func add(_ text: ContiguousArray<UInt8>, field: UInt64) {
            var start = 0
            var index = 0
            while index <= text.count {
                if index < text.count, NameBytes.isLetter(text[index]) {
                    index += 1
                    continue
                }
                let length = index - start
                if length >= 3, length <= TypoWords.longest,
                   text[start ..< index].allSatisfy({ (0x61 ... 0x7A).contains($0) }) {
                    add(word: text[start ..< index], field: field)
                }
                index += 1
                start = index
            }
        }

        private mutating func add(word: ArraySlice<UInt8>, field: UInt64) {
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in word {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
            }
            if hashes.count * 2 >= slots.count {
                grow()
            }
            var slot = Int(hash & UInt64(slots.count - 1))
            while slots[slot] >= 0 {
                let found = Int(slots[slot])
                let start = Int(words.starts[found])
                let end = Int(words.starts[found + 1])
                if hashes[found] == hash, end - start == word.count, words.bytes[start ..< end].elementsEqual(word) {
                    words.fields[found] |= field
                    return
                }
                slot = (slot + 1) & (slots.count - 1)
            }
            slots[slot] = Int32(hashes.count)
            hashes.append(hash)
            if words.starts.isEmpty {
                words.starts.append(0)
            }
            words.bytes.append(contentsOf: word)
            words.starts.append(Int32(words.bytes.count))
            words.masks.append(word.reduce(0) { $0 | NameBytes.bit($1) })
            words.fields.append(field)
        }

        private mutating func grow() {
            slots = ContiguousArray(repeating: -1, count: slots.count * 2)
            for (number, hash) in hashes.enumerated() {
                var slot = Int(hash & UInt64(slots.count - 1))
                while slots[slot] >= 0 {
                    slot = (slot + 1) & (slots.count - 1)
                }
                slots[slot] = Int32(number)
            }
        }

        func table() -> TypoWords {
            var table = words
            let count = table.masks.count
            guard count > 0 else { return table }
            var buckets = ContiguousArray<Int32>(repeating: 0, count: 26 * (TypoWords.longest + 1) + 1)
            var keys = ContiguousArray<Int32>(repeating: 0, count: count)
            for word in 0 ..< count {
                let start = Int(table.starts[word])
                let key = TypoWords.bucket(first: table.bytes[start], length: Int(table.starts[word + 1]) - start)
                keys[word] = Int32(key)
                buckets[key + 1] += 1
            }
            for key in 1 ..< buckets.count {
                buckets[key] += buckets[key - 1]
            }
            var next = buckets
            var order = ContiguousArray<Int32>(repeating: 0, count: count)
            for word in 0 ..< count {
                let key = Int(keys[word])
                order[Int(next[key])] = Int32(word)
                next[key] += 1
            }
            table.buckets = buckets
            table.order = order
            return table
        }
    }
}
