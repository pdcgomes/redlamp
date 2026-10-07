import Foundation

/// A list with its stacks shown (LIB-28): a cell for each photo on its own, and one for each stack
/// the list holds two or more photos of (frames, for a burst or a manual stack), which shows the
/// stack's top photo, or the first of its photos the list has, and stands for the others until it's
/// opened. A stack's cell sits where that photo sits in the list's order, so a stack stays together
/// in every sort; open, its other photos follow it in the stack's order. A raw and its JPEG are one
/// frame of a burst or a manual stack, and open on their own.
///
/// Opening or closing one stack changes a cell count kept in a Fenwick tree over the list's places:
/// microseconds at a million photos, for the main thread, with a diff of the cells that came or
/// went. Cells are fetched by index in log time.
public struct StackedList: Sendable, RandomAccessCollection {
    /// What a stack's first cell shows of it.
    public struct Badge: Sendable, Hashable {
        public let kind: Stack.Kind
        /// The list's photos of it: a burst's or a manual stack's frames, a raw and its JPEG counting
        /// once, or a pair's photos.
        public let count: Int
        public let isOpen: Bool
    }

    public let list: PhotoList
    public let stacks: Stacks
    /// Cells at each place of `list`: 1 for a photo on its own or a closed stack's first, an open
    /// stack's cells at its first photo's place, and 0 for a stack's others.
    private var sizes: ContiguousArray<Int32>
    private var tree: CellTree
    /// The open stacks' cells, one stack's after another: each open place's first in `openStore`,
    /// and -1 for the other places. A closed stack's cells stay until they're half the store.
    private var openStarts: ContiguousArray<Int32>
    private var openStore: ContiguousArray<Int64>
    private var unused = 0
    /// Open stacks, a bit each by their index in `stacks`.
    private var opened: RowBits
    /// For each stack the list shows as one: its first photo's place; -1 for the others.
    private let places: ContiguousArray<Int32>
    /// For each stack the list shows as one: the photos (a pair's) or frames it has of it.
    private let counts: ContiguousArray<Int32>
    /// The cells' photos, a bit each by ID.
    private(set) var shown: RowBits
    public private(set) var count: Int

    /// `list` with `stacks` shown, every one closed, or every one open.
    public init(_ list: PhotoList, stacks: Stacks, open: Bool = false) {
        self.init(list, stacks: stacks, opened: RowBits(rows: stacks.count, filled: open))
    }

    init(_ list: PhotoList, stacks: Stacks, opened: RowBits) {
        var sizes = ContiguousArray<Int32>(repeating: 1, count: list.count)
        var places = ContiguousArray<Int32>(repeating: -1, count: stacks.count)
        var counts = ContiguousArray<Int32>(repeating: 0, count: stacks.count)
        for group in stacks.groups {
            var frames: Int32 = 0
            var first: Int?
            for top in stacks.members(of: group) {
                guard let place = Self.firstPlace(ofFrame: top, in: list, stacks: stacks) else { continue }
                frames += 1
                first = first ?? place
            }
            guard frames > 1, let first else { continue }
            places[group] = Int32(first)
            counts[group] = frames
            for top in stacks.members(of: group) {
                guard let pair = stacks.pairIndex(of: top) else {
                    if let place = list.index(of: top) {
                        sizes[place] = 0
                    }
                    continue
                }
                for photo in stacks.members(of: pair) {
                    if let place = list.index(of: photo) {
                        sizes[place] = 0
                    }
                }
            }
            sizes[first] = 1
        }
        for pair in stacks.pairs {
            let members = stacks.members(of: pair)
            var present: Int32 = 0
            var first: Int?
            for photo in members {
                if let place = list.index(of: photo) {
                    present += 1
                    first = first ?? place
                }
            }
            guard present > 1, let first else { continue }
            places[pair] = Int32(first)
            counts[pair] = present
            if let group = stacks.groupIndex(of: members[members.startIndex]), places[group] >= 0 {
                continue
            }
            for photo in members {
                if let place = list.index(of: photo), place != first {
                    sizes[place] = 0
                }
            }
        }
        self.list = list
        self.stacks = stacks
        self.sizes = sizes
        self.places = places
        self.counts = counts
        self.opened = opened
        openStarts = []
        openStore = []
        tree = CellTree([])
        shown = RowBits(rows: 0)
        count = 0
        openAndCount()
    }

