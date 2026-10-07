import Foundation
import Synchronization

/// Where words start in a table's names, and where each name and its own name start, filed by their
/// first two bytes: for text of two bytes or more, its matches there are a lookup, not a scan.
struct WordStarts: Sendable {
    /// Where each pair of bytes' places start in `entries` and `offsets`, and a last for the end.
    private var buckets = ContiguousArray<Int32>()
    private var entries = ContiguousArray<Int32>()
    private var offsets = ContiguousArray<UInt16>()

    struct Builder {
        private var keys = ContiguousArray<UInt16>()
        private var entries = ContiguousArray<Int32>()
        private var offsets = ContiguousArray<UInt16>()

        mutating func add(first: UInt8, second: UInt8, entry: Int32, offset: UInt16) {
            keys.append(UInt16(first) << 8 | UInt16(second))
            entries.append(entry)
            offsets.append(offset)
        }

        func table() -> WordStarts {
            var table = WordStarts()
            var buckets = ContiguousArray<Int32>(repeating: 0, count: 1 << 16 + 1)
            for key in keys {
                buckets[Int(key) + 1] += 1
            }
            for key in 1 ..< buckets.count {
                buckets[key] += buckets[key - 1]
            }
            var next = buckets
            var entries = ContiguousArray<Int32>(repeating: 0, count: keys.count)
            var offsets = ContiguousArray<UInt16>(repeating: 0, count: keys.count)
            for (place, key) in keys.enumerated() {
                let filed = Int(next[Int(key)])
                entries[filed] = self.entries[place]
                offsets[filed] = self.offsets[place]
                next[Int(key)] += 1
            }
            table.buckets = buckets
            table.entries = entries
            table.offsets = offsets
            return table
        }
    }

    /// Calls `body` with the entry and offset of each place starting with `first` then `second`.
    @inline(__always)
    func forEach(_ first: UInt8, _ second: UInt8, _ body: (Int, Int) -> Void) {
        guard !buckets.isEmpty else { return }
        let key = Int(first) << 8 | Int(second)
        entries.withUnsafeBufferPointer { entries in
            offsets.withUnsafeBufferPointer { offsets in
                for place in Int(buckets[key]) ..< Int(buckets[key + 1]) {
                    body(Int(entries[place]), Int(offsets[place]))
                }
            }
        }
    }
}

// MARK: - Scans kept

/// The entries a table's last scan found holding its text in order, by the fields scanned: a later
/// text starting with that one is held only by them.
final class ScanCache: Sendable {
    private let kept = Mutex<[UInt64: (text: ContiguousArray<UInt8>, entries: ContiguousArray<Int32>)]>([:])

    /// The entries holding in order a text `typed` starts with, a character at a time.
    func entries(extending typed: TypedName, fields: UInt64) -> ContiguousArray<Int32>? {
        kept.withLock { kept in
            guard let found = kept[fields], found.text.count <= typed.bytes.count,
                  found.text.count == 0 || typed.units.contains(where: { $0.upperBound == found.text.count }),
                  typed.bytes.starts(with: found.text)
            else { return nil }
            return found.entries
        }
    }

    func keep(_ entries: ContiguousArray<Int32>, for typed: TypedName, fields: UInt64) {
        kept.withLock { kept in
            if kept.count >= 4, kept[fields] == nil {
                kept.removeAll()
            }
            kept[fields] = (typed.bytes, entries)
        }
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
                        guard fields[word] & wanted != 0, (typed.mask & ~masks[word]).nonzeroBitCount <= budget,
                              (masks[word] & ~typed.mask & ~NameBytes.bit(0x73)).nonzeroBitCount <= budget
                        else { continue }
                        let start = Int(starts[word])
                        let isPlural = length > 3 && bytes[start + length - 1] == 0x73
                        for form in stride(from: length, through: isPlural ? length - 1 : length, by: -1)
                            where abs(form - count) <= budget {
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
        mutating func add(_ text: ArraySlice<UInt8>, field: UInt64) {
            var start = text.startIndex
            var index = text.startIndex
            while index <= text.endIndex {
                if index < text.endIndex, NameBytes.isLetter(text[index]) {
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
