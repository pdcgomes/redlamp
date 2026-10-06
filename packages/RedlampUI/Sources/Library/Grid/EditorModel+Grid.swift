import Foundation
import RedlampLibrary

/// The Library grid's and loupe's actions (LIB-14): the thumbnail size, the cell style, the loupe's zoom,
/// opening a photo in the loupe or Develop, showing photos in Finder, the rubber band's selection, and
/// each source's view kept as it's left and shown again as it comes back.
public extension EditorModel {
    /// J: compact, expanded, none, as in Lightroom Classic.
    func cycleCellStyle() {
        libraryViews.setCellStyle(libraryViews.cellStyle.next)
    }

    func setCellStyle(_ style: GridCellStyle) {
        libraryViews.setCellStyle(style)
    }

    /// The thumbnail slider: a cell's width in points.
    func setThumbnailSize(_ size: Double) {
        libraryViews.setThumbnailSize(size)
    }

    /// = and -: the next size up or down.
    func growThumbnails() {
        libraryViews.setThumbnailSize(GridSize.larger(than: libraryViews.thumbnailSize))
    }

    func shrinkThumbnails() {
        libraryViews.setThumbnailSize(GridSize.smaller(than: libraryViews.thumbnailSize))
    }

    /// `url` large in the loupe: active, among the selection if it's in it, else alone; `zoomed` shows
    /// it at 1:1 (Z from the grid) and nil keeps the loupe's zoom.
    func openInLoupe(_ url: URL, zoomed: Bool? = nil) {
        makeActive(url)
        if let zoomed {
            libraryViews.setLoupeZoom(zoomed ? .actual : .fit)
        }
        showLibrary(.loupe)
    }

    /// `url` in Develop, on the Edit tool, as D does.
    func openInDevelop(_ url: URL) {
        makeActive(url)
        perform(.editTool)
    }

    /// Z in the loupe, or a click: fit, or 1:1.
    func toggleLoupeZoom() {
        libraryViews.setLoupeZoom(libraryViews.loupeZoom == .fit ? .actual : .fit)
    }

    func setLoupeZoom(_ zoom: LoupeZoom) {
        libraryViews.setLoupeZoom(zoom)
    }

    /// ⌘R: the selected photos in Finder, or `url` alone when it isn't among them.
    func showInFinder(_ url: URL? = nil) {
        let shown: [URL] = if let url, library.photoID(of: url).map(photoSelection.contains) != true {
            [url]
        } else {
            selectedPhotos
        }
        guard !shown.isEmpty else { return }
        libraryViews.revealInFinder(shown)
    }

    /// Makes `url` the active photo, keeping the selection when it's in it.
    private func makeActive(_ url: URL) {
        guard url != selection else { return }
        if let id = library.photoID(of: url), photoSelection.contains(id) {
            photoSelection.activate(id)
            select(url, keepingSelection: true)
            selectionAnchor = url
        } else {
            select(url)
        }
    }

    /// The photos a rubber band covers in the grid, by row, alone or, with ⇧ or ⌘, added to `base`, the
    /// selection when the band started. The active photo stays active while it's selected; a band that
    /// covers nothing leaves it selected alone.
    internal func selectInBand(_ rows: [Int], adding base: PhotoSelection?) {
        let list = library.photoList
        let ids = library.photoIDs
        let activeID = selection.flatMap(library.photoID(of:))
        var band = PhotoSelection()
        band.select(rows.lazy.filter(ids.indices.contains).map { ids[$0] }, active: activeID, in: list)
        var next = base ?? band
        if base != nil {
            next.formUnion(band, in: list)
        }
        if next.isEmpty, let activeID {
            next.select(activeID, in: list)
        }
        guard next != photoSelection else { return }
        photoSelection = next
        if let active = next.active.flatMap(library.url(ofPhoto:)), active != selection {
            select(active, keepingSelection: true)
            selectionAnchor = active
        }
    }

    // MARK: - Keys and menus

    /// The grid's and the loupe's actions; nil for every other.
    internal func performGridShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .cycleGridStyle: cycleCellStyle()
        case .largerThumbnails:
            guard libraryViews.thumbnailSize < GridSize.range.upperBound else { return false }
            growThumbnails()
        case .smallerThumbnails:
            guard libraryViews.thumbnailSize > GridSize.range.lowerBound else { return false }
            shrinkThumbnails()
        case .showInFinder:
            guard selection != nil else { return false }
            showInFinder()
        case .toggleZoom where module == .library:
            // In the grid, Space and Z go on to it: Space opens the loupe, Z the loupe at 1:1.
            guard libraryView == .loupe, selection != nil else { return false }
            toggleLoupeZoom()
        default: return nil
        }
        return true
    }

    /// Whether `performGridShortcut` would do something now; nil for the actions it leaves alone.
    internal func canPerformGridShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .cycleGridStyle: true
        case .largerThumbnails: libraryViews.thumbnailSize < GridSize.range.upperBound
        case .smallerThumbnails: libraryViews.thumbnailSize > GridSize.range.lowerBound
        case .showInFinder: selection != nil
        case .toggleZoom where module == .library: libraryView == .loupe && selection != nil
        default: nil
        }
    }

    // MARK: - Each source's view

    /// The open folder as a source of the grid, with or without its subfolders.
    internal var sourceKey: String? {
        folder.map { (library.includesSubfolders ? "+" : "") + $0.path }
    }

    /// Keeps the open source's view as it's left: its size, cell style, place and selection.
    internal func rememberSourceView() {
        guard let source = sourceKey, !items.isEmpty else { return }
        libraryViews.remember(source, selection: isMultiSelecting ? selectedPhotos : [], active: selection)
    }

    /// Shows the source just listed as it was left: its size and cell style, its place, and its selection
    /// when the photo it had active is the one active again.
    internal func restoreSourceView() {
        guard let source = sourceKey, let view = libraryViews.restore(source), let active = selection,
              view.active == active.path, view.selected.count > 1, let activeID = library.photoID(of: active)
        else { return }
        let ids = view.selected.compactMap { library.photoID(of: URL(fileURLWithPath: $0)) }
        photoSelection.select(ids + [activeID], active: activeID, in: library.photoList)
    }
}