    /// Gives each open stack its cells, every other being closed, and counts the cells.
    private mutating func openAndCount() {
        var sizes = ContiguousArray<Int32>()
        swap(&sizes, &self.sizes)
        var starts = ContiguousArray<Int32>(repeating: -1, count: sizes.count)
        var store = ContiguousArray<Int64>()
        let lookup = Lookup(self)
        let (places, groups, pairs) = (places, stacks.groups, stacks.pairs)
        opened.forEach { stack in
            guard stack < places.count, places[stack] >= 0 else { return true }
            let place = Int(places[stack])
            let start = store.count
            if groups.contains(stack) {
                lookup.appendCells(ofGroup: stack, to: &store)
            } else if pairs.contains(stack), lookup.groupSlot(ofPair: stack) == nil {
                lookup.appendCells(ofPair: stack, to: &store)
            } else {
                return true
            }
            starts[place] = Int32(start)
            sizes[place] = Int32(store.count - start)
            return true
        }
        var shown = RowBits(rows: list.members.wordCount << 6)
        list.ids.withUnsafeBufferPointer { ids in
            for place in sizes.indices {
                if sizes[place] == 1 {
                    shown.insert(Int(ids[place]))
                }
            }
        }
        for cell in store {
            shown.insert(Int(cell))
        }
        tree = CellTree(sizes)
        count = tree.total
        self.sizes = sizes
        openStarts = starts
        openStore = store
        unused = 0
        self.shown = shown
    }

    // MARK: - Cells

    public var startIndex: Int {
        0
    }

    public var endIndex: Int {
        count
    }

    public subscript(position: Int) -> Int64 {
        let (place, offset) = tree.find(position)
        guard offset > 0 else { return list.ids[place] }
        return openStore[Int(openStarts[place]) + offset]
    }

    public func makeIterator() -> Iterator {
        Iterator(ids: list.ids, sizes: sizes, openStarts: openStarts, openStore: openStore)
    }

    /// The cells in order, a place at a time.
    public struct Iterator: IteratorProtocol {
        private let ids: ContiguousArray<Int64>
        private let sizes: ContiguousArray<Int32>
        private let openStarts: ContiguousArray<Int32>
        private let openStore: ContiguousArray<Int64>
        private var place = 0
        /// The open cells left at the place before `place`, in `openStore`.
        private var position = 0
        private var end = 0

        init(
            ids: ContiguousArray<Int64>, sizes: ContiguousArray<Int32>, openStarts: ContiguousArray<Int32>,
            openStore: ContiguousArray<Int64>,
        ) {
            self.ids = ids
            self.sizes = sizes
            self.openStarts = openStarts
            self.openStore = openStore
        }

        public mutating func next() -> Int64? {
            if position < end {
                defer { position += 1 }
                return openStore[position]
            }
            while place < sizes.count {
                let current = place
                place += 1
                let size = Int(sizes[current])
                if size == 1 {
                    return ids[current]
                }
                if size > 1 {
                    let start = Int(openStarts[current])
                    (position, end) = (start + 1, start + size)
                    return openStore[start]
                }
            }
            return nil
        }
    }

    /// Calls `body` with each cell's index and photo, in order.
    func forEachCell(_ body: (Int, Int64) -> Void) {
        list.ids.withUnsafeBufferPointer { ids in
            sizes.withUnsafeBufferPointer { sizes in
                openStarts.withUnsafeBufferPointer { starts in
                    openStore.withUnsafeBufferPointer { store in
                        var index = 0
                        for place in sizes.indices {
                            let size = Int(sizes[place])
                            if size == 1 {
                                body(index, ids[place])
                            } else if size > 1 {
                                let start = Int(starts[place])
                                for offset in 0 ..< size {
                                    body(index + offset, store[start + offset])
                                }
                            }
                            index += size
                        }
                    }
                }
            }
        }
    }

    /// Whether photo `id` has a cell.
    public func isShown(_ id: Int64) -> Bool {
        id >= 0 && Int(id >> 6) < shown.wordCount && shown.contains(Int(id))
    }

    /// The cell of photo `id`; nil for a photo inside a closed stack, or one the list doesn't have.
    public func index(of id: Int64) -> Int? {
        guard isShown(id), let place = list.index(of: id) else { return nil }
        if sizes[place] > 0 {
            return tree.prefix(place)
        }
        guard let slot = slot(of: id), let cells = openCells(at: slot), let offset = cells.firstIndex(of: id)
        else { return nil }
        return tree.prefix(slot) + offset - cells.startIndex
    }

