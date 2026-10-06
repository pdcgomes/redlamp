import Foundation

/// A set of the column store's rows, a bit each: 125 KB for a million.
struct RowBits: Sendable, Hashable {
    private(set) var words: ContiguousArray<UInt64>

    /// Room for `rows` rows, none of them in it, or all of them.
    init(rows: Int, filled: Bool = false) {
        words = ContiguousArray(repeating: filled ? .max : 0, count: (rows + 63) / 64)
        if filled, rows % 64 != 0 {
            words[words.count - 1] = (1 << UInt64(rows % 64)) - 1
        }
    }

    init(words: ContiguousArray<UInt64>) {
        self.words = words
    }

    var wordCount: Int {
        words.count
    }

    func contains(_ row: Int) -> Bool {
        words[row >> 6] & (1 << UInt64(row & 63)) != 0
    }

    mutating func insert(_ row: Int) {
        words[row >> 6] |= 1 << UInt64(row & 63)
    }

    mutating func remove(_ row: Int) {
        words[row >> 6] &= ~(1 << UInt64(row & 63))
    }

    /// Makes room for `rows` rows, the new ones not in it.
    mutating func grow(to rows: Int) {
        let needed = (rows + 63) / 64
        if needed > words.count {
            words.append(contentsOf: repeatElement(0, count: needed - words.count))
        }
    }

    /// How many rows are in it.
    var count: Int {
        words.withUnsafeBufferPointer { words in
            var count = 0
            for word in words {
                count += word.nonzeroBitCount
            }
            return count
        }
    }

    var isEmpty: Bool {
        words.allSatisfy { $0 == 0 }
    }

    mutating func formIntersection(_ other: RowBits) {
        combine(other) { $0 & $1 }
    }

    mutating func formUnion(_ other: RowBits) {
        combine(other) { $0 | $1 }
    }

    /// The rows of `universe` not in it.
    mutating func complement(in universe: RowBits) {
        combine(universe) { ~$0 & $1 }
    }

    /// Takes out the rows of `other`.
    mutating func subtract(_ other: RowBits) {
        combine(other) { $0 & ~$1 }
    }

    private mutating func combine(_ other: RowBits, _ operation: (UInt64, UInt64) -> UInt64) {
        let count = min(words.count, other.words.count)
        words.withUnsafeMutableBufferPointer { words in
            other.words.withUnsafeBufferPointer { other in
                for index in 0 ..< count {
                    words[index] = operation(words[index], other[index])
                }
            }
        }
    }

    /// Calls `body` with each row in it, in order, until it returns false.
    func forEach(_ body: (Int) -> Bool) {
        words.withUnsafeBufferPointer { words in
            for (index, word) in words.enumerated() {
                var remaining = word
                while remaining != 0 {
                    let bit = remaining.trailingZeroBitCount
                    guard body(index << 6 | bit) else { return }
                    remaining &= remaining - 1
                }
            }
        }
    }

    /// Sets each word from `fill`, given the first row of its 64 and how many of them there are.
    mutating func fill(rows: Int, _ fill: (_ first: Int, _ count: Int) -> UInt64) {
        words.withUnsafeMutableBufferPointer { words in
            for index in words.indices {
                let first = index << 6
                words[index] = fill(first, min(64, rows - first))
            }
        }
    }
}
