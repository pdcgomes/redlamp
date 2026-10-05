import Foundation

/// How a list changed, for views that update cell by cell (the grid and the filmstrip), as
/// `NSCollectionView`'s batch updates take it: photos removed (their indexes before the change),
/// photos inserted (after it), photos that moved (from their index before to their index after), and
/// photos whose rows changed where they are (after it). A photo moves only when its row changed, so a
/// moved photo's cell fetches its row again, as an updated one's does. `reset` replaces everything,
/// as when a list is first shown.
public struct PhotoListDiff: Sendable, Hashable {
    public struct Move: Sendable, Hashable {
        public var from: Int
        public var to: Int

        public init(from: Int, to: Int) {
            self.from = from
            self.to = to
        }
    }

    public var reset = false
    public var removed = IndexSet()
    public var inserted = IndexSet()
    /// By their indexes after the change.
    public var moved: [Move] = []
    public var updated = IndexSet()

    public init(
        reset: Bool = false, removed: IndexSet = [], inserted: IndexSet = [], moved: [Move] = [],
        updated: IndexSet = [],
    ) {
        self.reset = reset
        self.removed = removed
        self.inserted = inserted
        self.moved = moved
        self.updated = updated
    }

    public var isEmpty: Bool {
        !reset && removed.isEmpty && inserted.isEmpty && moved.isEmpty && updated.isEmpty
    }

    /// The diff from `old` to `new`, `changed` naming the photos whose rows changed between them.
    public init(from old: PhotoList, to new: PhotoList, changed: some Sequence<Int64>) {
        let limit = max(old.members.wordCount, new.members.wordCount) << 6
        var bits = RowBits(rows: limit)
        for id in changed where id >= 0 && id < limit {
            bits.insert(Int(id))
        }
        self.init(from: old, to: new, changed: bits)
    }

    /// The diff from `old` to `new`, `changed` holding a bit for each photo whose row changed.
    ///
    /// Photos whose rows didn't change keep their order, so every change is the changed photos'
    /// own: a photo that left or arrived, or one whose row now sorts elsewhere. A changed photo
    /// stays put when it's between the same unchanged photos, and in the same order as the changed
    /// photos beside it, as before; otherwise it moves. When the lists without the changed photos
    /// are the same, one pass along both finds that, and only the changed photos are looked at;
    /// otherwise (a change `changed` didn't name) every photo is, and the unchanged ones found out
    /// of order move as few as keep the rest in order.
    init(from old: PhotoList, to new: PhotoList, changed: RowBits) {
        if Self.othersMatch(old, new, changed) {
            var removed: [Int] = []
            var inserted: [Int] = []
            var changedInBoth: [Move] = []
            changed.forEach { row in
                let id = Int64(row)
                switch (old.index(of: id), new.index(of: id)) {
                case let (from?, to?): changedInBoth.append(Move(from: from, to: to))
                case let (from?, nil): removed.append(from)
                case let (nil, to?): inserted.append(to)
                case (nil, nil): break
                }
                return true
            }
            removed.sort()
            inserted.sort()
            changedInBoth.sort { $0.to < $1.to }
            let (moved, stays) = Self.place(changedInBoth, leftOld: removed, arrivedNew: inserted)
            self.init(
                removed: IndexSet(removed), inserted: IndexSet(inserted), moved: moved.sorted { $0.to < $1.to },
                updated: IndexSet(stays),
            )
            return
        }
        let changedWords = changed.wordCount
        func isChanged(_ id: Int64) -> Bool {
            Int(id >> 6) < changedWords && changed.contains(Int(id))
        }
        var removed = IndexRuns()
        old.ids.withUnsafeBufferPointer { ids in
            for (index, id) in ids.enumerated() where !new.contains(id) {
                removed.append(index)
            }
        }
        var inserted = IndexRuns()
        var changedInBoth: [Move] = []
        var inOrder = true
        var last = -1
        new.ids.withUnsafeBufferPointer { ids in
            for (index, id) in ids.enumerated() {
                guard let from = old.index(of: id) else {
                    inserted.append(index)
                    continue
                }
                if isChanged(id) {
                    changedInBoth.append(Move(from: from, to: index))
                } else {
                    inOrder = inOrder && from > last
                    last = from
                }
            }
        }

        var moved: [Move] = []
        if !inOrder {
            var unchanged: [Move] = []
            new.ids.withUnsafeBufferPointer { ids in
                for (index, id) in ids.enumerated() where !isChanged(id) {
                    if let from = old.index(of: id) {
                        unchanged.append(Move(from: from, to: index))
                    }
                }
            }
            let keeps = Self.longestIncreasing(unchanged.map(\.from))
            moved = zip(unchanged, keeps).compactMap { $1 ? nil : $0 }
        }

        let (changedMoves, stays) = Self.place(
            changedInBoth, leftOld: (removed.indexes + moved.map(\.from)).sorted(),
            arrivedNew: (inserted.indexes + moved.map(\.to)).sorted(),
        )
        self.init(
            removed: removed.indexSet, inserted: inserted.indexSet,
            moved: (moved + changedMoves).sorted { $0.to < $1.to }, updated: IndexSet(stays),
        )
    }

