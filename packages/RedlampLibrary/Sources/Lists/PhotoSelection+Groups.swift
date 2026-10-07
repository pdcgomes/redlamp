import Foundation

/// The cells selected in a grouped list (LIB-41), as in a stacked list (`StackSelection`): a closed
/// stack's cell selects all of the stack. A closed group's cells are never selected, so nothing out of
/// sight is acted on: closing a group takes them out (`GroupedList.close(_:selection:)`), and
/// extending a selection, selecting all and inverting reach only the groups on show.
public extension StackSelection {
    /// Selects cell `id` alone and makes it active, when it's on show: a click.
    mutating func select(_ id: Int64, in list: GroupedList) {
        guard list.isVisible(id) else { return }
        select(id, in: list.stacked)
    }

    /// Adds cell `id` to the selection, making it active, or takes it out, when it's on show: a
    /// ⌘-click.
    mutating func toggle(_ id: Int64, in list: GroupedList) {
        guard list.isVisible(id) else { return }
        toggle(id, in: list.stacked)
    }

    /// Adds every cell on show from the active one to `id`, in `list`'s order, the active cell staying
    /// as it is: a ⇧-click. With no active cell, it selects `id` alone.
    mutating func extend(to id: Int64, in list: GroupedList) {
        guard let target = list.index(of: id) else { return }
        guard let active, let anchor = list.index(of: active) else { return select(id, in: list) }
        let words = list.stacked.shown.wordCount
        list.walk(from: min(anchor, target), through: max(anchor, target)) { insert($0, words: words) }
    }

    /// Selects every cell on show, keeping the active one when it's among them, or making the first
    /// active.
    mutating func selectAll(in list: GroupedList) {
        let active = active
        selectNone()
        let words = list.stacked.shown.wordCount
        list.forEachItem { _, item in
            if case let .photo(cell) = item {
                insert(cell, words: words)
            }
        }
        if let first = active.flatMap({ contains($0) ? $0 : nil }) ?? list
            .firstCell(fromItem: 0, where: { _ in true }) {
            activate(first)
        }
    }

    /// Selects the cells on show that aren't selected, and only those. The active cell stays if it's
    /// still selected; otherwise the first selected is active.
    mutating func invert(in list: GroupedList) {
        let words = list.stacked.shown.wordCount
        list.forEachItem { _, item in
            guard case let .photo(cell) = item else { return }
            if contains(cell) {
                remove(cell)
            } else {
                insert(cell, words: words)
            }
        }
        if let active, contains(active) {
            return
        }
        let selected = self
        guard let first = list.firstCell(fromItem: 0, where: selected.contains) else { return selectNone() }
        activate(first)
    }

    /// The photos selected, in `list`'s order: each selected cell's, every photo of a closed stack.
    func photos(in list: GroupedList) -> ContiguousArray<Int64> {
        photos(in: list.stacked)
    }
}
