import Foundation
import RedlampLibrary

/// The order the Library grid shows the source's photos in, one cell each (LIB-41, LIB-28): grouped, the open
/// groups' cells one group after another, a closed group's photos having none; among stacks, a closed stack's photos
/// behind its first; else the list's photos. The filmstrip shows these cells in either module, and ← and →,
/// culling's advance and Develop's reading ahead go from one to the next.
enum GridOrder {
    case grouped(GroupedList)
    case stacked(StackedList)
    case listed(PhotoList)

    /// The cells in order: a pass over them.
    var cells: ContiguousArray<Int64> {
        switch self {
        case let .grouped(list): list.cells
        case let .stacked(list): ContiguousArray(list)
        case let .listed(list): list.ids
        }
    }

    /// The stacks the cells show, grouped or not.
    var stacks: StackedList? {
        switch self {
        case let .grouped(list): list.stacked
        case let .stacked(list): list
        case .listed: nil
        }
    }

    /// The place of photo `id`'s own cell among `cells`; nil for a photo inside a closed stack or in a closed group.
    func index(of id: Int64) -> Int? {
        switch self {
        case let .grouped(list): list.cellIndex(of: id)
        case let .stacked(list): list.index(of: id)
        case let .listed(list): list.index(of: id)
        }
    }

    /// The photo whose cell stands for `id`: itself, or the first of the closed stack it's in.
    func cell(for id: Int64) -> Int64? {
        guard let stacks else { return id }
        return stacks.cell(for: id)
    }

    /// Where the cell standing for photo `id` is in the order, every group counted as open, to tell which of two
    /// photos comes first; nil for a photo the list doesn't have.
    func place(of id: Int64) -> Int? {
        guard let stacks else { return index(of: id) }
        return stacks.cell(for: id).flatMap(stacks.index(of:))
    }

    /// The cell `offset` (1 or -1) after or before the one standing for photo `id`; grouped, past headers and
    /// closed groups. Nil at either end.
    func cell(_ offset: Int, from id: Int64) -> Int64? {
        switch self {
        case let .grouped(list):
            return list.cell(offset, from: id)
        case let .stacked(list):
            guard let index = list.cell(for: id).flatMap(list.index(of:)), list.indices.contains(index + offset)
            else { return nil }
            return list[index + offset]
        case let .listed(list):
            guard let index = list.index(of: id), list.indices.contains(index + offset) else { return nil }
            return list[index + offset]
        }
    }

    /// The cell after the last of `photos`, as culling moves on past the photos it changed; nil when none is after
    /// them.
    func cell(after photos: [Int64]) -> Int64? {
        switch self {
        case let .grouped(list):
            return list.cell(after: photos)
        case let .stacked(list):
            var last = -1
            for photo in photos {
                last = max(last, list.cell(for: photo).flatMap(list.index(of:)) ?? -1)
            }
            return last >= 0 && list.indices.contains(last + 1) ? list[last + 1] : nil
        case let .listed(list):
            var last = -1
            for photo in photos {
                last = max(last, list.index(of: photo) ?? -1)
            }
            return last >= 0 && list.indices.contains(last + 1) ? list[last + 1] : nil
        }
    }
}

extension EditorModel {
    /// The grid's order as the model has it now: its groups, else the source's stacks, else its photos.
    var gridOrder: GridOrder {
        let list = library.photoList
        if let grouped = libraryViews.groups?.list {
            return .grouped(grouped)
        }
        if let stacked = libraryViews.stacks?.list, stacked.list.source == list.source {
            return .stacked(stacked)
        }
        return .listed(list)
    }
}
