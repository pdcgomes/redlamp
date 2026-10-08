import Foundation

/// The views of the Library panel's entries and the collections (LIB-23, LIB-41), kept as a folder's are: each
/// one's thumbnail size, cell style, Group By and Tighter–Looser setting, place and selection, under its key
/// (`LibrarySource.key`), as it's left and shown again with it.
extension EditorModel {
    /// Keeps `source`'s view as it's left, while its photos are still the ones shown.
    func rememberView(of source: LibrarySource) {
        guard !items.isEmpty else { return }
        libraryViews.remember(source.key, selection: isMultiSelecting ? selectedPhotos : [], active: selection)
    }

    /// `source`'s first photos are in, `found` the first of them: its view as it was left, with the photo it had
    /// active, if it's still among them, and the photos selected with it; else the first photo.
    func didList(_ source: LibrarySource, _ found: [LibraryItem]) {
        let view = libraryViews.restore(source.key)
        didList(found, select: view?.active.map { URL(fileURLWithPath: $0) })
        guard let view, let active = selection, view.active == active.path, view.selected.count > 1,
              let activeID = library.photoID(of: active)
        else { return }
        let ids = view.selected.compactMap { library.photoID(of: URL(fileURLWithPath: $0)) }
        photoSelection.select(ids + [activeID], active: activeID, in: library.photoList)
    }
}
