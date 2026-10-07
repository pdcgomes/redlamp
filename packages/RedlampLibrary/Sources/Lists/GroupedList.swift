import Foundation

/// A list's photos in their groups (LIB-41), as a grid grouped by a key shows them: each group a
/// header, then, while it's open, its photos with their stacks closed as a `StackedList` shows them,
/// each stack in the group of the photo standing for it. Items are found by index in log time.
///
/// Opening or closing a group changes a count kept in a Fenwick tree over the groups: microseconds
/// at a million photos, for the main thread, with a diff of the items that came or went and the
/// group's header updated; opening or closing every group is a pass over the groups. A list that
/// changes is grouped again off the main thread (`updated`), the groups and stacks open before open
/// after, with its diff worked out from the photos that changed when they account for the change.
public struct GroupedList: Sendable, RandomAccessCollection {
    /// What an item shows.
    public enum Item: Sendable, Hashable {
        /// The header of group `index` of `groups`.
        case header(Int)
        /// A photo, or the first of a closed stack, standing for the rest of it.
        case photo(Int64)
    }

    public let groups: PhotoGroups
    /// The groups' cells, one group after another, as though every group were open.
    public private(set) var stacked: StackedList
    /// Open groups, a bit each.
    private var opened: RowBits
    /// Items at each group: its header, and its cells while it's open.
    private var tree: CellTree
    /// Whether the groups a changing list gains come open.
    private var opensNew: Bool
    public private(set) var count: Int

    /// `groups` with their photos' stacks closed, `stacks` being those they were grouped with
    /// (`LibraryGrouping.stacks`), every group open or every one closed.
    public init(_ groups: PhotoGroups, stacks: Stacks, open: Bool = true) {
        self.init(
            groups, stacked: StackedList(Self.cells(of: groups), stacks: stacks),
            opened: RowBits(rows: groups.count, filled: open), opensNew: open,
        )
    }

    init(_ groups: PhotoGroups, stacked: StackedList, opened: RowBits, opensNew: Bool) {
        self.groups = groups
        self.stacked = stacked
        self.opened = opened
        self.opensNew = opensNew
        var sizes = ContiguousArray<Int32>(repeating: 1, count: groups.count)
        var before = 0
        for group in groups.indices {
            let after = stacked.cellCount(before: Int(groups.starts[group + 1]))
            if opened.contains(group) {
                sizes[group] += Int32(after - before)
            }
            before = after
        }
        tree = CellTree(sizes)
        count = tree.total
    }

    /// The groups' photos as one list, group after group, for their cells.
    static func cells(of groups: PhotoGroups) -> PhotoList {
        PhotoList(source: groups.list.source, sort: groups.list.sort, ids: groups.photos)
    }

    // MARK: - Items

    public var startIndex: Int {
        0
    }

    public var endIndex: Int {
        count
    }

    public subscript(position: Int) -> Item {
        let (group, offset) = tree.find(position)
        guard offset > 0 else { return .header(group) }
        return .photo(stacked[cells(of: group).first + offset - 1])
    }

    public func makeIterator() -> Iterator {
        Iterator(list: self)
    }

    /// The items in order, a group at a time.
    public struct Iterator: IteratorProtocol {
        private let list: GroupedList
        private var group = 0
        /// The cells of the open group before `group`, and the next of them.
        private var cells = ContiguousArray<Int64>()
        private var position = 0
        /// The cells before `group`'s.
        private var before = 0

        init(list: GroupedList) {
            self.list = list
        }

        public mutating func next() -> Item? {
            if position < cells.count {
                defer { position += 1 }
                return .photo(cells[position])
            }
            guard group < list.groups.count else { return nil }
            let header = group
            group += 1
            let after = list.stacked.cellCount(before: Int(list.groups.starts[group]))
            var found = ContiguousArray<Int64>()
            swap(&found, &cells)
            found.removeAll(keepingCapacity: true)
            if list.opened.contains(header) {
                let stacked = list.stacked
                stacked.walk(from: before, through: after - 1) { found.append($0) }
            }
            cells = found
            position = 0
            before = after
            return .header(header)
        }
    }

    /// Whether group `group` shows its cells.
    public func isOpen(_ group: Int) -> Bool {
        groups.indices.contains(group) && opened.contains(group)
    }

    /// The item of group `group`'s header.
    public func index(ofHeader group: Int) -> Int {
        tree.prefix(group)
    }

