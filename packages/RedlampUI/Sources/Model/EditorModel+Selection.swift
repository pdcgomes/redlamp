import Foundation
import RedlampLibrary

/// Several photos selected in the filmstrip or the grid, as in Lightroom: the active photo is the one
/// open (`selection`), always among them, and the one a click makes active. Sync and Paste then reach
/// the rest (`docs/plans/2026-10-02-copy-paste-sync-design.md`). The selection is a `PhotoSelection`
/// over the photos' IDs (`library.photoList`), so selecting all of a large folder costs a pass over its
/// bits, never one over its photos.
public extension EditorModel {
    /// The photos selected, in the filmstrip's order: a pass over the photos' IDs, so views follow
    /// `photoSelection` itself. The selection is read once: each read is an observed access, which a view's body
    /// would make a photo at a time; and only the photos selected are read, each a copy of many references. Of a
    /// large source's photos, only those whose rows are read: what acts on them all takes them through
    /// `selectionForAction`, or takes their IDs.
    var selectedPhotos: [URL] {
        let selected = photoSelection
        guard !selected.isEmpty else { return selection.map { [$0] } ?? [] }
        return library.items.urls(at: selectedPlaces(selected))
    }

    /// The IDs of the photos selected, in the filmstrip's order; the active photo's alone when nothing else is. Every
    /// photo of the list selected is its IDs as they are, without a pass over them (`PhotoSelection.ids(in:)`).
    var selectedIDs: [Int64] {
        let selected = photoSelection
        guard !selected.isEmpty else { return selection.flatMap(library.photoID(of:)).map { [$0] } ?? [] }
        return Array(selected.ids(in: library.photoList))
    }

    /// The photos selected, for an action on them all to work through (`SelectedPhotos`): their URLs, or a large
    /// source's IDs, the rows not read left unread. `excluding` leaves out the photo at that URL, the open one for
    /// Sync and Paste.
    internal func selectionForAction(excluding: URL? = nil) -> SelectedPhotos {
        guard library.items.readsOnRequest, let source = library.rowSource else {
            let photos = selectedPhotos
            return SelectedPhotos(excluding.map { url in photos.filter { $0 != url } } ?? photos)
        }
        // Every photo of a list selected is its IDs as they are, without a pass over them.
        let selected = photoSelection.isEmpty ? ContiguousArray(selectedIDs) : photoSelection.ids(in: library.photoList)
        let left = excluding.flatMap(library.photoID(of:))
        let ids = left.map { left in ContiguousArray(selected.lazy.filter { $0 != left }) } ?? selected
        return SelectedPhotos(ids: ids, read: library.items.rowsRead.mapValues(\.url), source: source)
    }

    /// Whether every photo selected has its row read: always, unless they're a large source's.
    var hasReadSelection: Bool {
        !library.items.readsOnRequest || library.hasRead(selectedIDs)
    }

    /// How many photos are selected: the active photo alone when nothing else is.
    var selectedCount: Int {
        photoSelection.isEmpty ? (selection == nil ? 0 : 1) : photoSelection.count
    }

    /// The index's IDs of the photos selected, in order: their own while the photos' IDs are the index's, else found
    /// from their URLs; photos the index doesn't have are left out.
    func selectedIndexIDs() async -> [Int64] {
        if library.showsIndexIDs {
            return selectedIDs
        }
        let urls = selectedPhotos
        guard let index = library.service?.core?.index else { return [] }
        let found = await LibraryService.indexIDs(of: urls, in: index)
        return urls.compactMap { found[$0] }
    }

    /// The places of the photos of `selected` among those shown, in order.
    private func selectedPlaces(_ selected: PhotoSelection) -> [Int] {
        let ids = library.photoIDs
        var places: [Int] = []
        places.reserveCapacity(selected.count)
        for index in ids.indices where selected.contains(ids[index]) {
            places.append(index)
        }
        return places
    }

    var isMultiSelecting: Bool {
        photoSelection.count > 1
    }

    /// A click on a photo in the filmstrip or the grid, or an arrow key in the grid: on its own it
    /// selects only that photo; `toggling` (⌘) adds it or takes it away; `extending` (⇧) selects the
    /// range from the photo last clicked or moved to without ⇧. The clicked photo becomes the active
    /// one, unless it was just taken away.
    func click(_ url: URL, toggling: Bool = false, extending: Bool = false) {
        guard let id = library.photoID(of: url), toggling || extending else { return select(url) }
        let list = library.photoList
        if extending, let anchor = extensionAnchor.flatMap(library.photoID(of:)) {
            photoSelection.select(from: anchor, through: id, in: list)
            select(url, keepingSelection: true)
        } else if photoSelection.contains(id), toggling {
            guard photoSelection.count > 1 else { return }
            photoSelection.toggle(id, in: list)
            if url == selection, let next = photoSelection.active.flatMap(library.url(ofPhoto:)) {
                select(next, keepingSelection: true)
                selectionAnchor = next
            }
        } else if toggling {
            photoSelection.toggle(id, in: list)
            select(url, keepingSelection: true)
            selectionAnchor = url
        } else {
            select(url)
        }
    }

    private var extensionAnchor: URL? {
        [selectionAnchor, selection].compactMap(\.self).first { library.index(of: $0) != nil }
    }

    /// ⌘A: every photo in the filmstrip, the active one staying active.
    func selectAllPhotos() {
        guard selection != nil else { return }
        photoSelection.selectAll(in: library.photoList)
    }

    /// ⌘D: only the active photo.
    func deselectOtherPhotos() {
        selectOnly(selection)
        selectionAnchor = selection
    }

    /// Selects `url` alone, if it's shown.
    internal func selectOnly(_ url: URL?) {
        var only = PhotoSelection()
        if let id = url.flatMap(library.photoID(of:)) {
            only.select(id, in: library.photoList)
        }
        photoSelection = only
    }

    /// After photos came or went: those gone leave the selection, and the active photo is selected
    /// again when nothing else is, as when a folder is listed afresh.
    internal func keepSelectionShown() {
        photoSelection.keep(in: library.photoList)
        if photoSelection.isEmpty, let selection, library.photoID(of: selection) != nil {
            selectOnly(selection)
        }
    }
}
