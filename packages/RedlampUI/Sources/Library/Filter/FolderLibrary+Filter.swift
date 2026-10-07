import Foundation
import RedlampLibrary

/// The open folder filtered and sorted (LIB-18): the library's list of the photos the filter finds, in
/// the sort's order, takes the place of the folder's photos. Each photo that stays keeps its ID, so
/// the selection keeps the photos that remain, and a change that keeps the photos' order reaches the
/// filmstrip and the grid row by row.
public extension FolderLibrary {
    /// Whether the photos shown are filtered or sorted, rather than the folder's as Folders lists them.
    var isFiltered: Bool {
        fromLibrary.list.map { !$0.filter.isEmpty } ?? false
    }

    /// The filter bar of the library the folders are shown from.
    var filters: LibraryFilters? {
        service?.filters
    }
}

extension FolderLibrary {
    /// The library's filtered or sorted list of the open folder, in place of the photos shown.
    func show(_ ordered: LibraryFolderList.Ordered) {
        let opened = fromLibrary.opened
        fromLibrary.opened = nil
        fromLibrary.awaitingFirst = false
        fromLibrary.keys.merge(ordered.keys) { _, new in new }
        let carried = ordered.previousCount >= 0 && ordered.previousCount == items.count
        var ids = ContiguousArray<Int64>()
        ids.reserveCapacity(ordered.items.count)
        for (index, item) in ordered.items.enumerated() {
            let before = carried ? Int(ordered.previous[index]) : positions[item.url] ?? -1
            ids.append(photoIDs.indices.contains(before) ? photoIDs[before] : newPhotoIDs(1).lowerBound)
        }
        let unchanged = carried && ordered.diff.isEmpty
        // Freeing tens of thousands of photos takes milliseconds: the list replaced goes off the main thread.
        let replaced = (items, positions)
        items = ordered.items
        positions = ordered.positions
        photoIDs = ids
        scheduler.submit(.background) { withExtendedLifetime(replaced) {} }
        isListing = false
        isOpenFolderUnavailable = false
        if opened != nil {
            listedDirectories = Set(items.map(\.folderPath)).union(openFolder.map { [$0.path] } ?? [])
        }
        if !unchanged {
            photosMoved()
            publish(carried ? ordered.diff : LibraryDiff(reset: true))
        }
        if let opened {
            opened(items)
            refreshStacks()
        }
        filters?.listed(ordered)
    }
}
