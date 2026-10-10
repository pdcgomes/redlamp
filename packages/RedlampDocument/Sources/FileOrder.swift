import Foundation

/// The order Folders lists file names in, and the library's lists with it (`key`): the Finder's
/// (`localizedStandardCompare`), ICU's root collation with numbers compared by value, wherever it is one order.
/// Names compare by their characters first, with case, accents and width ignored: whitespace, punctuation and
/// symbols before digits, a run of digits by its value, then letters (`DSC_5513` before `DSC05507`, `IMG_9` before
/// `IMG_10`); then by their accents (`cafe` before `café`); then by case and leading zeros, whichever differs first,
/// lowercase and fewer zeros first (`img_1.JPG` before `IMG_1.jpg`, `IMG_1` before `IMG_01`); then by width and
/// kana (`a` before `ａ`, `か` before `カ`); then by their UTF-16 code units.
///
/// The Finder's comparison isn't an order everywhere, and there the key follows ICU's levels: it compares a run of
/// ASCII digits as a 64-bit number, which wraps past 18446744073709551615, and against fullwidth digits digit by
/// digit; its case folding misreads what follows `ß` and accented Greek; a hiragana or katakana difference
/// outweighs an earlier leading zero but not case, and a width difference outweighs leading zeros only before
/// them; and Hangul syllables with final consonants and Arabic letters with hamza compare inconsistently
/// (`FileOrderTests` lists them). Han characters go by code point, where the Finder has their radicals and
/// strokes, which agree in the main block.
public enum FileOrder {
    public static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        var lhs = lhs
        var rhs = rhs
        if let result = lhs.withUTF8({ a in rhs.withUTF8 { b in compareASCII(a, b) } }) {
            return result
        }
        let (left, right) = (key(lhs), key(rhs))
        return left == right ? .orderedSame : left.lexicographicallyPrecedes(right) ? .orderedAscending
            : .orderedDescending
    }

    /// Bytes that sort as the names do, so a million names sort without comparing strings.
    public static func key(_ name: String) -> [UInt8] {
        var key = ContiguousArray<UInt8>()
        appendKey(of: name, to: &key)
        return Array(key)
    }

    /// Appends `name`'s key to `key`: its primary weights, and after them, each level separated by a byte of 1 and
    /// left out once the rest are common, its secondary weights (accents), its case and leading zeros as bits, its
    /// variants (width, kana) and its UTF-16 code units. An ASCII name without controls stops after its case and
    /// zeros, so most photos' names take 16 bytes or fewer.
    public static func appendKey(of name: String, to key: inout ContiguousArray<UInt8>) {
        var name = name
        let isPlain = name.withUTF8 { bytes in bytes.allSatisfy { $0 < 0x80 && asciiWeights[Int($0)] != 0 } }
        if isPlain {
            name.withUTF8 { appendASCIIKey(of: $0, to: &key) }
        } else {
            var unicode = UnicodeKey()
            unicode.append(name)
            unicode.finish(name, to: &key)
        }
    }
}

// MARK: - ASCII names

extension FileOrder {
    /// Case and leading zeros as bits, seven to a byte from `common`, so the first that differs decides: a 1 for an
    /// uppercase letter or a large kana, a 0 for a lowercase or small one, and a run of digits' leading zeros as as
    /// many 1s and a 0. The bytes stop at the last 1, its own padded with 0s.
    struct TieBits {
        private(set) var count = 0
        private var chunk: UInt8 = 0

        mutating func append(_ bit: Bool, to key: inout ContiguousArray<UInt8>) {
            chunk = chunk << 1 | (bit ? 1 : 0)
            count += 1
            if count % 7 == 0 {
                key.append(common + chunk)
                chunk = 0
            }
        }

        /// A run's leading zeros, stopping at `limit` bits.
        mutating func append(zeros: Int, upTo limit: Int, to key: inout ContiguousArray<UInt8>) {
            for bit in 0 ... zeros where count < limit {
                append(bit < zeros, to: &key)
            }
        }

