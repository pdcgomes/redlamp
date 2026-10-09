import Foundation
import RedlampDocument
import RedlampEngineAPI

public extension EditorModel {
    /// Opens folders (each joins the working set) or loose files (their folder joins it, and the
    /// first file is selected). The first folder opens in the filmstrip. A URL is a photo by its
    /// extension, so nothing is read on the main thread.
    func open(_ urls: [URL]) {
        var folders: [URL] = []
        var firstFile: URL?
        for url in urls {
            if !url.hasDirectoryPath, SupportedFormats.isSupported(url) {
                folders.append(url.deletingLastPathComponent())
                firstFile = firstFile ?? url
            } else {
                folders.append(url)
            }
        }
        guard let first = firstFile?.deletingLastPathComponent() ?? folders.first else { return }
        library.add(folders)
        openFolder(first, select: firstFile)
    }

    /// Opens a folder of the working set in the filmstrip.
    func showFolder(_ folder: URL) {
        guard folder != self.folder else { return }
        openFolder(folder, select: nil)
    }

    /// Finds the working set again and reopens the folder and photo of the last session.
    func restoreLibrary() {
        library.restore { [weak self] folder, photo in
            guard let self, let folder else { return }
            openFolder(folder, select: photo)
        }
    }

    /// Show Photos in Subfolders.
    func setIncludesSubfolders(_ include: Bool) {
        let keep = selection
        rememberSourceView()
        library.setIncludesSubfolders(include) { [weak self] found in
            self?.didList(found, select: keep)
            self?.restoreSourceView()
        }
    }

    internal func openFolder(_ url: URL, select target: URL?) {
        stackSuggestions = []
        onFolderChange?(url)
        rememberSourceView()
        library.open(url) { [weak self] found in
            self?.didList(found, select: target ?? self?.library.lastPhoto(in: url))
            self?.restoreSourceView()
        }
    }

    /// The folder's first photos are in: selects `target` if it's among them, else the first.
    internal func didList(_ found: [LibraryItem], select target: URL?) {
        if let next = target.flatMap({ library.index(of: $0) != nil ? $0 : nil }) ?? found.first?.url {
            if next == selection {
                selectionIndex = library.index(of: next)
            } else {
                select(next)
            }
        }
        thumbnailLoader.warm(found)
        noteCustomLabels(in: found)
    }

    /// Keeps the editor in step with the folder as it changes on disk: when the selected photo is
    /// deleted or moved away, its neighbour is selected, as deleting does in Lightroom.
    internal func followLibrary() {
        libraryObservation = library.observe { [weak self] diff in self?.libraryChanged(diff) }
        library.adjust = { [weak self] diff in self?.keepCullingShown(diff) }
        library.onReopened = { [weak self] found in self?.didList(found, select: self?.selection) }
        library.files = engine.files
        library.onStacks = { [weak self] found in
            guard let self else { return }
            stackSuggestions = found.filter { !dismissedStacks.contains($0) }
        }
        library.onRemoved = { [weak self] in self?.libraryLostFolder() }
        library.followUnfinishedSidecarMove { [weak self] in self?.finishSidecarMove($0) }
    }

    /// A folder left the library, from Folders or as the library opened: what counts from the index counts again,
    /// the Keyword List, the Library panel and the custom labels.
    private func libraryLostFolder() {
        libraryPanels.refreshKeywords()
        librarySources.recount()
        refreshCustomLabels()
    }

    private func libraryChanged(_ diff: LibraryDiff) {
        if diff.reset || !diff.removed.isEmpty || !diff.inserted.isEmpty {
            keepSelectionShown()
        }
        if diff.reset {
            refreshCustomLabels()
        }
        if library.isFiltered, diff.reset || !diff.removed.isEmpty, let selection, library.index(of: selection) == nil {
            if libraryFilters?.isTyping != true {
                keepActivePhotoShown()
            }
            return
        }
        guard !diff.reset, let selection else { return }
        if let index = library.index(of: selection) {
            selectionIndex = index
        } else if let last = selectionIndex, !diff.removed.isEmpty, !items.isEmpty {
            selectRow(min(last, items.count - 1))
        }
    }

    /// Selects row `row`'s photo: at once, or, for a large source's row not read yet, once it's read.
    internal func selectRow(_ row: Int, keepingSelection: Bool = false) {
        guard items.indices.contains(row) else { return }
        if let item = items.row(row) {
            return select(item.url, keepingSelection: keepingSelection)
        }
        let id = library.photoIDs[row]
        library.whenRead([id]) { [weak self] in
            guard let self, let url = library.url(ofPhoto: id) else { return }
            select(url, keepingSelection: keepingSelection)
        }
    }

    func selectNext() {
        step(by: 1)
    }

    func selectPrevious() {
        step(by: -1)
    }

    private func step(by offset: Int) {
        guard let from = opening ?? selection, let index = library.index(of: from) else { return }
        let next = index + offset
        guard items.indices.contains(next) else { return }
        selectRow(next)
    }

    /// The photo being opened, then its neighbours in the grid's order (`GridOrder`), where ← and → go, the
    /// direction of travel first.
    internal func workingSet(around url: URL, comingFrom previous: URL?) -> [URL] {
        guard let id = library.photoID(of: url) else { return [url] }
        let order = gridOrder
        let place = order.place(of: id) ?? .max
        let backward = previous.flatMap(library.photoID(of:)).flatMap(order.place(of:)).map { $0 > place } ?? false
        let step = backward ? -1 : 1
        let ahead = order.cell(step, from: id)
        let neighbours = [ahead, order.cell(-step, from: id), ahead.flatMap { order.cell(step, from: $0) }]
        library.askForRows(ofPhotos: neighbours.compactMap(\.self))
        return [url] + neighbours.compactMap { $0.flatMap(library.url(ofPhoto:)) }
    }
}
