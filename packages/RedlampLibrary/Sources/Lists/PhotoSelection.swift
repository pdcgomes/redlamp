import Foundation

/// The photos selected in a list and the active one (LIB-10), for the grid, the filmstrip and the
/// loupe. It's a bit per photo ID, which the index keeps as dense as the column store keeps its
/// rows: 125 KB for a million photos. Unlike rows, IDs aren't renumbered when the store compacts,
/// so a selection outlives any change. What follows the list's order takes the list; each change
/// is a pass over the bits at most, cheap enough for the main thread at a million photos.
///
/// Only photos in the list are selected: those that leave it leave the selection (`keep(in:)`).
public struct PhotoSelection: Sendable, Equatable {
    private var bits = RowBits(rows: 0)
    /// How many photos are selected.
    public private(set) var count = 0
    /// The photo the loupe shows and the selection extends from; selected, unless nothing is.
    public private(set) var active: Int64?

    public init() {}

    public var isEmpty: Bool {
        count == 0
    }

    public func contains(_ id: Int64) -> Bool {
        id >= 0 && Int(id >> 6) < bits.wordCount && bits.contains(Int(id))
    }

    /// Selects `id` alone and makes it active: a click.
    public mutating func select(_ id: Int64, in list: PhotoList) {
        guard list.contains(id) else { return }
        bits = RowBits(rows: list.members.wordCount << 6)
        bits.insert(Int(id))
        count = 1
        active = id
    }

    /// Adds `id` to the selection, making it active, or takes it out: a ⌘-click. Taking out the
    /// active photo makes the nearest selected photo after it in `list`, else before it, active.
    public mutating func toggle(_ id: Int64, in list: PhotoList) {
        guard list.contains(id) else { return }
        if contains(id) {
            bits.remove(Int(id))
            count -= 1
            if active == id {
                active = list.index(of: id).flatMap { nearestSelected(to: $0, in: list) }
            }
        } else {
            if bits.wordCount <= Int(id >> 6) {
                bits.grow(to: list.members.wordCount << 6)
            }
            bits.insert(Int(id))
            count += 1
            active = id
        }
    }

    /// Adds every photo from the active one to `id`, in `list`'s order, the active photo staying
    /// as it is: a ⇧-click. With no active photo, it selects `id` alone.
    public mutating func extend(to id: Int64, in list: PhotoList) {
        guard let target = list.index(of: id) else { return }
        guard let active, let anchor = list.index(of: active) else { return select(id, in: list) }
        var words = taken(wordCount: list.members.wordCount)
        var added = 0
        words.withUnsafeMutableBufferPointer { words in
            list.ids.withUnsafeBufferPointer { ids in
                for place in min(anchor, target) ... max(anchor, target) {
                    let id = Int(ids[place])
                    let bit: UInt64 = 1 << UInt64(id & 63)
                    let word = words[id >> 6]
                    added &+= word & bit == 0 ? 1 : 0
                    words[id >> 6] = word | bit
                }
            }
        }
        bits = RowBits(words: words)
        count += added
    }

    /// Selects every photo in `list`, keeping the active one, or making the first active.
    public mutating func selectAll(in list: PhotoList) {
        bits = list.members
        count = list.count
        if active.map(list.contains) != true {
            active = list.first
        }
    }

    public mutating func selectNone() {
        bits = RowBits(rows: 0)
        count = 0
        active = nil
    }

    /// Selects the photos in `list` that aren't selected, and only those. The active photo stays
    /// if it's still selected; otherwise the first selected in the list's order is active.
    public mutating func invert(in list: PhotoList) {
        combine(with: list) { member, selected in member & ~selected }
        if active.map(contains) != true {
            active = nearestSelected(to: 0, in: list)
        }
    }

    /// Keeps only the photos still in `list`, after it changed. When the active photo has left,
    /// the first selected in the list's order is active.
    public mutating func keep(in list: PhotoList) {
        combine(with: list) { member, selected in member & selected }
        if let active, !contains(active) {
            self.active = nearestSelected(to: 0, in: list)
        }
    }

    /// The selected photos' IDs, in `list`'s order.
    public func ids(in list: PhotoList) -> ContiguousArray<Int64> {
        guard count > 0 else { return [] }
        if count == list.count, covers(list) {
            return list.ids
        }
        var ids = ContiguousArray<Int64>()
        ids.reserveCapacity(count)
        bits.words.withUnsafeBufferPointer { words in
            for id in list.ids {
                let word = Int(id >> 6)
                if word < words.count, words[word] >> UInt64(id & 63) & 1 != 0 {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    // MARK: - Bits

    /// The bits' words, at least `wordCount` of them, taken out so they're changed in place.
    private mutating func taken(wordCount: Int) -> ContiguousArray<UInt64> {
        var words = bits.words
        bits = RowBits(rows: 0)
        if words.count < wordCount {
            words.append(contentsOf: repeatElement(0, count: wordCount - words.count))
        }
        return words
    }

    /// Sets each word to `operation` of `list`'s members' word and the selection's, recounting.
    private mutating func combine(with list: PhotoList, _ operation: (UInt64, UInt64) -> UInt64) {
        let members = list.members.words
        var words = ContiguousArray<UInt64>(repeating: 0, count: members.count)
        var selected = 0
        words.withUnsafeMutableBufferPointer { words in
            members.withUnsafeBufferPointer { members in
                bits.words.withUnsafeBufferPointer { current in
                    for index in members.indices {
                        let word = operation(members[index], index < current.count ? current[index] : 0)
                        words[index] = word
                        selected &+= word.nonzeroBitCount
                    }
                }
            }
        }
        bits = RowBits(words: words)
        count = selected
    }

    /// Whether every photo in `list` is selected.
    private func covers(_ list: PhotoList) -> Bool {
        list.members.words.withUnsafeBufferPointer { members in
            bits.words.withUnsafeBufferPointer { current in
                members.indices.allSatisfy { members[$0] & ~(($0 < current.count) ? current[$0] : 0) == 0 }
            }
        }
    }

    /// The selected photo nearest `index` in `list`: at it or after it, else before it.
    private func nearestSelected(to index: Int, in list: PhotoList) -> Int64? {
        guard count > 0, !list.isEmpty else { return nil }
        let start = min(max(index, 0), list.count - 1)
        if let after = list.ids[start...].first(where: contains) {
            return after
        }
        return list.ids[..<start].last(where: contains)
    }

    /// The same photos selected, and the same one active.
    public static func == (lhs: PhotoSelection, rhs: PhotoSelection) -> Bool {
        guard lhs.count == rhs.count, lhs.active == rhs.active else { return false }
        let (left, right) = (lhs.bits.words, rhs.bits.words)
        return (0 ..< max(left.count, right.count)).allSatisfy { index in
            (index < left.count ? left[index] : 0) == (index < right.count ? right[index] : 0)
        }
    }
}
