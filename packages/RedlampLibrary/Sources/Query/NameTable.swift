import Foundation

/// Names folded once (`FoldedText`) and filed for ranking as text is typed: their bytes end to end,
/// with the bits of the letters and digits each holds, of those starting its words and of those
/// starting it and its own name, so most names are ruled out before a byte of theirs is read; where
/// their words start, by their first two bytes; and the words they're made of, for typos.
struct NameTable: Sendable {
    /// The entries: each name, then the other names it goes by, a field's together.
    let count: Int
    /// Each entry's field, by its place among `LibraryQuery.Field`'s cases.
    private let numbers: ContiguousArray<UInt8>
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
    /// The pairs of bytes each entry holds side by side, as bits of two words (`NameBytes.pair`): what
    /// it can't hold as typed is ruled out without searching it.
    private let pairs: ContiguousArray<UInt64>
    /// Where characters start, for the entries that weren't ASCII.
    private let characters: [Int32: ContiguousArray<Bool>]
    /// Each field's entries, a run each.
    private let ranges: [(number: UInt8, range: Range<Int>)]
    private let wordStarts: WordStarts
    private let words: TypoWords
    private let scans = ScanCache()

    init(_ names: [RankedName]) {
        var order: [LibraryQuery.Field] = []
        var byField: [LibraryQuery.Field: [Int]] = [:]
        for (index, name) in names.enumerated() {
            if byField[name.field] == nil {
                order.append(name.field)
            }
            byField[name.field, default: []].append(index)
        }
        var builder = Builder()
        var ranges: [(number: UInt8, range: Range<Int>)] = []
        for field in order {
            let first = builder.numbers.count
            for index in byField[field] ?? [] {
                builder.add(names[index])
            }
            ranges.append((Self.number(of: field), first ..< builder.numbers.count))
        }
        builder.starts.append(Int32(builder.text.count))
        count = builder.numbers.count
        numbers = builder.numbers
        values = builder.values
        owners = builder.owners
        text = builder.text
        starts = builder.starts
        ownStarts = builder.ownStarts
        masks = builder.masks
        wordMasks = builder.wordMasks
        startMasks = builder.startMasks
        pairs = builder.pairs
        characters = builder.characters
        self.ranges = ranges
        wordStarts = builder.wordStarts.table()
        words = builder.words.table()
    }

    private struct Builder {
        var numbers = ContiguousArray<UInt8>()
        var values: [String] = []
        var owners = ContiguousArray<Int32>()
        var text = ContiguousArray<UInt8>()
        var starts = ContiguousArray<Int32>()
        var ownStarts = ContiguousArray<Int32>()
        var masks = ContiguousArray<UInt64>()
        var wordMasks = ContiguousArray<UInt64>()
        var startMasks = ContiguousArray<UInt64>()
        var pairs = ContiguousArray<UInt64>()
        var characters: [Int32: ContiguousArray<Bool>] = [:]
        var wordStarts = WordStarts.Builder()
        var words = TypoWords.Builder()

        mutating func add(_ name: RankedName) {
            let number = NameTable.number(of: name.field)
            let owner = Int32(numbers.count)
            add(context: name.context, name: name.name, number: number, value: name.value, owner: owner)
            for other in name.others where !other.isEmpty {
                add(context: "", name: other, number: number, value: name.value, owner: owner)
            }
        }