    /// The photo whose cell stands for `id`: itself when it has one, else the first of the closed
    /// stack it's in; nil for a photo the list doesn't have.
    public func cell(for id: Int64) -> Int64? {
        guard list.contains(id) else { return nil }
        if isShown(id) {
            return id
        }
        if let group = stacks.groupIndex(of: id), places[group] >= 0, !opened.contains(group) {
            return list.ids[Int(places[group])]
        }
        if let pair = stacks.pairIndex(of: id), places[pair] >= 0 {
            return list.ids[Int(places[pair])]
        }
        return nil
    }

    /// The photos cell `id` stands for, in the stack's order: a closed stack's, the list's photos of
    /// it; else the photo alone.
    public func photos(of id: Int64) -> [Int64] {
        var photos = ContiguousArray<Int64>()
        appendPhotos(of: id, to: &photos)
        return Array(photos)
    }

    func appendPhotos(of id: Int64, to photos: inout ContiguousArray<Int64>) {
        guard isShown(id), let place = list.index(of: id) else { return }
        if let group = stacks.groupIndex(of: id), places[group] == Int32(place), !opened.contains(group) {
            for top in stacks.members(of: group) {
                guard let pair = stacks.pairIndex(of: top) else {
                    if list.contains(top) {
                        photos.append(top)
                    }
                    continue
                }
                for photo in stacks.members(of: pair) where list.contains(photo) {
                    photos.append(photo)
                }
            }
            return
        }
        if let pair = stacks.pairIndex(of: id), places[pair] == Int32(place), !opened.contains(pair) {
            for photo in stacks.members(of: pair) where list.contains(photo) {
                photos.append(photo)
            }
            return
        }
        photos.append(id)
    }

    /// What cell `id` shows of the stacks it's the first cell of: a burst or a manual stack, and a
    /// pair shown as one.
    public func badges(of id: Int64) -> (stack: Badge?, pair: Badge?) {
        guard isShown(id), let place = list.index(of: id) else { return (nil, nil) }
        var stack: Badge?
        var pair: Badge?
        if let group = stacks.groupIndex(of: id), places[group] == Int32(place) {
            stack = Badge(kind: stacks.kinds[group], count: Int(counts[group]), isOpen: opened.contains(group))
        }
        if let shownPair = stacks.pairIndex(of: id), places[shownPair] == Int32(place), isVisible(pair: shownPair) {
            pair = Badge(kind: .pair, count: Int(counts[shownPair]), isOpen: opened.contains(shownPair))
        }
        return (stack, pair)
    }

    /// Whether photo `id` is in a stack: its cell may carry a badge.
    func isStacked(_ id: Int64) -> Bool {
        stacks.groupIndex(of: id) != nil || stacks.pairIndex(of: id) != nil
    }

    /// The open stacks' cells at `place`; nil for a place without.
    private func openCells(at place: Int) -> ArraySlice<Int64>? {
        let start = Int(openStarts[place])
        return start < 0 ? nil : openStore[start ..< start + Int(sizes[place])]
    }

    /// Makes `cells` the open cells at `place`, whose size the caller makes their count; the place
    /// had `old` open cells.
    private mutating func setOpenCells(_ cells: some Collection<Int64>, at place: Int, replacing old: Int) {
        if openStarts[place] >= 0 {
            unused += old
        }
        openStarts[place] = Int32(openStore.count)
        openStore.append(contentsOf: cells)
    }

    private mutating func removeOpenCells(at place: Int, count: Int) {
        openStarts[place] = -1
        unused += count
    }

    /// Drops the cells no open place holds once they're half the store, with each open place's
    /// size its count.
    private mutating func compact() {
        guard unused > Swift.max(1 << 16, openStore.count / 2) else { return }
        var store = ContiguousArray<Int64>()
        store.reserveCapacity(openStore.count - unused)
        for place in openStarts.indices where openStarts[place] >= 0 {
            let start = Int(openStarts[place])
            openStarts[place] = Int32(store.count)
            store.append(contentsOf: openStore[start ..< start + Int(sizes[place])])
        }
        openStore = store
        unused = 0
    }

    // MARK: - Opening and closing