    /// The item of photo `id`'s cell; nil for a photo in a closed group or inside a closed stack, or one
    /// the list doesn't have.
    public func index(of id: Int64) -> Int? {
        guard let group = groups.index(of: id), opened.contains(group), let cell = stacked.index(of: id) else {
            return nil
        }
        return tree.prefix(group) + 1 + cell - cells(of: group).first
    }

    /// The group whose header or cell item `position` is.
    public func group(at position: Int) -> Int {
        tree.find(position).place
    }

    /// How many cells group `group` has, open or closed: its photos with their stacks closed, or open
    /// as they've been opened.
    public func cellCount(of group: Int) -> Int {
        let (first, end) = cells(of: group)
        return end - first
    }

    /// Whether photo `id` has a cell on show: in an open group, and not inside a closed stack.
    public func isVisible(_ id: Int64) -> Bool {
        stacked.isShown(id) && groups.index(of: id).map(isOpen) == true
    }

    /// Group `group`'s cells among `stacked`'s: the first, and the one after its last.
    func cells(of group: Int) -> (first: Int, end: Int) {
        (
            stacked.cellCount(before: Int(groups.starts[group])),
            stacked.cellCount(before: Int(groups.starts[group + 1])),
        )
    }

    /// Calls `body` with each item's index and what it shows, in order.
    func forEachItem(_ body: (Int, Item) -> Void) {
        var index = 0
        var before = 0
        for group in groups.indices {
            body(index, .header(group))
            index += 1
            let after = stacked.cellCount(before: Int(groups.starts[group + 1]))
            if opened.contains(group) {
                stacked.walk(from: before, through: after - 1) { cell in
                    body(index, .photo(cell))
                    index += 1
                }
            }
            before = after
        }
    }

    /// Calls `body` with each cell from item `first` through item `last`, in order.
    func walk(from first: Int, through last: Int, _ body: (Int64) -> Void) {
        guard first >= 0, first <= last, last < count else { return }
        let (startGroup, startOffset) = tree.find(first)
        let (endGroup, endOffset) = tree.find(last)
        for group in startGroup ... endGroup where opened.contains(group) {
            let (cellsStart, cellsEnd) = cells(of: group)
            let from = group == startGroup ? cellsStart + Swift.max(startOffset - 1, 0) : cellsStart
            let through = group == endGroup ? cellsStart + endOffset - 1 : cellsEnd - 1
            if from <= through {
                stacked.walk(from: from, through: through, body)
            }
        }
    }

    /// The first cell from item `start` on that `matches`.
    func firstCell(fromItem start: Int, where matches: (Int64) -> Bool) -> Int64? {
        guard start < count else { return nil }
        let (startGroup, offset) = tree.find(Swift.max(start, 0))
        for group in startGroup ..< groups.count where opened.contains(group) {
            let (first, end) = cells(of: group)
            let from = group == startGroup ? first + Swift.max(offset - 1, 0) : first
            if let found = stacked.firstCell(from: from, before: end, where: matches) {
                return found
            }
        }
        return nil
    }

    /// The last cell before item `end` that `matches`.
    func lastCell(beforeItem end: Int, where matches: (Int64) -> Bool) -> Int64? {
        guard end > 0, count > 0 else { return nil }
        let (endGroup, offset) = tree.find(Swift.min(end, count) - 1)
        for group in stride(from: endGroup, through: 0, by: -1) where opened.contains(group) {
            let (first, last) = cells(of: group)
            let before = group == endGroup ? first + offset : last
            if let found = stacked.lastCell(before: before, from: first, where: matches) {
                return found
            }
        }
        return nil
    }

    // MARK: - Opening and closing

    /// Opens group `group`: its cells are inserted after its header, which is updated. Nothing changes
    /// for any other item.
    @discardableResult
    public mutating func open(_ group: Int) -> PhotoListDiff {
        guard groups.indices.contains(group), !opened.contains(group) else { return PhotoListDiff() }
        opened.insert(group)
        let (first, end) = cells(of: group)
        let header = tree.prefix(group)
        tree.add(Int32(end - first), at: group)
        count += end - first
        return PhotoListDiff(inserted: IndexSet(integersIn: header + 1 ..< header + 1 + end - first), updated: [header])
    }

    /// Closes group `group`: its cells are removed after its header, which is updated.
    @discardableResult
    public mutating func close(_ group: Int) -> PhotoListDiff {
        var selection = StackSelection()
        return close(group, selection: &selection)
    }

