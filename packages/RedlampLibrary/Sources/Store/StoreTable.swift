import Foundation

/// Where a shard's record for a key, tier and edit is: 32 bytes, so a million of them take 32 MB.
/// The edit is told by its digest's first 31 bits; reading a record checks the whole digest in its
/// header.
struct StoreEntry: Equatable {
    var high: UInt64
    var low: UInt64
    /// The tier in bit 31, the edit digest's first 31 bits below it (0 for the unedited photo).
    var variant: UInt32
    /// When the record was last read or stored, in seconds since 2001.
    var used: UInt32
    /// The record's offset in the pack, in units of `StoreRecord.alignment`.
    var location: UInt32
    var length: UInt32

    static func variant(_ tier: PhotoStore.Tier, _ edit: EditDigest) -> UInt32 {
        let fingerprint = edit.isUnedited ? 0 : max(UInt32(truncatingIfNeeded: edit.high >> 33), 1)
        return UInt32(tier.rawValue) << 31 | fingerprint
    }

    var key: StoreKey {
        StoreKey(high: high, low: low)
    }

    var tier: PhotoStore.Tier {
        variant >> 31 == 0 ? .grid : .preview
    }

    var offset: Int {
        Int(location) * StoreRecord.alignment
    }
}

/// A shard's entries in key order, searched by halving: a sorted array keeps an entry to its
/// 32 bytes, where a hash table's empty slots would add a third or more. It grows by an eighth at a
/// time for the same reason.
struct StoreTable {
    private(set) var entries: ContiguousArray<StoreEntry>

    init(entries: ContiguousArray<StoreEntry> = []) {
        self.entries = entries
    }

    var count: Int {
        entries.count
    }

    /// The bytes the entries take in memory.
    var footprint: Int {
        entries.capacity * MemoryLayout<StoreEntry>.stride
    }

    subscript(index: Int) -> StoreEntry {
        get { entries[index] }
        set { entries[index] = newValue }
    }

    /// The first entry at or after the key and variant.
    func lowerBound(_ key: StoreKey, _ variant: UInt32) -> Int {
        entries.withUnsafeBufferPointer { buffer in
            var lower = 0
            var upper = buffer.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                let entry = buffer[middle]
                if (entry.high, entry.low, entry.variant) < (key.high, key.low, variant) {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }
    }

    func index(of key: StoreKey, _ variant: UInt32) -> Int? {
        let index = lowerBound(key, variant)
        guard index < entries.count else { return nil }
        let entry = entries[index]
        return entry.high == key.high && entry.low == key.low && entry.variant == variant ? index : nil
    }

    /// Adds `entry`, or puts it in place of the one with its key and variant, which it returns.
    mutating func upsert(_ entry: StoreEntry) -> StoreEntry? {
        let index = lowerBound(entry.key, entry.variant)
        if index < entries.count, entries[index].high == entry.high, entries[index].low == entry.low,
           entries[index].variant == entry.variant {
            let replaced = entries[index]
            entries[index] = entry
            return replaced
        }
        if entries.count == entries.capacity {
            entries.reserveCapacity(entries.count + max(entries.count / 8, 16))
        }
        entries.insert(entry, at: index)
        return nil
    }

    mutating func remove(at index: Int) -> StoreEntry {
        entries.remove(at: index)
    }

    /// Removes every tier and edit of `key`, and returns them.
    mutating func removeAll(_ key: StoreKey) -> [StoreEntry] {
        let start = lowerBound(key, 0)
        var end = start
        while end < entries.count, entries[end].high == key.high, entries[end].low == key.low {
            end += 1
        }
        guard end > start else { return [] }
        let removed = Array(entries[start ..< end])
        entries.removeSubrange(start ..< end)
        return removed
    }

    /// Each key once, in order.
    var keys: [StoreKey] {
        var keys: [StoreKey] = []
        keys.reserveCapacity(entries.count)
        for entry in entries where keys.last != entry.key {
            keys.append(entry.key)
        }
        return keys
    }
}
