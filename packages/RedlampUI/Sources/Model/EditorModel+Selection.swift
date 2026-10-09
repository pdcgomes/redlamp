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
    /// would make a photo at a time; and only the photos selected are read, each a copy of many references.
    var selectedPhotos: [URL] {
        let selected = photoSelection
        guard !selected.isEmpty else { return selection.map { [$0] } ?? [] }
        let ids = library.photoIDs
        var urls: [URL] = []
        urls.reserveCapacity(selected.count)
        items.withUnsafeBufferPointer { items in
            for index in ids.indices where items.indices.contains(index) && selected.contains(ids[index]) {
                urls.append(items[index].url)
            }
        }
        return urls
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