    /// Whether `old` and `new` are the same once the photos in `changed` are left out of both.
    private static func othersMatch(_ old: PhotoList, _ new: PhotoList, _ changed: RowBits) -> Bool {
        old.ids.withUnsafeBufferPointer { old in
            new.ids.withUnsafeBufferPointer { new in
                changed.words.withUnsafeBufferPointer { changed in
                    func isChanged(_ id: Int64) -> Bool {
                        let word = Int(id >> 6)
                        return word < changed.count && changed[word] >> UInt64(id & 63) & 1 != 0
                    }
                    var (left, right) = (0, 0)
                    while true {
                        while left < old.count, isChanged(old[left]) {
                            left += 1
                        }
                        while right < new.count, isChanged(new[right]) {
                            right += 1
                        }
                        guard left < old.count, right < new.count else {
                            return left == old.count && right == new.count
                        }
                        guard old[left] == new[right] else { return false }
                        left += 1
                        right += 1
                    }
                }
            }
        }
    }

    /// Which of the changed photos in both lists (`changedInBoth`, in their order after the change)
    /// move, and the indexes of those that stay, given the indexes of the other photos that aren't
    /// kept in place: those that left or moved (`leftOld`), and those that arrived or moved
    /// (`arrivedNew`), each sorted.
    private static func place(
        _ changedInBoth: [Move],
        leftOld: [Int],
        arrivedNew: [Int],
    ) -> (moved: [Move], stays: [Int]) {
        guard !changedInBoth.isEmpty else { return ([], []) }
        let leftOld = (leftOld + changedInBoth.map(\.from)).sorted()
        let arrivedNew = (arrivedNew + changedInBoth.map(\.to)).sorted()
        /// How many of the photos kept in place come before an index, before the change and after.
        func keptBefore(_ index: Int, _ others: [Int]) -> Int {
            index - countBelow(index, in: others)
        }
        var moved: [Move] = []
        var gaps: [Int: [Move]] = [:]
        for move in changedInBoth {
            let gap = keptBefore(move.from, leftOld)
            if gap == keptBefore(move.to, arrivedNew) {
                gaps[gap, default: []].append(move)
            } else {
                moved.append(move)
            }
        }
        var stays: [Int] = []
        for group in gaps.values {
            for (move, keep) in zip(group, longestIncreasing(group.map(\.from))) {
                if keep {
                    stays.append(move.to)
                } else {
                    moved.append(move)
                }
            }
        }
        return (moved, stays.sorted())
    }

    /// Applies the diff to `elements`, the list's before it, making each photo inserted from its
    /// index after it. A diff that resets has nothing to apply: the list replaces everything.
    public func apply<Elements: RangeReplaceableCollection>(
        to elements: inout Elements, inserting element: (Int) -> Elements.Element,
    ) where Elements.Index == Int {
        precondition(!reset, "a reset replaces the list")
        let leaving = (Array(removed) + moved.map(\.from)).sorted()
        var arriving = inserted.map { (index: $0, element: element($0)) }
            + moved.map { (index: $0.to, element: elements[$0.from]) }
        arriving.sort { $0.index < $1.index }
        var result = Elements()
        result.reserveCapacity(elements.count - leaving.count + arriving.count)
        var source = elements.startIndex
        var left = 0
        var next = 0
        while true {
            if next < arriving.count, arriving[next].index == result.count {
                result.append(arriving[next].element)
                next += 1
                continue
            }
            while left < leaving.count, leaving[left] == source {
                left += 1
                source += 1
            }
            guard source < elements.endIndex else { break }
            result.append(elements[source])
            source += 1
        }
        precondition(next == arriving.count, "the diff isn't of these elements")
        elements = result
    }

    /// Which of `values` (all different) make one of their longest increasing runs, in order.
    static func longestIncreasing(_ values: [Int]) -> [Bool] {
        var tails: [Int] = []
        var previous = [Int](repeating: -1, count: values.count)
        for (index, value) in values.enumerated() {
            var low = tails.count
            if let last = tails.last, values[last] > value {
                low = 0
                var high = tails.count
                while low < high {
                    let middle = (low + high) / 2
                    if values[tails[middle]] < value {
                        low = middle + 1
                    } else {
                        high = middle
                    }
                }
            }
            if low > 0 {
                previous[index] = tails[low - 1]
            }
            if low == tails.count {
                tails.append(index)
            } else {
                tails[low] = index
            }
        }
        var member = [Bool](repeating: false, count: values.count)
        var index = tails.last ?? -1
        while index >= 0 {
            member[index] = true
            index = previous[index]
        }
        return member
    }

    /// How many of `sorted` are below `value`.
    private static func countBelow(_ value: Int, in sorted: [Int]) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}

/// Indexes gathered in ascending order as ranges, made into an `IndexSet` once.
private struct IndexRuns {
    private var ranges: [Range<Int>] = []

    mutating func append(_ index: Int) {
        if let last = ranges.last, last.upperBound == index {
            ranges[ranges.count - 1] = last.lowerBound ..< index + 1
        } else {
            ranges.append(index ..< index + 1)
        }
    }

    var indexes: [Int] {
        ranges.flatMap(\.self)
    }

    var indexSet: IndexSet {
        var set = IndexSet()
        for range in ranges {
            set.insert(integersIn: range)
        }
        return set
    }
}