    /// Closes group `group` as `close(_:)` does, taking its cells out of `selection`, which never holds a
    /// cell out of sight. When the active cell was one of them, the selected cell nearest after the
    /// header becomes active, else the nearest before it.
    @discardableResult
    public mutating func close(_ group: Int, selection: inout StackSelection) -> PhotoListDiff {
        guard groups.indices.contains(group), opened.contains(group) else { return PhotoListDiff() }
        let (first, end) = cells(of: group)
        if !selection.isEmpty {
            stacked.walk(from: first, through: end - 1) { selection.remove($0) }
        }
        opened.remove(group)
        let header = tree.prefix(group)
        tree.add(-Int32(end - first), at: group)
        count -= end - first
        activateNearest(&selection, to: header)
        return PhotoListDiff(removed: IndexSet(integersIn: header + 1 ..< header + 1 + end - first), updated: [header])
    }

    /// Opens every group, the diff inserting their cells and updating their headers; groups the list
    /// gains as it changes come open.
    @discardableResult
    public mutating func openAll() -> PhotoListDiff {
        opensNew = true
        var sizes = ContiguousArray<Int32>(repeating: 1, count: groups.count)
        var (inserted, updated) = (IndexSet(), IndexSet())
        var (position, before) = (0, 0)
        for group in groups.indices {
            let after = stacked.cellCount(before: Int(groups.starts[group + 1]))
            sizes[group] += Int32(after - before)
            if !opened.contains(group) {
                inserted.insert(integersIn: position + 1 ..< position + 1 + after - before)
                updated.insert(position)
            }
            position += 1 + after - before
            before = after
        }
        opened = RowBits(rows: groups.count, filled: true)
        tree = CellTree(sizes)
        count = position
        return PhotoListDiff(inserted: inserted, updated: updated)
    }

    /// Closes every group, the diff removing their cells and updating their headers; groups the list
    /// gains as it changes come closed.
    @discardableResult
    public mutating func closeAll() -> PhotoListDiff {
        var selection = StackSelection()
        return closeAll(selection: &selection)
    }

    /// Closes every group as `closeAll()` does, and selects nothing, since no cell is on show.
    @discardableResult
    public mutating func closeAll(selection: inout StackSelection) -> PhotoListDiff {
        opensNew = false
        var (removed, updated) = (IndexSet(), IndexSet())
        var (position, before) = (0, 0)
        for group in groups.indices {
            let after = stacked.cellCount(before: Int(groups.starts[group + 1]))
            if opened.contains(group) {
                removed.insert(integersIn: position + 1 ..< position + 1 + after - before)
                updated.insert(group)
                position += after - before
            }
            position += 1
            before = after
        }
        opened = RowBits(rows: groups.count)
        tree = CellTree(ContiguousArray(repeating: 1, count: groups.count))
        count = groups.count
        selection.selectNone()
        return PhotoListDiff(removed: removed, updated: updated)
    }

    // MARK: - Stacks

    /// Opens the closed stack whose first cell is `id`, in an open group, as `StackedList.open` does: its
    /// others are inserted after it, which is updated.
    @discardableResult
    public mutating func openStack(_ id: Int64) -> PhotoListDiff {
        var selection = StackSelection()
        return openStack(id, selection: &selection)
    }

    /// Opens the stack as `openStack(_:)` does, keeping `selection` on the photos it stood for.
    @discardableResult
    public mutating func openStack(_ id: Int64, selection: inout StackSelection) -> PhotoListDiff {
        guard let group = groups.index(of: id), opened.contains(group) else { return PhotoListDiff() }
        let before = stacked.count
        let diff = stacked.open(id, selection: &selection)
        return items(diff, inGroup: group, growingBy: stacked.count - before)
    }

    /// Closes the open stack cell `id` is in, in an open group, as `StackedList.close` does: its others
    /// are removed, and its first updated.
    @discardableResult
    public mutating func closeStack(_ id: Int64) -> PhotoListDiff {
        var selection = StackSelection()
        return closeStack(id, selection: &selection)
    }

    /// Closes the stack as `closeStack(_:)` does, keeping `selection` on the photos it held.
    @discardableResult
    public mutating func closeStack(_ id: Int64, selection: inout StackSelection) -> PhotoListDiff {
        guard let group = groups.index(of: id), opened.contains(group) else { return PhotoListDiff() }
        let before = stacked.count
        let diff = stacked.close(id, selection: &selection)
        return items(diff, inGroup: group, growingBy: stacked.count - before)
    }

