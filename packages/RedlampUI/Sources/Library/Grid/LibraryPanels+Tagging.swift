import Foundation
import RedlampLibrary

/// Keywords put on photos given rather than the selection (LIB-21): a keyword dropped on a photo in the grid, and the
/// painter's strokes. Each is one change of the panels', with Undo and Redo on Library's ⌘Z and ⇧⌘Z, made once the
/// photos' IDs in the index are found, read afresh rather than from the IDs the panels keep for the selection, which
/// can hold a folder's photos as they were while a batch moved photos into it; photos the library hasn't read are
/// left out.
extension LibraryPanels {
    /// Puts `keywords` on the photos at `urls`, or with `removing` takes them off; false when there's nothing to
    /// change.
    @discardableResult
    func change(_ keywords: [KeywordPath], removing: Bool = false, on urls: [URL]) async -> Bool {
        guard !keywords.isEmpty, !urls.isEmpty, let core = model?.library.service?.core else { return false }
        let found = await LibraryService.indexIDs(of: urls, in: core.index)
        let known = urls.filter { found[$0] != nil }
        return change(keywords, removing: removing, photos: (known, known.compactMap { found[$0] }))
    }

    /// Puts `keywords` on the photos with the index's IDs `ids`, or with `removing` takes them off: a large source's
    /// selection, whose rows aren't read for it.
    @discardableResult
    func change(_ keywords: [KeywordPath], removing: Bool = false, ids: [Int64]) -> Bool {
        guard !keywords.isEmpty else { return false }
        return change(keywords, removing: removing, photos: ([], ids))
    }

    private func change(_ keywords: [KeywordPath], removing: Bool, photos: (urls: [URL], ids: [Int64])) -> Bool {
        let ids = photos.ids
        guard !ids.isEmpty else { return false }
        var overlay = PanelOverlay(ids: ids.sorted())
        if removing {
            overlay.removing = keywords
        } else {
            overlay.adding = keywords
        }
        return make(
            [.keywords(removing ? .remove(keywords, from: ids) : .add(keywords, to: ids))],
            title: Self.title(removing ? "Remove" : "Add", keywords, ids.count, from: removing), overlay: overlay,
            photos: photos,
        )
    }
}