    /// Opens the closed stack whose first cell is `id`: a burst or a manual stack, else a pair, to
    /// show its raw and its JPEG apart. Returns how the cells changed: the stack's others inserted
    /// after its first, which is updated. Nothing changes for any other cell.
    @discardableResult
    public mutating func open(_ id: Int64) -> PhotoListDiff {
        var selection = StackSelection()
        return open(id, selection: &selection)
    }

    /// Opens the stack as `open(_:)` does, keeping `selection` on the photos it stood for: each of
    /// a selected stack's cells is selected.
    @discardableResult
    public mutating func open(_ id: Int64, selection: inout StackSelection) -> PhotoListDiff {
        guard isShown(id), let place = list.index(of: id) else { return PhotoListDiff() }
        if let group = stacks.groupIndex(of: id), places[group] == Int32(place), !opened.contains(group) {
            opened.insert(group)
            var cells = ContiguousArray<Int64>()
            Lookup(self).appendCells(ofGroup: group, to: &cells)
            setOpenCells(cells, at: place, replacing: 0)
            return grow(slot: place, at: 0, by: cells.count - 1, cells: cells, selection: &selection)
        }
        guard let pair = stacks.pairIndex(of: id), places[pair] == Int32(place), !opened.contains(pair),
              isVisible(pair: pair)
        else { return PhotoListDiff() }
        opened.insert(pair)
        var photos = ContiguousArray<Int64>()
        Lookup(self).appendCells(ofPair: pair, to: &photos)
        guard let slot = groupSlot(ofPair: pair), let open = openCells(at: slot) else {
            setOpenCells(photos, at: place, replacing: 0)
            return grow(slot: place, at: 0, by: photos.count - 1, cells: photos, selection: &selection)
        }
        var cells = ContiguousArray(open)
        guard let at = cells.firstIndex(of: id) else { return PhotoListDiff() }
        cells.replaceSubrange(at ... at, with: photos)
        setOpenCells(cells, at: slot, replacing: open.count)
        return grow(slot: slot, at: at, by: photos.count - 1, cells: cells, selection: &selection)
    }

    /// Closes the open stack cell `id` is in, a pair before the burst or manual stack holding it.
    /// Returns how the cells changed: the stack's others removed, and its first updated.
    @discardableResult
    public mutating func close(_ id: Int64) -> PhotoListDiff {
        var selection = StackSelection()
        return close(id, selection: &selection)
    }

    /// Closes the stack as `close(_:)` does, keeping `selection` on the photos it held: the closed
    /// stack is selected when any of its cells was.
    @discardableResult
    public mutating func close(_ id: Int64, selection: inout StackSelection) -> PhotoListDiff {
        guard isShown(id) else { return PhotoListDiff() }
        if let pair = stacks.pairIndex(of: id), places[pair] >= 0, opened.contains(pair), isVisible(pair: pair) {
            opened.remove(pair)
            let place = Int(places[pair])
            let first = list.ids[place]
            guard let slot = groupSlot(ofPair: pair), let open = openCells(at: slot),
                  let found = open.firstIndex(of: first)
            else {
                let cells = Array(openCells(at: place) ?? [first])
                removeOpenCells(at: place, count: cells.count)
                return shrink(
                    slot: place,
                    at: 0,
                    first: first,
                    removing: Array(cells.dropFirst()),
                    selection: &selection,
                )
            }
            var cells = ContiguousArray(open)
            let at = found - open.startIndex
            let others = at + 1 ..< at + Int(counts[pair])
            let removed = Array(cells[others])
            cells.removeSubrange(others)
            setOpenCells(cells, at: slot, replacing: open.count)
            return shrink(slot: slot, at: at, first: first, removing: removed, selection: &selection)
        }
        guard let group = stacks.groupIndex(of: id), places[group] >= 0, opened.contains(group) else {
            return PhotoListDiff()
        }
        opened.remove(group)
        let place = Int(places[group])
        let first = list.ids[place]
        let cells = Array(openCells(at: place) ?? [first])
        removeOpenCells(at: place, count: cells.count)
        return shrink(slot: place, at: 0, first: first, removing: Array(cells.dropFirst()), selection: &selection)
    }

    /// Opens every stack, the diff inserting their cells.
    @discardableResult
    public mutating func openAll(selection: inout StackSelection) -> PhotoListDiff {
        reopen(RowBits(rows: stacks.count, filled: true), selection: &selection)
    }

