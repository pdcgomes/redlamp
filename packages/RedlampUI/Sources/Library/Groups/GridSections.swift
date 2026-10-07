import Foundation
import RedlampLibrary

/// A grouped grid's sections (LIB-41): each group's header on a row of its own across the grid, then,
/// while the group is open, its cells in rows of their own, as `GroupedList` orders its items.
struct GridSections: Equatable {
    /// Each group's cells on show: none while it's closed.
    private(set) var cells: [Int]
    /// The item of each group's header, then the count of items.
    private(set) var firsts: [Int]

    init(_ list: GroupedList) {
        var cells: [Int] = []
        var firsts: [Int] = []
        cells.reserveCapacity(list.groups.count)
        firsts.reserveCapacity(list.groups.count + 1)
        var item = 0
        for group in list.groups.indices {
            firsts.append(item)
            let shown = list.isOpen(group) ? list.cellCount(of: group) : 0
            cells.append(shown)
            item += 1 + shown
        }
        firsts.append(item)
        self.cells = cells
        self.firsts = firsts
    }

    var groups: Int {
        cells.count
    }

    /// The group whose header or cell item `index` is.
    func group(ofItem index: Int) -> Int {
        var (low, high) = (0, cells.count)
        while high - low > 1 {
            let middle = (low + high) / 2
            (low, high) = firsts[middle] <= index ? (middle, high) : (low, middle)
        }
        return low
    }

    /// Whether item `index` is a header.
    func isHeader(_ index: Int) -> Bool {
        guard !cells.isEmpty, index >= 0, index < firsts[cells.count] else { return false }
        return firsts[group(ofItem: index)] == index
    }
}

extension LibraryGridLayout {
    /// A header's height, across the grid.
    static let headerHeight: CGFloat = 28

    /// Each group's cell rows before it, then all of them, for the sections at this layout's columns.
    static func rowsBefore(_ sections: GridSections, columns: Int) -> [Int] {
        var rows: [Int] = []
        rows.reserveCapacity(sections.groups + 1)
        var total = 0
        for group in 0 ..< sections.groups {
            rows.append(total)
            total += (sections.cells[group] + columns - 1) / columns
        }
        rows.append(total)
        return rows
    }

    var pitch: CGFloat {
        cellSize.height + spacing
    }

    /// Where group `group`'s header starts.
    func top(ofGroup group: Int) -> CGFloat {
        Self.insets.top + CGFloat(group) * (Self.headerHeight + spacing) + CGFloat(rowsBefore[group]) * pitch
    }

    /// Where group `group`'s first row of cells starts.
    func cellsTop(ofGroup group: Int) -> CGFloat {
        top(ofGroup: group) + Self.headerHeight + spacing
    }

    func groupedFrame(forItem index: Int, in sections: GridSections) -> CGRect {
        let group = sections.group(ofItem: index)
        let offset = index - sections.firsts[group]
        guard offset > 0 else {
            return CGRect(
                x: Self.insets.left, y: top(ofGroup: group), width: max(
                    width - Self.insets.left - Self.insets.right,
                    1,
                ),
                height: Self.headerHeight,
            )
        }
        let (cell, size) = (offset - 1, cellSize)
        return CGRect(
            x: left + CGFloat(cell % columns) * (size.width + spacing),
            y: cellsTop(ofGroup: group) + CGFloat(cell / columns) * pitch, width: size.width, height: size.height,
        )
    }

    /// The items whose frames meet the rows from `rect.minY` to `rect.maxY`: from the first whose bottom is
    /// at or below its top to the last whose top is at or above its bottom.
    func groupedItems(in rect: CGRect, of sections: GridSections) -> Range<Int> {
        let groups = sections.groups
        guard groups > 0 else { return 0 ..< 0 }
        // The first group ending at or below the rect's top.
        var (low, high) = (0, groups)
        while low < high {
            let middle = (low + high) / 2
            (low, high) = top(ofGroup: middle + 1) - spacing < rect.minY ? (middle + 1, high) : (low, middle)
        }
        guard low < groups else { return 0 ..< 0 }
        let start = low
        var first = sections.firsts[start]
        if top(ofGroup: start) + Self.headerHeight < rect.minY, sections.cells[start] > 0 {
            let row = max(Int(((rect.minY - cellsTop(ofGroup: start) - cellSize.height) / pitch).rounded(.up)), 0)
            first = min(sections.firsts[start] + 1 + row * columns, sections.firsts[start] + sections.cells[start])
        }
        // The last group starting at or above the rect's bottom.
        (low, high) = (0, groups)
        while low < high {
            let middle = (low + high) / 2
            (low, high) = top(ofGroup: middle) <= rect.maxY ? (middle + 1, high) : (low, middle)
        }
        guard low > 0 else { return 0 ..< 0 }
        let end = low - 1
        var last = sections.firsts[end]
        if sections.cells[end] > 0, rect.maxY >= cellsTop(ofGroup: end) {
            let rows = (sections.cells[end] + columns - 1) / columns
            let row = min(Int(((rect.maxY - cellsTop(ofGroup: end)) / pitch).rounded(.down)), rows - 1)
            last = sections.firsts[end] + min((row + 1) * columns, sections.cells[end])
        }
        return first <= last ? first ..< last + 1 : 0 ..< 0
    }
}