        private mutating func add(context: String, name: String, number: UInt8, value: String, owner: Int32) {
            let entry = Int32(numbers.count)
            let start = text.count
            let contextMarks = NameTable.fold(context, into: &text)
            let own = text.count - start
            let nameMarks = NameTable.fold(name, into: &text)
            let length = text.count - start
            var marks: ContiguousArray<Bool>?
            if contextMarks != nil || nameMarks != nil {
                var all = contextMarks ?? ContiguousArray(repeating: true, count: own)
                all += nameMarks ?? ContiguousArray(repeating: true, count: length - own)
                all.append(true)
                marks = all
                characters[entry] = all
            }
            numbers.append(number)
            values.append(value)
            owners.append(owner)
            starts.append(Int32(start))
            ownStarts.append(Int32(own))
            var mask: UInt64 = marks == nil ? 0 : NameBytes.marked
            var wordMask: UInt64 = 0
            var startMask: UInt64 = 0
            var pair: (UInt64, UInt64) = (0, 0)
            text.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress, length > 0 else { return }
                let bytes = base + start
                for at in 0 ..< length {
                    let byte = bytes[at]
                    mask |= NameBytes.bit(byte)
                    if at + 1 < length {
                        NameBytes.addPair(byte, bytes[at + 1], to: &pair)
                    }
                    guard marks?[at] ?? true, NameBytes.startsWord(bytes, at: at, own: own) else { continue }
                    wordMask |= NameBytes.bit(byte)
                    if at == 0 || at == own {
                        startMask |= NameBytes.bit(byte)
                    }
                    if at + 1 < length, at <= Int(UInt16.max) {
                        wordStarts.add(first: byte, second: bytes[at + 1], entry: entry, offset: UInt16(at))
                    }
                }
            }
            masks.append(mask)
            wordMasks.append(wordMask)
            startMasks.append(startMask)
            pairs.append(pair.0)
            pairs.append(pair.1)
            words.add(text[start ..< start + length], field: NameTable.bit(number))
        }
    }

    /// Appends `string` folded (`FoldedText`) to `bytes`; where its characters start, unless it's
    /// ASCII.
    private static func fold(_ string: String, into bytes: inout ContiguousArray<UInt8>) -> ContiguousArray<Bool>? {
        let start = bytes.count
        for byte in string.utf8 {
            guard byte < 0x80 else {
                bytes.removeSubrange(start...)
                let folded = FoldedText(string)
                bytes.append(contentsOf: folded.bytes)
                return folded.starts.map { ContiguousArray($0.dropLast()) }
                    ?? ContiguousArray(repeating: true, count: folded.bytes.count)
            }
            bytes.append((0x41 ... 0x5A).contains(byte) ? byte | 0x20 : byte)
        }
        return nil
    }

    func field(of entry: Int) -> LibraryQuery.Field {
        LibraryQuery.Field.allCases[Int(numbers[entry])]
    }

    func value(of entry: Int) -> String {
        values[entry]
    }

    func owner(of entry: Int) -> Int {
        Int(owners[entry])
    }

    /// `field`'s place among `LibraryQuery.Field`'s cases.
    static func number(of field: LibraryQuery.Field) -> UInt8 {
        fieldNumbers[field] ?? 63
    }

    /// The bit of the field numbered `number` in a set of fields.
    static func bit(_ number: UInt8) -> UInt64 {
        1 << UInt64(number)
    }

    private static let fieldNumbers: [LibraryQuery.Field: UInt8] = Dictionary(
        uniqueKeysWithValues: LibraryQuery.Field.allCases.enumerated().map { ($1, UInt8(min($0, 63))) },
    )

    /// The table's arrays, unsafely, for the loops over names.
    private struct Buffers {
        let text: UnsafePointer<UInt8>
        let starts: UnsafeBufferPointer<Int32>
        let own: UnsafeBufferPointer<Int32>
        let masks: UnsafeBufferPointer<UInt64>
        let wordMasks: UnsafeBufferPointer<UInt64>
        let startMasks: UnsafeBufferPointer<UInt64>
        let pairs: UnsafeBufferPointer<UInt64>
        let owners: UnsafeBufferPointer<Int32>
        let numbers: UnsafeBufferPointer<UInt8>
    }

    private func withBuffers<T>(_ body: (Buffers) -> T) -> T {
        text.withUnsafeBufferPointer { text in
            starts.withUnsafeBufferPointer { starts in
                ownStarts.withUnsafeBufferPointer { own in
                    masks.withUnsafeBufferPointer { masks in
                        wordMasks.withUnsafeBufferPointer { wordMasks in
                            startMasks.withUnsafeBufferPointer { startMasks in
                                pairs.withUnsafeBufferPointer { pairs in
                                    owners.withUnsafeBufferPointer { owners in
                                        numbers.withUnsafeBufferPointer { numbers in
                                            let empty = UnsafePointer<UInt8>(bitPattern: 1)!
                                            return body(Buffers(
                                                text: text.baseAddress ?? empty, starts: starts, own: own,
                                                masks: masks, wordMasks: wordMasks, startMasks: startMasks,
                                                pairs: pairs, owners: owners, numbers: numbers,
                                            ))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Ranking

    /// Offers `top` the entries of `fields` holding `typed` as typed at their start, their own name's
    /// or a word's, looked up by its first two bytes; for one byte, every entry holding it, wherever,
    /// from their bits, kept for the scans of what's typed after it.
    func findAtStarts(_ typed: TypedName, fields: FieldSet, table: Int, into top: inout TopMatches) {
        let count = typed.bytes.count
        var holders = ContiguousArray<Int32>()
        defer {
            if count == 1 {
                scans.keep(holders, for: typed, fields: fields.bits)
            }
        }
        typed.bytes.withUnsafeBufferPointer { query in
            guard let query = query.baseAddress else { return }
            withBuffers { buffers in
                func offer(_ entry: Int, _ match: NameMatch, at: Int, length: Int, rank: Int) {
                    top.offer(
                        HoldingMatch(
                            match: match, at: Int32(at), length: Int32(length), field: Int16(rank), table: Int16(table),
                            entry: Int32(entry),
                        ),
                        owner: Int64(table) << 32 | Int64(buffers.owners[entry]),
                    )
                }
                guard count > 1 else {
                    let wanted = typed.mask
                    for (number, range) in ranges where fields.contains(number) {
                        let rank = fields.rank(number)
                        for entry in range {
                            let mask = buffers.masks[entry]
                            guard mask & wanted == wanted else { continue }
                            let start = Int(buffers.starts[entry])
                            let length = Int(buffers.starts[entry + 1]) - start
                            if wanted != 0, mask & NameBytes.marked == 0 {
                                let match: NameMatch = buffers.startMasks[entry] & wanted != 0 ? .start
                                    : buffers.wordMasks[entry] & wanted != 0 ? .word : .inside
                                holders.append(Int32(entry))
                                offer(entry, match, at: -1, length: length, rank: rank)
                            } else if let (match, at) = Self.place(
                                query, count: count, in: buffers.text + start, length: length,
                                own: Int(buffers.own[entry]), characters: characters[Int32(entry)],
                            ) {
                                holders.append(Int32(entry))
                                offer(entry, match, at: at, length: length, rank: rank)
                            }
                        }
                    }
                    return
                }
                wordStarts.forEach(query[0], query[1]) { entry, offset in
                    let rank = fields.rank(buffers.numbers[entry])
                    guard rank >= 0 else { return }
                    let start = Int(buffers.starts[entry])
                    let length = Int(buffers.starts[entry + 1]) - start
                    let name = buffers.text + start
                    guard offset + count <= length, count == 2 || memcmp(name + offset + 2, query + 2, count - 2) == 0
                    else { return }
                    if buffers.masks[entry] & NameBytes.marked != 0, let marks = characters[Int32(entry)],
                       !(marks[offset] && marks[offset + count]) {
                        return
                    }
                    let own = Int(buffers.own[entry])
                    offer(entry, offset == 0 || offset == own ? .start : .word, at: offset, length: length, rank: rank)
                }
            }
        }
    }

    /// Offers `top` the entries of `fields` holding `typed` anywhere, and adds to `ordered` those
    /// holding only its letters in order within `best`'s floor as it stands, `best` keeping the best
    /// of them all. Only the entries holding in order what was typed before it are read, when it
    /// starts with that; it keeps those holding `typed` for the next.
    func scan(
        _ typed: TypedName, fields: FieldSet, table: Int, limit: Int, best: inout MatchQuality,
        top: inout TopMatches, ordered: inout [OrderedMatch],
    ) {
        let entries = scans.entries(extending: typed, fields: fields.bits) ?? ranges.reduce(into: []) { entries, run in
            if fields.contains(run.number) {
                entries.append(contentsOf: run.range.lazy.map { Int32($0) })
            }
        }
        let parts = entries.count >= Self.parallelScan ? min(
            8,
            max(1, ProcessInfo.processInfo.activeProcessorCount / 2),
        ) : 1
        let size = (entries.count + parts - 1) / max(parts, 1)
        let start = best
        var found = [ScanPart](repeating: ScanPart(best: start, limit: limit), count: parts)
        found.withUnsafeMutableBufferPointer { buffer in
            if parts == 1 {
                buffer[0] = scan(typed, entries[...], fields: fields, table: table, limit: limit, best: start)
                return
            }
            nonisolated(unsafe) let found = buffer
            DispatchQueue.concurrentPerform(iterations: parts) { part in
                let range = min(part * size, entries.count) ..< min((part + 1) * size, entries.count)
                found[part] = scan(typed, entries[range], fields: fields, table: table, limit: limit, best: start)
            }
        }
        var holders = ContiguousArray<Int32>()
        holders.reserveCapacity(found.reduce(0) { $0 + $1.holders.count })
        for part in found {
            holders.append(contentsOf: part.holders)
            best.keepBest(part.best)
            for (match, owner) in zip(part.top.kept, part.top.owners) {
                top.offer(match, owner: owner)
            }
            for match in part.ordered {
                Self.keep(match, in: &ordered, capacity: limit * 2)
            }
        }
        scans.keep(holders, for: typed, fields: fields.bits)
    }

    /// Scans of this many entries or more are cut into parts scanned at once.
    static let parallelScan = 16384

    /// What a part of a scan found.
    private struct ScanPart {
        var holders = ContiguousArray<Int32>()
        var top: TopMatches
        var ordered: [OrderedMatch] = []
        var best: MatchQuality

        init(best: MatchQuality, limit: Int) {
            self.best = best
            top = TopMatches(limit: limit)
        }
    }
}

extension NameTable {
    /// `scan`'s work on `entries`.
    private func scan(
        _ typed: TypedName, _ entries: ArraySlice<Int32>, fields: FieldSet, table: Int, limit: Int,
        best start: MatchQuality,
    ) -> ScanPart {
        var part = ScanPart(best: start, limit: limit)
        let count = typed.bytes.count
        let units = Double(typed.units.count)
        let wanted = typed.mask
        let pairs = NameBytes.pairs(typed.bytes)
        let kept = limit * 2
        typed.bytes.withUnsafeBufferPointer { query in
            guard let query = query.baseAddress else { return }
            withBuffers { buffers in
                for slot in entries {
                    let entry = Int(slot)
                    let rank = fields.rank(buffers.numbers[entry])
                    let mask = buffers.masks[entry]
                    guard mask & wanted == wanted else { continue }
                    let start = Int(buffers.starts[entry])
                    let length = Int(buffers.starts[entry + 1]) - start
                    let name = buffers.text + start
                    let marks = mask & NameBytes.marked != 0 ? characters[Int32(entry)] : nil
                    guard let end = Self.forward(typed, query: query, in: name, length: length, characters: marks)
                    else { continue }
                    part.holders.append(slot)
                    let own = Int(buffers.own[entry])
                    let total = marks.map { marks in marks.prefix(length).count { $0 } } ?? length
                    let coverage = units / Double(max(total, 1))
                    if buffers.pairs[2 * entry] & pairs.0 == pairs.0, buffers.pairs[2 * entry + 1] & pairs.1 == pairs.1,
                       let (match, at) = Self.place(
                           query, count: count, in: name, length: length, own: own, characters: marks,
                       ) {
                        part.top.offer(
                            HoldingMatch(
                                match: match, at: Int32(at), length: Int32(length), field: Int16(rank),
                                table: Int16(table), entry: Int32(entry),
                            ),
                            owner: Int64(table) << 32 | Int64(buffers.owners[entry]),
                        )
                        part.best.tightness = 1
                        part.best.coverage = max(part.best.coverage, coverage)
                        continue
                    }
                    // Holding its letters in order only ranks after a full list of names holding it,
                    // and within the floor.
                    guard part.top.count < limit, coverage >= NameRanking.floor * part.best.coverage else { continue }
                    let first = Self.backward(typed, query: query, in: name, end: end, characters: marks)
                    let span = marks.map { marks in (first ..< end).count { marks[$0] } } ?? end - first
                    let tightness = units / Double(max(span, 1))
                    guard tightness >= NameRanking.floor * part.best.tightness else { continue }
                    let score = Self.score(
                        typed,
                        query: query,
                        in: name,
                        from: first,
                        to: end,
                        own: own,
                        characters: marks,
                    )
                    guard score * 2 >= part.best.score else { continue }
                    let match = OrderedMatch(
                        place: NamePlace(length: length, field: rank, table: table, entry: entry),
                        quality: MatchQuality(score: score, tightness: tightness, coverage: coverage),
                    )
                    part.best.keepBest(match.quality)
                    Self.keep(match, in: &part.ordered, capacity: kept)
                }
            }
        }
        return part
    }

    /// Keeps `match` among the best `capacity` of `ordered`, best first.
    @inline(__always)
    private static func keep(_ match: OrderedMatch, in ordered: inout [OrderedMatch], capacity: Int) {
        if ordered.count == capacity, let last = ordered.last, !match.precedes(last) {
            return
        }
        var index = ordered.count
        while index > 0, match.precedes(ordered[index - 1]) {
            index -= 1
        }
        ordered.insert(match, at: index)
        if ordered.count > capacity {
            ordered.removeLast()
        }
    }

    /// Adds to `found` the entries of `fields` with a word one of `twins` is, a plural's `s` aside,
    /// each with the twin of the fewest typos it has, looked up by its first two letters.
    func findTwins(_ twins: [Twin], fields: FieldSet, table: Int, into found: inout [TwinMatch]) {
        var kept: [Int: Int] = [:]
        withBuffers { buffers in
            for (index, twin) in twins.enumerated() {
                let length = twin.bytes.count
                twin.bytes.withUnsafeBufferPointer { word in
                    guard let letters = word.baseAddress, length >= 3 else { return }
                    wordStarts.forEach(letters[0], letters[1]) { entry, offset in
                        let rank = fields.rank(buffers.numbers[entry])
                        guard rank >= 0 else { return }
                        let start = Int(buffers.starts[entry])
                        let size = Int(buffers.starts[entry + 1]) - start
                        let name = buffers.text + start
                        guard offset + length <= size, name[offset + 2] == letters[2],
                              memcmp(name + offset + 3, letters + 3, length - 3) == 0,
                              NameBytes.endsWord(name, at: offset + length, length: size)
                        else { return }
                        let marks = buffers.masks[entry] & NameBytes.marked != 0 ? characters[Int32(entry)] : nil
                        let own = Int(buffers.own[entry])
                        let match: NameMatch = offset == 0 || offset == own ? .start : .word
                        let total = marks.map { marks in marks.prefix(size).count { $0 } } ?? size
                        let place = NamePlace(length: size, field: rank, table: table, entry: entry)
                        let candidate = TwinMatch(
                            place: place, typos: twin.typos, match: match, twin: index,
                            coverage: Double(length) / Double(max(total, 1)),
                        )
                        if let at = kept[entry] {
                            if (candidate.typos, candidate.match) < (found[at].typos, found[at].match) {
                                found[at] = candidate
                            }
                        } else {
                            kept[entry] = found.count
                            found.append(candidate)
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
                        query, count: typed.bytes.count, in: name, length: length, own: own, characters: marks,
                    )?.1 ?? 0
                }
                return Self.score(
                    typed, query: query, in: name, from: at, to: min(at + typed.bytes.count, length), own: own,
                    characters: marks,
                )
            }
        }
    }

    /// The share of `entry`'s characters `count` of them are.
    func coverage(of count: Int, entry: Int) -> Double {
        let length = Int(starts[entry + 1] - starts[entry])
        let marks = masks[entry] & NameBytes.marked != 0 ? characters[Int32(entry)] : nil
        let total = marks.map { marks in marks.prefix(length).count { $0 } } ?? length
        return Double(count) / Double(max(total, 1))
    }

    /// The words of `fields`' names within `typed`'s typos of it.
    func twins(of typed: TypedName, fields: UInt64) -> [Twin] {
        words.twins(of: typed, fields: fields)
    }

    // MARK: Matching

    /// Where `query` is in `name`, its best place first: the name's start or its own name's, a word's
    /// start, inside a word; never starting or ending inside a character.
    @inline(__always)
    private static func place(
        _ query: UnsafePointer<UInt8>, count: Int, in name: UnsafePointer<UInt8>, length: Int, own: Int,
        characters: ContiguousArray<Bool>?,
    ) -> (NameMatch, Int)? {
        guard count <= length else { return nil }
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

    /// Where `typed`'s characters, found in order from the start, each where it's next found, end;
    /// nil when they aren't all there. Fzf's first algorithm, forward.
    private static func forward(
        _ typed: TypedName, query: UnsafePointer<UInt8>, in name: UnsafePointer<UInt8>, length: Int,
        characters: ContiguousArray<Bool>?,
    ) -> Int? {
        var at = 0
        for unit in typed.units {
            guard let found = find(
                query + unit.lowerBound, count: unit.count, in: name, from: at, length: length,
                characters: characters,
            ) else { return nil }
            at = found + unit.count
        }
        return at
    }

    /// Where the tightest span of `typed`'s characters in order ending at `end` starts: back from the
    /// last, each where it's found first. Fzf's first algorithm, backward.
    private static func backward(
        _ typed: TypedName, query: UnsafePointer<UInt8>, in name: UnsafePointer<UInt8>, end: Int,
        characters: ContiguousArray<Bool>?,
    ) -> Int {
        var start = end
        if characters == nil, typed.isASCII {
            for unit in stride(from: typed.bytes.count - 1, through: 0, by: -1) {
                var back = start - 1
                while back > 0, name[back] != query[unit] {
                    back -= 1
                }
                start = back
            }
            return start
        }
        for unit in typed.units.reversed() {
            var back = start - unit.count
            while back > 0, memcmp(name + back, query + unit.lowerBound, unit.count) != 0
                || !(characters.map { $0[back] && $0[back + unit.count] } ?? true) {
                back -= 1
            }
            start = back
        }
        return start
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
        if characters == nil, typed.isASCII {
            let count = typed.bytes.count
            while at < to {
                if unit < count, name[at] == query[unit] {
                    var bonus = NameBytes.startsWord(name, at: at, own: own) ? 8 : 0
                    if run > 0 {
                        bonus = max(bonus, 4)
                    }
                    score += 16 + (unit == 0 ? bonus * 2 : bonus)
                    run += 1
                    unit += 1
                    inGap = false
                } else {
                    score += inGap ? -1 : -3
                    inGap = true
                    run = 0
                }
                at += 1
            }
            return score
        }
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