    /// Closes every stack, the diff removing their cells but the first.
    @discardableResult
    public mutating func closeAll(selection: inout StackSelection) -> PhotoListDiff {
        reopen(RowBits(rows: stacks.count), selection: &selection)
    }

    /// Opens the stacks `opened` holds and closes the others.
    private mutating func reopen(_ opened: RowBits, selection: inout StackSelection) -> PhotoListDiff {
        let old = self
        for place in sizes.indices where sizes[place] > 1 {
            sizes[place] = 1
        }
        self.opened = opened
        openAndCount()
        let diff = Self.diff(from: old, to: self)
        selection.carry(from: old, to: self)
        return diff
    }

    /// The slot at place `slot`, whose cells are now `cells`, showing `extra` more after its cell
    /// `offset`.
    private mutating func grow(
        slot: Int, at offset: Int, by extra: Int, cells: ContiguousArray<Int64>, selection: inout StackSelection,
    ) -> PhotoListDiff {
        let start = tree.prefix(slot) + offset
        sizes[slot] += Int32(extra)
        tree.add(Int32(extra), at: slot)
        count += extra
        let added = cells[offset + 1 ..< offset + 1 + extra]
        for cell in added {
            shown.insert(Int(cell))
        }
        if selection.contains(cells[offset]) {
            for cell in added {
                selection.insert(cell, words: shown.wordCount)
            }
        }
        compact()
        return PhotoListDiff(inserted: IndexSet(integersIn: start + 1 ..< start + 1 + extra), updated: [start])
    }

    /// The slot at place `slot` no longer showing `removed`, the cells after its cell `offset`, which
    /// is `first`.
    private mutating func shrink(
        slot: Int, at offset: Int, first: Int64, removing removed: [Int64], selection: inout StackSelection,
    ) -> PhotoListDiff {
        let start = tree.prefix(slot) + offset
        sizes[slot] -= Int32(removed.count)
        tree.add(-Int32(removed.count), at: slot)
        count -= removed.count
        for cell in removed {
            shown.remove(Int(cell))
        }
        if selection.contains(first) || removed.contains(where: selection.contains) {
            selection.insert(first, words: shown.wordCount)
            let active = selection.active
            for cell in removed {
                selection.remove(cell)
            }
            if let active, removed.contains(active) {
                selection.activate(first)
            }
        }
        compact()
        return PhotoListDiff(removed: IndexSet(integersIn: start + 1 ..< start + 1 + removed.count), updated: [start])
    }

    // MARK: - Changes

    /// This list after its list or its stacks changed: a new list of the view's source (as
    /// `LibraryLive` hands them over) or stacks found again, with the stacks open here open there,
    /// and the diff from this one; `changed` names photos whose rows changed. `selection` follows
    /// the photos it held. At a million photos this takes as long as making a list, so it's for
    /// off the main thread.
    public func updated(
        list newList: PhotoList? = nil, stacks newStacks: Stacks? = nil, changed: [Int64] = [],
        selection: inout StackSelection,
    ) -> (list: StackedList, diff: PhotoListDiff) {
        let new = remade(list: newList ?? list, stacks: newStacks ?? stacks)
        var named = changed
        for cell in new where (new.isStacked(cell) || isStacked(cell)) && isShown(cell) {
            if badges(of: cell) != new.badges(of: cell) {
                named.append(cell)
            }
        }
        let diff = PhotoListDiff(
            from: PhotoList(source: list.source, sort: list.sort, ids: ContiguousArray(self)),
            to: PhotoList(source: new.list.source, sort: new.list.sort, ids: ContiguousArray(new)), changed: named,
        )
        selection.carry(from: self, to: new)
        return (new, diff)
    }

    /// This list after `LibraryLive`'s `update` to its list, as `updated(list:changed:selection:)`
    /// makes it: a reset when the update is one.
    public func updated(_ update: PhotoListUpdate, selection: inout StackSelection)
        -> (list: StackedList, diff: PhotoListDiff) {
        guard !update.diff.reset else {
            let new = remade(list: update.list, stacks: stacks)
            selection.carry(from: self, to: new)
            return (new, PhotoListDiff(reset: true))
        }
        let changed = update.diff.updated.map { update.list[$0] } + update.diff.moved.map { update.list[$0.to] }
        return updated(list: update.list, changed: changed, selection: &selection)
    }