    /// `diff`, of `stacked`'s cells in open group `group`, as items, the group having `extra` more cells.
    private mutating func items(_ diff: PhotoListDiff, inGroup group: Int, growingBy extra: Int) -> PhotoListDiff {
        let shift = tree.prefix(group) + 1 - cells(of: group).first
        tree.add(Int32(extra), at: group)
        count += extra
        func shifted(_ cells: IndexSet) -> IndexSet {
            IndexSet(cells.map { $0 + shift })
        }
        return PhotoListDiff(
            removed: shifted(diff.removed), inserted: shifted(diff.inserted), updated: shifted(diff.updated),
        )
    }

    // MARK: - Selections

    /// Makes the selected cell nearest item `position` active, after it or else before it, when the
    /// active cell isn't selected any more; with nothing selected, nothing is active.
    func activateNearest(_ selection: inout StackSelection, to position: Int) {
        guard let active = selection.active, !selection.contains(active) else { return }
        let selected = selection
        guard let nearest = firstCell(fromItem: position, where: selected.contains)
            ?? lastCell(beforeItem: position, where: selected.contains)
        else { return selection.selectNone() }
        selection.activate(nearest)
    }

    /// Takes out of `selection` the cells of closed groups.
    func deselectHidden(_ selection: inout StackSelection) {
        guard !selection.isEmpty, opened.count < groups.count else { return }
        selection.removeAll { !isVisible($0) }
        activateNearest(&selection, to: 0)
    }

    // MARK: - Changes

    /// This list after its list changed (a new list of the view's source, as `LibraryLive` hands them
    /// over), or the store or the stacks its groups came from: grouped again by `grouping`, a grouping
    /// of the store as it is now, by the same key and setting, with the groups and stacks open here
    /// open there, and the diff from this one. `changed` names photos whose rows changed. `selection`
    /// follows the photos it held but for those now in a closed group. At a million photos this takes
    /// about as long as grouping them, so it's for off the main thread.
    public func updated(
        list newList: PhotoList? = nil, grouping: LibraryGrouping, changed: [Int64] = [],
        selection: inout StackSelection,
    ) -> (list: GroupedList, diff: PhotoListDiff) {
        let (new, same) = regrouped(newList ?? groups.list, grouping: grouping, selection: &selection)
        return (new, Self.diff(from: self, to: new, same: same, changed: changed))
    }

    /// This list after `LibraryLive`'s `update` to its list, as `updated(list:grouping:changed:selection:)`
    /// makes it: a reset when the update is one.
    public func updated(_ update: PhotoListUpdate, grouping: LibraryGrouping, selection: inout StackSelection)
        -> (list: GroupedList, diff: PhotoListDiff) {
        guard !update.diff.reset else {
            return (regrouped(update.list, grouping: grouping, selection: &selection).list, PhotoListDiff(reset: true))
        }
        let changed = update.diff.updated.map { update.list[$0] } + update.diff.moved.map { update.list[$0.to] }
        return updated(list: update.list, grouping: grouping, changed: changed, selection: &selection)
    }

    /// `list` grouped by `grouping` as these groups are, with what's open here open there, and for each
    /// of its groups the one here it is, -1 for none.
    private func regrouped(_ list: PhotoList, grouping: LibraryGrouping, selection: inout StackSelection)
        -> (list: GroupedList, same: [Int]) {
        let groups = grouping.groups(of: list, by: groups.key, setting: groups.setting)
        let (same, state) = Self.match(self.groups, groups)
        var open = RowBits(rows: groups.count)
        for group in groups.indices where state[group] < 0 ? opensNew : opened.contains(state[group]) {
            open.insert(group)
        }
        let cells = stacked.remade(list: Self.cells(of: groups), stacks: grouping.stacks)
        let new = GroupedList(groups, stacked: cells, opened: open, opensNew: opensNew)
        selection.carry(from: stacked, to: new.stacked)
        new.deselectHidden(&selection)
        return (new, same)
    }

    /// For each of `new`'s groups, the group of `old` it is and the one whose open state it takes, -1
    /// for none: the group of the same value, or for moments, which keep no value from one grouping
    /// to the next, the group of `old` holding the first of its photos that `old` has, each the same
    /// as one group of `new` at most.
    static func match(_ old: PhotoGroups, _ new: PhotoGroups) -> (same: [Int], state: [Int]) {
        switch new.key {
        case .moment, .momentCamera:
            var taken = [Bool](repeating: false, count: old.count)
            var same = [Int](repeating: -1, count: new.count)
            var state = same
            for group in new.indices {
                let photos = new.photos[Int(new.starts[group]) ..< Int(new.starts[group + 1])]
                guard let found = photos.lazy.compactMap(old.index(of:)).first else { continue }
                state[group] = found
                if !taken[found] {
                    taken[found] = true
                    same[group] = found
                }
            }
            return (same, state)
        default:
            var byValue: [GroupValue: Int] = [:]
            for (group, detail) in old.details.enumerated() {
                byValue[detail.value] = group
            }
            let same = new.details.map { byValue[$0.value] ?? -1 }
            return (same, same)
        }
    }

