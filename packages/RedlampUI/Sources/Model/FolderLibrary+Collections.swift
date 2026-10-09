import Foundation
import RedlampDocument
import RedlampLibrary

/// The Library panel's entries and the collections as sources (LIB-23, `LibrarySources`): a source's photos
/// take the place of the open folder's, as Recently Trashed's do, each photo at its own folder with its badges
/// and the store's thumbnails, and its list's changes reach the filmstrip and the grid row by row. Each photo's
/// ID is the index's, so the selection keeps the photos that remain, whatever the filter; a photo is found from
/// its URL by its folder and name (`PhotoPaths`), and its content key by its ID. Its photos are the library's, as
/// a folder's shown from its photo list are, so the panels, Group By and the filter bar work on them, and the
/// source keeps its own filter and view.
extension FolderLibrary {
    /// Closes the open folder for `source`'s photos, `photos` as the library lists them, filtered and sorted as
    /// the filter bar has `source`: each change of their list goes to `deliver` with the opening's generation, for
    /// `showSource`. The folder that was open is the one the next launch opens. Returns the generation, which a
    /// later opening ends, and the list, which its owner closes; no list without the library.
    func openSource(
        _ source: LibrarySource, photos: PhotoSource,
        deliver: @escaping @MainActor @Sendable (LibrarySourceList.Change, Int) -> Void,
    ) -> (generation: Int, list: LibrarySourceList?) {
        let before = openFolder ?? trash.folderBefore
        // Freeing tens of thousands of photos takes milliseconds: those shown go off the main thread.
        let shown = (items, positions, photoIDs)
        scheduler.submit(.background) { withExtendedLifetime(shown) {} }
        open(nil)
        trash.folderBefore = before
        saveSettings()
        isListing = true
        shownSource = source
        fromLibrary.sourcePhotos = photos
        photosMoved()
        let generation = generation
        guard let core = service?.core else { return (generation, nil) }
        filters?.follow(source, photos: photos)
        let list = LibrarySourceList(
            core: core, source: photos, filter: filters?.request(for: source.key) ?? LibraryListFilter(),
        ) { change in deliver(change, generation) }
        fromLibrary.sourceList = list
        filters?.sourceList = list
        return (generation, list)
    }

    /// The photos of the entry or the collection shown, as the query engine knows them.
    var shownSourcePhotos: PhotoSource? {
        fromLibrary.sourcePhotos
    }

    /// The index's ID of the photo at `url`, while it's one of the photos of the entry or the collection shown,
    /// filtered or not.
    func sourcePhotoID(of url: URL) -> Int64? {
        fromLibrary.sourcePaths?.id(of: url)
    }

    /// Whether the photos' IDs (`photoIDs`) are the index's: those of the entry or the collection shown.
    var showsIndexIDs: Bool {
        fromLibrary.sourcePaths != nil
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
        let unchanged = carried && change.diff.isEmpty
        // Freeing tens of thousands of photos takes milliseconds: the photos replaced go off the main thread.
        let replaced = (items, positions, photoIDs, fromLibrary.tables)
        fromLibrary.sourceKeys = change.keys
        fromLibrary.sourcePaths = change.paths
        items = change.items
        positions = [:]
        photoIDs = change.list.ids
        scheduler.submit(.background) { withExtendedLifetime(replaced) {} }
        if let highest = change.list.highestID {
            noteIndexID(highest)
        }
        isListing = false
        isOpenFolderUnavailable = false
        if !unchanged {
            photosMoved(to: change.list)
            publish(carried ? change.diff : LibraryDiff(reset: true))
        }
        if let filter = change.filter {
            filters?.listed(LibraryListing(
                shown: change.items.count, total: change.total, filter: filter, took: change.took,
            ))
        }
        return true
    }
}

extension LibrarySource {
    /// What its filter and its view are kept under, as a folder's are under its path (`LibraryFilters.key`).
    var key: String {
        switch self {
        case .allPhotographs: "library:all-photographs"
        case .previousImport: "library:previous-import"
        case .marked: "library:marked"
        case .rejected: "library:rejected"
        case let .health(kind): "library:health:" + kind.rawValue
        case .unreadable: "library:unreadable"
        case .keptAnyway: "library:kept-anyway"
        case let .collection(path): "collection:" + path.text
        }
    }
}
