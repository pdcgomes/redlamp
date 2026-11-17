import Foundation
import RedlampDocument
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

    /// The photos selected, in the filmstrip's order, by address: a version as itself (LIB-48); the active photo's
    /// alone when nothing else is. Of a large source's photos, only those whose rows are read, as `selectedPhotos`.
    var selectedAddresses: [PhotoAddress] {
        let selected = photoSelection
        guard !selected.isEmpty else { return activeAddress.map { [$0] } ?? [] }
        return library.items.addresses(at: selectedPlaces(selected))
    }

    /// The IDs of the photos selected, in the filmstrip's order; the active photo's alone when nothing else is. Every
    /// photo of the list selected is its IDs as they are, without a pass over them (`PhotoSelection.ids(in:)`).
    var selectedIDs: [Int64] {
        let selected = photoSelection
        guard !selected.isEmpty else { return selectionID.map { [$0] } ?? [] }
        return Array(selected.ids(in: library.photoList))
    }

    /// The photos selected, for an action on them all to work through (`SelectedPhotos`): their addresses, a version
    /// as itself (LIB-48), or a large source's IDs, the rows not read left unread. `excluding` leaves out the photo it
    /// names, the edit open for Sync and Paste.
    internal func selectionForAction(excluding: PhotoAddress? = nil) -> SelectedPhotos {
        guard library.items.readsOnRequest, let source = library.rowSource else {
            let selected = photoSelection
            // The active photo alone when nothing else is: the edit of it open, when it's open.
            let active = selection
                .map { url in openPhoto.flatMap { $0.url == url ? $0 : nil } ?? PhotoAddress(url: url) }
            let photos = selected.isEmpty ? active.map { [$0] } ?? [] : library.items
                .addresses(at: selectedPlaces(selected))
            return SelectedPhotos(excluding.map { photo in photos.filter { $0 != photo } } ?? photos)
        }
        // Every photo of a list selected is its IDs as they are, without a pass over them.
        let selected = photoSelection.isEmpty ? ContiguousArray(selectedIDs) : photoSelection.ids(in: library.photoList)
        let left = excluding.flatMap(library.photoID(of:))
        let ids = left.map { left in ContiguousArray(selected.lazy.filter { $0 != left }) } ?? selected
        return SelectedPhotos(ids: ids, read: library.items.rowsRead.mapValues(\.address), source: source)
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
    /// from their addresses, a version's row for a version (LIB-48); photos the index doesn't have are left out.
    func selectedIndexIDs() async -> [Int64] {
        if library.showsIndexIDs {
            return selectedIDs
        }
        let photos = selectedAddresses
        guard let index = library.service?.core?.index else { return [] }
        let found = await LibraryService.indexIDs(of: photos, in: index)
        return photos.compactMap { found[$0] }
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

    /// The active photo's row: the selection's active one while it's a row of the active photo's file, the file's own
    /// or one of its versions' (LIB-48), else the file's own row. The photo opening's, while one is.
    var activeID: Int64? {
        guard let photo = opening ?? selection else { return nil }
        if let id = photoSelection.active, library.address(ofPhoto: id)?.url == photo {
            return id
        }
        return library.photoID(of: activePlace(of: photo)) ?? library.photoID(of: photo)
    }

    /// The row of the photo `selection` names: `activeID`, but for the photo left while another is opening.
    var selectionID: Int64? {
        opening == nil ? activeID : selection.flatMap(library.photoID(of:))
    }

    /// The active photo as its address: its file, and the version its row is (`activeID`); without a row, the
    /// version Develop has open or is to open.
    var activeAddress: PhotoAddress? {
        guard let photo = opening ?? selection else { return nil }
        if let id = activeID, let address = library.address(ofPhoto: id), address.url == photo {
            return address
        }
        return activePlace(of: photo)
    }

    /// `photo`, the active file, in the version Develop has open, or the one it's to open.
    private func activePlace(of photo: URL) -> PhotoAddress {
        PhotoAddress(url: photo, version: opening == nil && info?.url == photo ? openVersion : openingVersion)
    }

    /// A click on a photo in the filmstrip or the grid, or an arrow key in the grid: on its own it
    /// selects only that photo; `toggling` (⌘) adds it or takes it away; `extending` (⇧) selects the
    /// range from the photo last clicked or moved to without ⇧. The clicked photo becomes the active
    /// one, unless it was just taken away.
    func click(_ url: URL, toggling: Bool = false, extending: Bool = false) {
        click(PhotoAddress(url: url), toggling: toggling, extending: extending)
    }

    /// A click on the cell of the photo `photo` names: a file's own edit, or one of its versions, a photo of its own
    /// in the library's lists (LIB-48).
    func click(_ photo: PhotoAddress, toggling: Bool = false, extending: Bool = false) {
        guard let id = library.photoID(of: photo), toggling || extending else { return select(photo) }
        let list = library.photoList
        if extending, let anchor = anchorID {
            photoSelection.select(from: anchor, through: id, in: list)
            select(photo, keepingSelection: true)
        } else if photoSelection.contains(id), toggling {
            guard photoSelection.count > 1 else { return }
            let wasActive = id == activeID
            photoSelection.toggle(id, in: list)
            if wasActive, let next = photoSelection.active.flatMap(library.address(ofPhoto:)) {
                select(next, keepingSelection: true)
                selectionAnchor = next
            }
        } else if toggling {
            photoSelection.toggle(id, in: list)
            select(photo, keepingSelection: true)
            selectionAnchor = photo
        } else {
            select(photo)
        }
    }

    /// The row ⇧ extends the selection from: the photo last clicked or moved to without ⇧, else the active one, while
    /// it's shown.
    internal var anchorID: Int64? {
        [selectionAnchor, activeAddress].lazy.compactMap { $0.flatMap(self.library.photoID(of:)) }.first
    }

    /// ⌘A: every photo in the filmstrip, the active one staying active. With no photo active, as after the last one
    /// shown went to the Trash, the first becomes the active one (#543).
    func selectAllPhotos() {
        photoSelection.selectAll(in: library.photoList)
        guard activeID == nil, let first = photoSelection.active.flatMap(library.address(ofPhoto:)) else { return }
        select(first, keepingSelection: true)
        selectionAnchor = first
    }

    /// ⌘D: only the active photo.
    func deselectOtherPhotos() {
        let active = activeAddress
        selectOnly(active)
        selectionAnchor = active
    }

    /// Selects `url` alone, if it's shown.
    internal func selectOnly(_ url: URL?) {
        selectOnly(url.map { PhotoAddress(url: $0) })
    }

    /// Selects the photo `photo` names alone, a file's own edit or one of its versions (LIB-48), if it's shown; for a
    /// version not shown, its file's own row.
    internal func selectOnly(_ photo: PhotoAddress?) {
        var only = PhotoSelection()
        if let photo, let id = library.photoID(of: photo) ?? library.photoID(of: photo.url) {
            only.select(id, in: library.photoList)
        }
        photoSelection = only
    }

    /// After photos came or went: those gone leave the selection, and the active photo is selected
    /// again when nothing else is, as when a folder is listed afresh.
    internal func keepSelectionShown() {
        photoSelection.keep(in: library.photoList)
        if photoSelection.isEmpty, let active = activeAddress, library.photoID(of: active.url) != nil {
            selectOnly(active)
        }
    }
}
