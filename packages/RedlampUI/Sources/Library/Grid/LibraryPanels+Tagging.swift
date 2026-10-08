import Foundation
import RedlampLibrary

/// Keywords put on photos given rather than the selection (LIB-21): a keyword dropped on a photo in the grid, and the
/// painter's strokes. Each is one change of the panels', with Undo and Redo on Library's ⌘Z and ⇧⌘Z, made once the
/// photos' IDs in the index are found; photos the library hasn't read are left out.
extension LibraryPanels {
    /// Puts `keywords` on `photos` (their IDs in the list shown, and their URLs), or with `removing` takes them off;
    /// false when there's nothing to change.
    @discardableResult
    func change(_ keywords: [KeywordPath], removing: Bool = false, on photos: [(list: Int64, url: URL)]) async
        -> Bool {
        guard !keywords.isEmpty, !photos.isEmpty, let core = model?.library.service?.core else { return false }
        let found = await photoIDs.ids(of: photos, in: core.index)
        let known = photos.filter { found[$0.list] != nil }
        let ids = known.compactMap { found[$0.list] }
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
            photos: (known.map(\.url), ids),
        )
    }
}