        func finish(to key: inout ContiguousArray<UInt8>) {
            if count % 7 != 0 {
                key.append(common + chunk << (7 - count % 7))
            }
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    /// The run of digits at `start`: where its significant digits start (a single zero for a run of zeros) and end.
    private static func run(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> (first: Int, end: Int) {
        var end = start
        while end < bytes.count, isDigit(bytes[end]) {
            end += 1
        }
        var first = start
        while first < end - 1, bytes[first] == 0x30 {
            first += 1
        }
        return (first, end)
    }

    /// A run's weight: its lead byte, with the count of its significant digits, then those digits.
    static func appendRun(_ digits: some Collection<UInt8>, to key: inout ContiguousArray<UInt8>) {
        let count = min(digits.count, 255)
        if count < 16 {
            key.append(self.digits + UInt8(count))
        } else {
            key.append(longDigits)
            key.append(UInt8(count))
        }
        key.append(contentsOf: digits)
    }

    private static func appendASCIIKey(of bytes: UnsafeBufferPointer<UInt8>, to key: inout ContiguousArray<UInt8>) {
        var bits = 0
        var lastSet = 0
        var index = 0
        while index < bytes.count {
            let weight = asciiWeights[Int(bytes[index])]
            if weight == digits {
                let (first, end) = run(in: bytes, from: index)
                appendRun(UnsafeBufferPointer(rebasing: bytes[first ..< end]), to: &key)
                bits += first - index + 1
                if first > index {
                    lastSet = bits - 1
                }
                index = end
                continue
            }
            key.append(weight)
            if weight >= letterA {
                bits += 1
                if bytes[index] < 0x61 {
                    lastSet = bits
                }
            }
            index += 1
        }
        guard lastSet > 0 else { return }
        key.append(separator)
        key.append(separator)
        var ties = TieBits()
        index = 0
        while ties.count < lastSet {
            let weight = asciiWeights[Int(bytes[index])]
            if weight == digits {
                let (first, end) = run(in: bytes, from: index)
                ties.append(zeros: first - index, upTo: lastSet, to: &key)
                index = end
            } else {
                if weight >= letterA {
                    ties.append(bytes[index] < 0x61, to: &key)
                }
                index += 1
            }
        }
        ties.finish(to: &key)
    }

    /// The runs of digits at `i` and `j` compared by value, and where they end; nil when one has 255 significant
    /// digits or more, or a byte beyond ASCII after it, which may be a digit carrying the run on. Runs of the same
    /// value differ only in their leading zeros, so the shorter has fewer.
    private static func compareRuns(
        _ a: UnsafeBufferPointer<UInt8>,
        from i: Int,
        _ b: UnsafeBufferPointer<UInt8>,
        from j: Int,
    )
        -> (order: ComparisonResult, ends: (Int, Int))? {
        let (firstA, endA) = run(in: a, from: i)
        let (firstB, endB) = run(in: b, from: j)
        if endA < a.count && a[endA] >= 0x80 || endB < b.count && b[endB] >= 0x80 {
            return nil
        }
        let (countA, countB) = (endA - firstA, endB - firstB)
        guard countA < 255, countB < 255 else { return nil }
        if countA != countB {
            return (countA < countB ? .orderedAscending : .orderedDescending, (endA, endB))
        }
        for k in 0 ..< countA where a[firstA + k] != b[firstB + k] {
            return (a[firstA + k] < b[firstB + k] ? .orderedAscending : .orderedDescending, (endA, endB))
        }
        return (.orderedSame, (endA, endB))
    }

    /// Two ASCII names compared as their keys would order them; nil when either has a byte beyond ASCII or a
    /// control, or a run of 255 digits or more, before they differ.
    private static func compareASCII(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>)
        -> ComparisonResult? {
        var i = 0
        var j = 0
        var tie = ComparisonResult.orderedSame
        while i < a.count, j < b.count {
            let x = a[i]
            let y = b[j]
            guard x < 0x80, y < 0x80 else { return nil }
            let left = asciiWeights[Int(x)]
            let right = asciiWeights[Int(y)]
            guard left != 0, right != 0 else { return nil }
            if left == digits, right == digits {
                guard let (order, (endA, endB)) = compareRuns(a, from: i, b, from: j) else { return nil }
                if order != .orderedSame {
                    return order
                }
                if tie == .orderedSame, endA - i != endB - j {
                    tie = endA - i < endB - j ? .orderedAscending : .orderedDescending
                }
                i = endA
                j = endB
                continue
            }
            if left != right {
                return left < right ? .orderedAscending : .orderedDescending
            }
            if tie == .orderedSame, x != y {
                tie = x > y ? .orderedAscending : .orderedDescending
            }
            i += 1
            j += 1
        }
        if a[i...].contains(where: { $0 >= 0x80 || asciiWeights[Int($0)] == 0 })
            || b[j...].contains(where: { $0 >= 0x80 || asciiWeights[Int($0)] == 0 }) {
            return nil
        }
        if i < a.count {
            return .orderedDescending
        }
        if j < b.count {
            return .orderedAscending
        }
        return tie
    }
}
