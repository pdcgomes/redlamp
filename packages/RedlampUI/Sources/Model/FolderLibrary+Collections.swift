import Foundation
import RedlampDocument
import RedlampLibrary

/// The Library panel's entries and the collections as sources (LIB-23, `LibrarySources`): a source's photos
/// take the place of the open folder's, as Recently Trashed's do, each photo at its own folder with its badges
/// and the store's thumbnails, and its list's changes reach the filmstrip and the grid row by row. Each photo
/// that stays keeps its ID, so the selection keeps the photos that remain.
extension FolderLibrary {
    /// Closes the open folder for a source's photos, which come with `showSource`: the folder that was open is
    /// the one the next launch opens. Returns the opening's generation, which a later opening ends.
    func openSource() -> Int {
        let before = openFolder ?? trash.folderBefore
        // Freeing tens of thousands of photos takes milliseconds: those shown go off the main thread.
        let shown = (items, positions, fromLibrary.keys)
        scheduler.submit(.background) { withExtendedLifetime(shown) {} }
        open(nil)
        trash.folderBefore = before
        saveSettings()
        isListing = true
        return generation
    }

    /// Whether the opening `generation` names is still the one shown.
    func showsSource(_ generation: Int) -> Bool {
        generation == self.generation && openFolder == nil && !showsRecentlyTrashed
    }

    /// `change`'s photos in place of those shown, for the opening `generation` names; false when another
    /// opening has replaced it.
    @discardableResult
    func showSource(_ change: LibrarySourceList.Change, generation: Int) -> Bool {
        guard showsSource(generation) else { return false }
        let carried = change.previousCount >= 0 && change.previousCount == items.count
        var ids = ContiguousArray<Int64>()
        if !carried, positions.isEmpty {
            // Hashing tens of thousands of URLs to find none takes milliseconds.
            ids = ContiguousArray(newPhotoIDs(change.items.count))
        } else {
            ids.reserveCapacity(change.items.count)
            for (index, item) in change.items.enumerated() {
                let before = carried ? Int(change.previous[index]) : positions[item.url] ?? -1
                ids.append(photoIDs.indices.contains(before) ? photoIDs[before] : newPhotoIDs(1).lowerBound)
            }
        }
        let unchanged = carried && change.diff.isEmpty
        // Freeing tens of thousands of photos takes milliseconds: the photos replaced go off the main thread.
        let replaced = (items, positions, fromLibrary.keys)
        fromLibrary.keys = change.keys
        items = change.items
        positions = change.positions
        photoIDs = ids
        scheduler.submit(.background) { withExtendedLifetime(replaced) {} }
        isListing = false
        isOpenFolderUnavailable = false
        if !unchanged {
            photosMoved()
            publish(carried ? change.diff : LibraryDiff(reset: true))
        }
        return true
    }
}
