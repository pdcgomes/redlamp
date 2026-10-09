import Foundation
import RedlampDocument

/// The names' Finder keys side by side, so a million of them sort without an array each.
struct NameKeys {
    private var bytes = ContiguousArray<UInt8>()
    private var offsets: ContiguousArray<Int32> = [0]
    /// Each key's first sixteen bytes, big-endian and padded with zeros, in two numbers a key: the
    /// whole key, for most names.
    private var prefixes = ContiguousArray<UInt64>()

    init() {}

    init(_ names: some Sequence<String>) {
        for name in names {
            append(name: name)
        }
    }

    /// Room for `count` names of about 16 bytes.
    mutating func reserveCapacity(_ count: Int) {
        bytes.reserveCapacity(count * 16)
        offsets.reserveCapacity(count + 1)
        prefixes.reserveCapacity(2 * count)
    }

    mutating func append(name: String) {
        let start = bytes.count
        FinderOrder.appendKey(of: name, to: &bytes)
        offsets.append(Int32(clamping: bytes.count))
        for half in 0 ..< 2 {
            var prefix: UInt64 = 0
            for index in start + 8 * half ..< start + 8 * half + 8 {
                prefix = prefix << 8 | UInt64(index < bytes.count ? bytes[index] : 0)
            }
            prefixes.append(prefix)
        }
    }

    /// Adds `other`'s keys after these.
    mutating func append(contentsOf other: NameKeys) {
        let base = Int32(clamping: bytes.count)
        bytes.append(contentsOf: other.bytes)
        offsets.append(contentsOf: other.offsets.dropFirst().lazy.map { $0 + base })
        prefixes.append(contentsOf: other.prefixes)
    }

    /// How key `lhs` orders against key `rhs`: true before, false after, nil the same.
    func compare(_ lhs: Int, _ rhs: Int) -> Bool? {
        if prefixes[2 * lhs] != prefixes[2 * rhs] {
            return prefixes[2 * lhs] < prefixes[2 * rhs]
        }
        if prefixes[2 * lhs + 1] != prefixes[2 * rhs + 1] {
            return prefixes[2 * lhs + 1] < prefixes[2 * rhs + 1]
        }
        let (left, right) = (offsets[lhs + 1] - offsets[lhs], offsets[rhs + 1] - offsets[rhs])
        if left <= 16, right <= 16 {
            return left == right ? nil : left < right
        }
        return bytes.withUnsafeBufferPointer { bytes in
            let left = UnsafeBufferPointer(rebasing: bytes[Int(offsets[lhs]) ..< Int(offsets[lhs + 1])])
            let right = UnsafeBufferPointer(rebasing: bytes[Int(offsets[rhs]) ..< Int(offsets[rhs + 1])])
            if left.elementsEqual(right) {
                return nil
            }
            return left.lexicographicallyPrecedes(right)
        }
    }
}
