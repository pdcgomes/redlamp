import Foundation

/// Several photos selected in the filmstrip, as in Lightroom: the active photo is the one open
/// (`selection`), always among them, and the one a click makes active. Sync and Paste then reach
/// the rest (`docs/plans/2026-10-02-copy-paste-sync-design.md`).
public extension EditorModel {
    var isMultiSelecting: Bool {
        selectedPhotos.count > 1
    }

    /// A click on a photo in the filmstrip or the grid, or an arrow key in the grid: on its own it
    /// selects only that photo; `toggling` (⌘) adds it or takes it away; `extending` (⇧) selects the
    /// range from the photo last clicked or moved to without ⇧. The clicked photo becomes the active
    /// one, unless it was just taken away.
    func click(_ url: URL, toggling: Bool = false, extending: Bool = false) {
        if extending, let anchor = extensionAnchor, let from = library.index(of: anchor),
           let to = library.index(of: url) {
            selectedPhotos = (min(from, to) ... max(from, to)).map { items[$0].url }
            select(url, keepingSelection: true)
        } else if toggling, selectedPhotos.contains(url) {
            guard selectedPhotos.count > 1 else { return }
            selectedPhotos.removeAll { $0 == url }
            if url == selection, let next = selectedPhotos.last {
                select(next, keepingSelection: true)
                selectionAnchor = next
            }
        } else if toggling {
            selectedPhotos = inFilmstripOrder(selectedPhotos + [url])
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
        selectedPhotos = items.map(\.url)
    }

    /// ⌘D: only the active photo.
    func deselectOtherPhotos() {
        selectedPhotos = selection.map { [$0] } ?? []
        selectionAnchor = selection
    }

    private func inFilmstripOrder(_ urls: [URL]) -> [URL] {
        Array(Set(urls)).sorted { (library.index(of: $0) ?? .max) < (library.index(of: $1) ?? .max) }
    }
}
