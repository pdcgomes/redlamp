import Foundation

/// Photos whose content keys and file sizes agree: copies of one file, perhaps, until their full
/// hashes say so (LIB-39).
public struct DuplicateCandidateGroup: Sendable, Hashable {
    public var contentKey: ContentKey
    public var size: Int64
    /// Two or more, in ID order.
    public var photos: [Int64]

    public init(contentKey: ContentKey, size: Int64, photos: [Int64]) {
        self.contentKey = contentKey
        self.size = size
        self.photos = photos
    }
}

/// The library's candidates, grouped in one pass over its photos.
public struct DuplicateCandidates: Sendable, Hashable {
    /// The largest files first, then by their first photo.
    public var groups: [DuplicateCandidateGroup]
    /// The photos with a content key, in a group or not.
    public var photosGrouped: Int
    /// The bytes grouping took at once.
    public var memoryFootprint: Int

    public init(groups: [DuplicateCandidateGroup], photosGrouped: Int, memoryFootprint: Int) {
        self.groups = groups
        self.photosGrouped = photosGrouped
        self.memoryFootprint = memoryFootprint
    }

    /// The photos in a group.
    public var photoCount: Int {
        groups.reduce(0) { $0 + $1.photos.count }
    }

    /// The photos in a group but its first: what removing every copy but one would remove, if each
    /// group's photos turn out to be one file.
    public var copyCount: Int {
        photoCount - groups.count
    }
}

/// Groups photos by content key and size as they're added: 32 bytes a photo, and a table of twice
/// as many 4-byte slots as photos while grouping. The table is addressed by the key's bits, which
/// SHA-256 spreads evenly, so grouping takes one pass whatever the library's size, with no index
/// on content keys in the database (schema version 2).
public struct DuplicateGrouper: Sendable {
    struct Entry: Sendable {
        var high: UInt64
        var low: UInt64
        var size: Int64
        var photo: Int64

        func sameContent(as other: Entry) -> Bool {
            high == other.high && low == other.low && size == other.size
        }
    }

    private var entries: ContiguousArray<Entry> = []

    /// Room for `capacity` photos, so adding them doesn't grow the entries past them.
    public init(capacity: Int = 0) {
        entries.reserveCapacity(capacity)
    }

    public var count: Int {
        entries.count
    }

    public mutating func add(photo: Int64, contentKey: ContentKey, size: Int64) {
        let (high, low) = contentKey.data.withUnsafeBytes { bytes in
            (
                UInt64(bigEndian: bytes.loadUnaligned(as: UInt64.self)),
                UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self)),
            )
        }
        add(photo: photo, high: high, low: low, size: size)
    }

    /// Adds a photo by its content key's bytes 0 to 7 and 8 to 15, big-endian.
    mutating func add(photo: Int64, high: UInt64, low: UInt64, size: Int64) {
        precondition(entries.count < Int32.max, "more photos than a table slot can name")
        entries.append(Entry(high: high, low: low, size: size, photo: photo))
    }

    /// The groups of two or more photos whose content keys and sizes agree.
    public func candidates() -> DuplicateCandidates {
        let bits = max(4, Int.bitWidth - (2 * entries.count).leadingZeroBitCount)
        let mask = (1 << bits) - 1
        var slots = ContiguousArray<Int32>(repeating: -1, count: 1 << bits)
        // Each copy, by the entry that came first with its content.
        var copies: ContiguousArray<(first: Int32, copy: Int32)> = []
        entries.withUnsafeBufferPointer { entries in
            slots.withUnsafeMutableBufferPointer { slots in
                for index in entries.indices {
                    let entry = entries[index]
                    var slot =
                        Int(truncatingIfNeeded: ((entry.high ^ entry.low) &* 0x9E37_79B9_7F4A_7C15) >> (64 - bits))
                    while true {
                        let held = slots[slot]
                        if held < 0 {
                            slots[slot] = Int32(index)
                            break
                        }
                        if entries[Int(held)].sameContent(as: entry) {
                            copies.append((held, Int32(index)))
                            break
                        }
                        slot = (slot + 1) & mask
                    }
                }
            }
        }
        let footprint = entries.capacity * MemoryLayout<Entry>.stride + slots.capacity * MemoryLayout<Int32>.stride
            + copies.capacity * MemoryLayout<(Int32, Int32)>.stride

        copies.sort { $0.first < $1.first }
        var groups: [DuplicateCandidateGroup] = []
        var start = 0
        while start < copies.count {
            let first = copies[start].first
            var end = start
            var photos = [entries[Int(first)].photo]
            while end < copies.count, copies[end].first == first {
                photos.append(entries[Int(copies[end].copy)].photo)
                end += 1
            }
            let entry = entries[Int(first)]
            let key = withUnsafeBytes(of: (entry.high.bigEndian, entry.low.bigEndian)) { Data($0) }
            groups.append(DuplicateCandidateGroup(
                contentKey: ContentKey(data: key)!, size: entry.size, photos: photos.sorted(),
            ))
            start = end
        }
        groups.sort { $0.size != $1.size ? $0.size > $1.size : $0.photos[0] < $1.photos[0] }
        return DuplicateCandidates(groups: groups, photosGrouped: entries.count, memoryFootprint: footprint)
    }
}