    /// `list` with `stacks`, the stacks open here open there: those holding an open one's top photo.
    func remade(list: PhotoList, stacks: Stacks) -> StackedList {
        var open = RowBits(rows: stacks.count)
        opened.forEach { stack in
            guard stack < self.stacks.count, let top = self.stacks.members(of: stack).first else { return true }
            let found = self.stacks.pairs.contains(stack) ? stacks.pairIndex(of: top) : stacks.groupIndex(of: top)
            if let found {
                open.insert(found)
            }
            return true
        }
        return StackedList(list, stacks: stacks, opened: open)
    }

    /// The diff from `old` to `new`, both of one list with its stacks, which keep their cells in one
    /// order however they're opened: the cells that went and came, and the stacks' first cells whose
    /// badges changed.
    static func diff(from old: StackedList, to new: StackedList) -> PhotoListDiff {
        let (shownBefore, shownAfter) = (old.shown.words, new.shown.words)
        func isShown(_ cell: Int64, in words: ContiguousArray<UInt64>) -> Bool {
            let word = Int(cell >> 6)
            return word < words.count && words[word] >> UInt64(cell & 63) & 1 != 0
        }
        var removed = CellRuns()
        old.forEachCell { index, cell in
            if !isShown(cell, in: shownAfter) {
                removed.add(index)
            }
        }
        var inserted = CellRuns()
        var updated = CellRuns()
        let (before, after) = (Lookup(old), Lookup(new))
        new.forEachCell { index, cell in
            if !isShown(cell, in: shownBefore) {
                inserted.add(index)
            } else if after.isStacked(cell), before.badgeState(of: cell) != after.badgeState(of: cell) {
                updated.add(index)
            }
        }
        return PhotoListDiff(removed: removed.set, inserted: inserted.set, updated: updated.set)
    }

    // MARK: - Stacks

    /// The place of the first photo `list` has of the frame whose top is `top`.
    private static func firstPlace(ofFrame top: Int64, in list: PhotoList, stacks: Stacks) -> Int? {
        guard let pair = stacks.pairIndex(of: top) else { return list.index(of: top) }
        for photo in stacks.members(of: pair) {
            if let place = list.index(of: photo) {
                return place
            }
        }
        return nil
    }

    /// The place of the stack holding `id`, a photo without a cell of its own there.
    private func slot(of id: Int64) -> Int? {
        if let group = stacks.groupIndex(of: id), places[group] >= 0 {
            return Int(places[group])
        }
        if let pair = stacks.pairIndex(of: id), places[pair] >= 0 {
            return Int(places[pair])
        }
        return nil
    }

    /// The place of the burst or manual stack shown as one that holds pair `pair`; nil when the
    /// pair is shown on its own.
    private func groupSlot(ofPair pair: Int) -> Int? {
        guard let group = stacks.groupIndex(of: stacks.members[stacks.memberRange(of: pair).lowerBound]),
              places[group] >= 0
        else { return nil }
        return Int(places[group])
    }

    /// Whether pair `pair`'s photos have cells of their own when it's open: it's on its own, or in an
    /// open burst or manual stack.
    private func isVisible(pair: Int) -> Bool {
        guard let group = stacks.groupIndex(of: stacks.members[stacks.memberRange(of: pair).lowerBound]),
              places[group] >= 0
        else { return true }
        return opened.contains(group)
    }

    // MARK: - Walking

    /// Calls `body` with each cell from `first` through `last`, in order.
    func walk(from first: Int, through last: Int, _ body: (Int64) -> Void) {
        guard first >= 0, first <= last, last < count else { return }
        var (place, offset) = tree.find(first)
        var remaining = last - first + 1
        while remaining > 0, place < sizes.count {
            let size = Int(sizes[place])
            if size > 1 {
                let start = Int(openStarts[place])
                let end = Swift.min(size, offset + remaining)
                for index in offset ..< end {
                    body(openStore[start + index])
                }
                remaining -= end - offset
            } else if size == 1 {
                body(list.ids[place])
                remaining -= 1
            }
            offset = 0
            place += 1
        }
    }

    /// The first cell from `start` on that `matches`.
    func firstCell(from start: Int, where matches: (Int64) -> Bool) -> Int64? {
        guard start >= 0, start < count else { return nil }
        var (place, offset) = tree.find(start)
        while place < sizes.count {
            let size = Int(sizes[place])
            if size > 1, let cells = openCells(at: place) {
                if let found = cells.dropFirst(offset).first(where: matches) {
                    return found
                }
            } else if size == 1, matches(list.ids[place]) {
                return list.ids[place]
            }
            offset = 0
            place += 1
        }
        return nil
    }