    /// The diff from `old` to `new`, whose groups are `same`'s of `old`, -1 for none, `changed` naming
    /// photos whose rows changed. Items are compared by ID: a photo's, or for a header a number after
    /// every photo's, a group of `new` taking its match's. What changed is those photos, the photos
    /// that changed group, the stacks' first cells whose badges changed, and the headers that came,
    /// went, or show another name, count, picks, filter, span or state.
    static func diff(from old: GroupedList, to new: GroupedList, same: [Int], changed: [Int64]) -> PhotoListDiff {
        let base = headerBase(old, new)
        let numbers = headerNumbers(same, after: old.groups.count)
        var bits = RowBits(rows: base + (numbers.max().map { Swift.max($0 + 1, old.groups.count) } ?? old.groups.count))
        for id in changed where id >= 0 && id < base {
            bits.insert(Int(id))
        }
        var kept = [Bool](repeating: false, count: old.groups.count)
        for (group, match) in same.enumerated() {
            guard match >= 0 else {
                bits.insert(base + numbers[group])
                continue
            }
            kept[match] = true
            if new.groups.details[group] != old.groups.details[match]
                || new.groups.photoCount(of: group) != old.groups.photoCount(of: match)
                || new.isOpen(group) != old.isOpen(match) {
                bits.insert(base + match)
            }
        }
        for group in kept.indices where !kept[group] {
            bits.insert(base + group)
        }
        for group in new.groups.indices {
            for id in new.groups.photos[Int(new.groups.starts[group]) ..< Int(new.groups.starts[group + 1])] {
                if old.groups.index(of: id) != numbers[group] {
                    bits.insert(Int(id))
                }
            }
        }
        for id in old.groups.photos where !new.groups.list.contains(id) {
            bits.insert(Int(id))
        }
        new.forEachItem { _, item in
            guard case let .photo(cell) = item, new.stacked.isStacked(cell) || old.stacked.isStacked(cell),
                  old.stacked.isShown(cell), old.stacked.badges(of: cell) != new.stacked.badges(of: cell)
            else { return }
            bits.insert(Int(cell))
        }
        return PhotoListDiff(
            from: itemIDs(of: old, base: base) { $0 }, to: itemIDs(of: new, base: base) { numbers[$0] }, changed: bits,
        )
    }

    /// The ID of the first header in a diff from `old` to `new`: one after every photo's. Item IDs
    /// make a `PhotoList`, which keeps a place for each ID from the lowest to the highest.
    static func headerBase(_ old: GroupedList, _ new: GroupedList) -> Int {
        Swift.max(old.groups.list.members.wordCount, new.groups.list.members.wordCount) << 6
    }

    /// Each group's number in a diff from a list of `old` groups: its match's, else one after them.
    static func headerNumbers(_ same: [Int], after old: Int) -> [Int] {
        var numbers = same
        var next = old
        for group in numbers.indices where numbers[group] < 0 {
            numbers[group] = next
            next += 1
        }
        return numbers
    }

    /// `list`'s items as a diff compares them: photos by their IDs, and headers by `base` and their
    /// group's `number`.
    static func itemIDs(of list: GroupedList, base: Int, number: (Int) -> Int) -> PhotoList {
        var ids = ContiguousArray<Int64>()
        ids.reserveCapacity(list.count)
        list.forEachItem { _, item in
            switch item {
            case let .header(group): ids.append(Int64(base + number(group)))
            case let .photo(id): ids.append(id)
            }
        }
        return PhotoList(source: list.groups.list.source, sort: list.groups.list.sort, ids: ids)
    }
}

public extension LibraryGrouping {
    /// `list`'s photos grouped by `key` as `groups(of:by:setting:)` groups them, with their stacks
    /// closed in each group, every group open or every one closed. Call it off the main thread.
    func grouped(_ list: PhotoList, by key: GroupKey, setting: MomentSetting = MomentSetting(), open: Bool = true)
        -> GroupedList {
        GroupedList(groups(of: list, by: key, setting: setting), stacks: stacks, open: open)
    }
}

extension PhotoGroups {
    /// How many photos group `group` has.
    func photoCount(of group: Int) -> Int {
        Int(starts[group + 1] - starts[group])
    }
}
