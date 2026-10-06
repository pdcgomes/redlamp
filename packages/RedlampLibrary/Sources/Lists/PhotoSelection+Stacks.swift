import Foundation

/// The cells selected in a stacked list (LIB-28) and the active one. A closed stack's cell selects
/// all of the stack: a rating, flag, label, keyword, move or removal of what's selected reaches
/// every photo it stands for, as one made to a raw and JPEG pair reaches both, and never the top
/// alone with the rest out of sight (`photos(in:)`). A stack that opens keeps each of its cells
/// selected, and one that closes is selected when any of its cells was.
///
/// A bit per cell by photo ID, as `PhotoSelection` keeps them, so a selection outlives the column
/// store's compaction; each change is a pass over the bits or the cells at most.
public struct StackSelection: Sendable, Equatable {
    private var bits = RowBits(rows: 0)
    /// How many cells are selected.
    public private(set) var count = 0
    /// The cell the loupe shows and the selection extends from; selected, unless nothing is.
    public private(set) var active: Int64?

    public init() {}

    public var isEmpty: Bool {
        count == 0
    }

    /// Whether cell `id` is selected.
    public func contains(_ id: Int64) -> Bool {
        id >= 0 && Int(id >> 6) < bits.wordCount && bits.contains(Int(id))
    }

    /// Whether `photo` is selected in `list`: its cell, or the closed stack's it's in.
    public func contains(photo: Int64, in list: StackedList) -> Bool {
        list.cell(for: photo).map(contains) ?? false
    }

    /// Selects cell `id` alone and makes it active: a click.
    public mutating func select(_ id: Int64, in list: StackedList) {
        guard list.isShown(id) else { return }
        bits = RowBits(rows: list.shown.wordCount << 6)
        bits.insert(Int(id))
        count = 1
        active = id
    }

    /// Adds cell `id` to the selection, making it active, or takes it out: a ⌘-click. Taking out the
    /// active cell makes the nearest selected cell after it, else before it, active.
    public mutating func toggle(_ id: Int64, in list: StackedList) {
        guard list.isShown(id) else { return }
        guard contains(id) else {
            insert(id, words: list.shown.wordCount)
            active = id
            return
        }
        remove(id)
        if active == id {
            active = list.index(of: id).flatMap { nearestSelected(to: $0, in: list) }
        }
    }

    /// Adds every cell from the active one to `id`, in `list`'s order, the active cell staying as it
    /// is: a ⇧-click. With no active cell, it selects `id` alone.
    public mutating func extend(to id: Int64, in list: StackedList) {
        guard let target = list.index(of: id) else { return }
        guard let active, let anchor = list.index(of: active) else { return select(id, in: list) }
        var words = bits.words
        bits = RowBits(rows: 0)
        if words.count < list.shown.wordCount {
            words.append(contentsOf: repeatElement(0, count: list.shown.wordCount - words.count))
        }
        var added = 0
        words.withUnsafeMutableBufferPointer { words in
            list.walk(from: min(anchor, target), through: max(anchor, target)) { cell in
                let bit: UInt64 = 1 << UInt64(cell & 63)
                let word = words[Int(cell >> 6)]
                added &+= word & bit == 0 ? 1 : 0
                words[Int(cell >> 6)] = word | bit
            }
        }
        bits = RowBits(words: words)
        count += added
    }

    /// Selects every cell of `list`, keeping the active one, or making the first active.
    public mutating func selectAll(in list: StackedList) {
        bits = list.shown
        count = list.count
        if active.map(list.isShown) != true {
            active = list.first
        }
    }

    public mutating func selectNone() {
        bits = RowBits(rows: 0)
        count = 0
        active = nil
    }

    /// Selects the cells of `list` that aren't selected, and only those. The active cell stays if
    /// it's still selected; otherwise the first selected is active.
    public mutating func invert(in list: StackedList) {
        let shown = list.shown.words
        var words = ContiguousArray<UInt64>(repeating: 0, count: shown.count)
        var selected = 0
        words.withUnsafeMutableBufferPointer { words in
            shown.withUnsafeBufferPointer { shown in
                bits.words.withUnsafeBufferPointer { current in
                    for index in shown.indices {
                        let word = shown[index] & ~(index < current.count ? current[index] : 0)
                        words[index] = word
                        selected &+= word.nonzeroBitCount
                    }
                }
            }
        }
        bits = RowBits(words: words)
        count = selected
        if active.map(contains) != true {
            active = nearestSelected(to: 0, in: list)
        }
    }

    /// The photos selected, in `list`'s order: each selected cell's, every photo of a closed stack.
    public func photos(in list: StackedList) -> ContiguousArray<Int64> {
        var photos = ContiguousArray<Int64>()
        guard count > 0, !list.isEmpty else { return photos }
        photos.reserveCapacity(count)
        list.walk(from: 0, through: list.count - 1) { cell in
            if contains(cell) {
                list.appendPhotos(of: cell, to: &photos)
            }
        }
        return photos
    }

    /// Follows the photos selected from `old` to `new`, the list after it changed: each cell of
    /// `new` is selected when a photo it stands for was. The cell standing for the active photo is
    /// active, else the first selected.
    public mutating func carry(from old: StackedList, to new: StackedList) {
        guard count > 0 else { return }
        var carried = RowBits(rows: new.shown.wordCount << 6)
        var selected = 0
        var photos = ContiguousArray<Int64>()
        bits.forEach { cell in
            photos.removeAll(keepingCapacity: true)
            old.appendPhotos(of: Int64(cell), to: &photos)
            for photo in photos {
                if let target = new.cell(for: photo), !carried.contains(Int(target)) {
                    carried.insert(Int(target))
                    selected += 1
                }
            }
            return true
        }
        let activeCell = active.flatMap { new.cell(for: $0) }
        bits = carried
        count = selected
        active = activeCell.flatMap { contains($0) ? $0 : nil } ?? nearestSelected(to: 0, in: new)
    }

    // MARK: - Bits

    /// Selects cell `id`, of a list whose cells' bits take `words` words.
    mutating func insert(_ id: Int64, words: Int) {
        guard id >= 0, !contains(id) else { return }
        if bits.wordCount <= Int(id >> 6) {
            bits.grow(to: max(words, Int(id >> 6) + 1) << 6)
        }
        bits.insert(Int(id))
        count += 1
    }

    mutating func remove(_ id: Int64) {
        guard contains(id) else { return }
        bits.remove(Int(id))
        count -= 1
    }

    mutating func activate(_ id: Int64) {
        active = id
    }

    /// The selected cell nearest `index` in `list`: at it or after it, else before it.
    private func nearestSelected(to index: Int, in list: StackedList) -> Int64? {
        guard count > 0, !list.isEmpty else { return nil }
        let start = min(max(index, 0), list.count - 1)
        return list.firstCell(from: start, where: contains) ?? list.lastCell(before: start, where: contains)
    }

    /// The same cells selected, and the same one active.
    public static func == (lhs: StackSelection, rhs: StackSelection) -> Bool {
        guard lhs.count == rhs.count, lhs.active == rhs.active else { return false }
        let (left, right) = (lhs.bits.words, rhs.bits.words)
        return (0 ..< max(left.count, right.count)).allSatisfy { index in
            (index < left.count ? left[index] : 0) == (index < right.count ? right[index] : 0)
        }
    }
}