    /// The first cell from `start` up to `end` that `matches`.
    func firstCell(from start: Int, before end: Int, where matches: (Int64) -> Bool) -> Int64? {
        let end = Swift.min(end, count)
        guard start >= 0, start < end else { return nil }
        var (place, offset) = tree.find(start)
        var index = start
        while place < sizes.count, index < end {
            let size = Int(sizes[place])
            if size > 1, let cells = openCells(at: place) {
                for cell in cells.dropFirst(offset).prefix(end - index) {
                    if matches(cell) {
                        return cell
                    }
                }
                index += size - offset
            } else if size == 1 {
                if matches(list.ids[place]) {
                    return list.ids[place]
                }
                index += 1
            }
            offset = 0
            place += 1
        }
        return nil
    }

    /// The last cell before `end` and from `start` on that `matches`.
    func lastCell(before end: Int, from start: Int, where matches: (Int64) -> Bool) -> Int64? {
        let end = Swift.min(end, count)
        guard start >= 0, start < end else { return nil }
        var (place, offset) = tree.find(end - 1)
        var index = end - 1
        while place >= 0, index >= start {
            let size = Int(sizes[place])
            if size > 1, let cells = openCells(at: place) {
                for cell in cells.prefix(offset + 1).reversed().prefix(index - start + 1) {
                    if matches(cell) {
                        return cell
                    }
                }
                index -= offset + 1
            } else if size == 1 {
                if matches(list.ids[place]) {
                    return list.ids[place]
                }
                index -= 1
            }
            place -= 1
            offset = place >= 0 ? Int(sizes[place]) - 1 : 0
        }
        return nil
    }

    /// Cells at the places before `place`.
    func cellCount(before place: Int) -> Int {
        tree.prefix(place)
    }

    /// The last cell before `end` that `matches`.
    func lastCell(before end: Int, where matches: (Int64) -> Bool) -> Int64? {
        guard end > 0, count > 0 else { return nil }
        var (place, offset) = tree.find(Swift.min(end, count) - 1)
        while place >= 0 {
            let size = Int(sizes[place])
            if size > 1, let cells = openCells(at: place) {
                if let found = cells.prefix(offset + 1).last(where: matches) {
                    return found
                }
            } else if size == 1, matches(list.ids[place]) {
                return list.ids[place]
            }
            place -= 1
            offset = place >= 0 ? Int(sizes[place]) - 1 : 0
        }
        return nil
    }
}

extension StackedList {
    /// The arrays cells are made from, held apart from the list so loops over a million photos read
    /// them without calls into other files.
    private struct Lookup {
        let members: ContiguousArray<Int64>
        let bounds: ContiguousArray<Int32>
        let pairOf: ContiguousArray<Int32>
        let groupOf: ContiguousArray<Int32>
        let places: ContiguousArray<Int32>
        /// The list's photos and the open stacks, a bit each.
        let inList: ContiguousArray<UInt64>
        let opened: ContiguousArray<UInt64>
        let listPlaces: (Int64) -> Int?

        init(_ stacked: StackedList) {
            members = stacked.stacks.members
            bounds = stacked.stacks.starts
            pairOf = stacked.stacks.pairOf
            groupOf = stacked.stacks.groupOf
            places = stacked.places
            inList = stacked.list.members.words
            opened = stacked.opened.words
            let list = stacked.list
            listPlaces = { list.index(of: $0) }
        }

        func contains(_ id: Int64) -> Bool {
            let word = Int(id >> 6)
            return id >= 0 && word < inList.count && inList[word] >> UInt64(id & 63) & 1 != 0
        }

        func isOpen(_ stack: Int) -> Bool {
            opened[stack >> 6] >> UInt64(stack & 63) & 1 != 0
        }

        func pair(of id: Int64) -> Int {
            id >= 0 && id < pairOf.count ? Int(pairOf[Int(id)]) : -1
        }

        func group(of id: Int64) -> Int {
            id >= 0 && id < groupOf.count ? Int(groupOf[Int(id)]) : -1
        }

        func isStacked(_ id: Int64) -> Bool {
            pair(of: id) >= 0 || group(of: id) >= 0
        }

        /// The place of the burst or manual stack shown as one that holds pair `pair`; nil when the
        /// pair is shown on its own.
        func groupSlot(ofPair pair: Int) -> Int? {
            let group = group(of: members[Int(bounds[pair])])
            return group >= 0 && places[group] >= 0 ? Int(places[group]) : nil
        }

        /// An open burst's or manual stack's cells: each frame's first photo in the list, or every
        /// one of an open pair.
        func appendCells(ofGroup group: Int, to cells: inout ContiguousArray<Int64>) {
            for index in Int(bounds[group]) ..< Int(bounds[group + 1]) {
                let top = members[index]
                let pair = pair(of: top)
                guard pair >= 0 else {
                    if contains(top) {
                        cells.append(top)
                    }
                    continue
                }
                let open = places[pair] >= 0 && isOpen(pair)
                for photo in members[Int(bounds[pair]) ..< Int(bounds[pair + 1])] where contains(photo) {
                    cells.append(photo)
                    if !open {
                        break
                    }
                }
            }
        }

        /// An open pair's cells: its photos in the list.
        func appendCells(ofPair pair: Int, to cells: inout ContiguousArray<Int64>) {
            for photo in members[Int(bounds[pair]) ..< Int(bounds[pair + 1])] where contains(photo) {
                cells.append(photo)
            }
        }

        /// What of `badges(of:)` changes as stacks open and close, for photo `id`: whether it's the
        /// first of an open burst or manual stack, and of a pair shown as one, and whether that pair
        /// is open.
        func badgeState(of id: Int64) -> UInt8 {
            let (group, pair) = (group(of: id), pair(of: id))
            guard group >= 0 && places[group] >= 0 || pair >= 0 && places[pair] >= 0,
                  let place = listPlaces(id).map(Int32.init)
            else { return 0 }
            var state: UInt8 = 0
            if group >= 0, places[group] == place {
                state |= isOpen(group) ? 1 : 0
            }
            if pair >= 0, places[pair] == place, groupSlot(ofPair: pair).map({ _ in isOpen(group) }) ?? true {
                state |= isOpen(pair) ? 6 : 2
            }
            return state
        }
    }
}

/// Cells counted at each place, to find a cell's place and a place's first cell in log time: a
/// Fenwick tree.
struct CellTree: Sendable {
    /// From 1: each holds the sum of the `index & -index` places up to its own.
    private var sums: ContiguousArray<Int32>
    /// The highest power of two at most the places.
    private let step: Int

    init(_ sizes: ContiguousArray<Int32>) {
        var sums = ContiguousArray<Int32>(repeating: 0, count: sizes.count + 1)
        sums.withUnsafeMutableBufferPointer { sums in
            sizes.withUnsafeBufferPointer { sizes in
                for index in 1 ..< sums.count {
                    sums[index] &+= sizes[index - 1]
                    let parent = index + (index & -index)
                    if parent < sums.count {
                        sums[parent] &+= sums[index]
                    }
                }
            }
        }
        self.sums = sums
        step = sizes.isEmpty ? 0 : 1 << (Int.bitWidth - 1 - sizes.count.leadingZeroBitCount)
    }

    var total: Int {
        prefix(sums.count - 1)
    }

    /// Cells before `place`.
    func prefix(_ place: Int) -> Int {
        var index = place
        var sum = 0
        while index > 0 {
            sum += Int(sums[index])
            index &= index - 1
        }
        return sum
    }

    mutating func add(_ delta: Int32, at place: Int) {
        var index = place + 1
        while index < sums.count {
            sums[index] += delta
            index += index & -index
        }
    }

    /// The place whose cells hold cell `cell`, and which of them it is.
    func find(_ cell: Int) -> (place: Int, offset: Int) {
        var place = 0
        var remaining = cell
        var step = step
        while step > 0 {
            let next = place + step
            if next < sums.count, Int(sums[next]) <= remaining {
                place = next
                remaining -= Int(sums[next])
            }
            step >>= 1
        }
        return (place, remaining)
    }
}

/// Indexes gathered in ascending order as ranges, made into an `IndexSet` once.
struct CellRuns {
    private var ranges: [Range<Int>] = []

    mutating func add(_ index: Int) {
        if let last = ranges.last, last.upperBound == index {
            ranges[ranges.count - 1] = last.lowerBound ..< index + 1
        } else {
            ranges.append(index ..< index + 1)
        }
    }

    var set: IndexSet {
        var set = IndexSet()
        for range in ranges {
            set.insert(integersIn: range)
        }
        return set
    }
}
