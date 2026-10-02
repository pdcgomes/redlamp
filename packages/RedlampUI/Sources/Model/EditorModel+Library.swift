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
        library.setIncludesSubfolders(include) { [weak self] found in
            self?.didList(found, select: keep)
        }
    }

    internal func openFolder(_ url: URL, select target: URL?) {
        stackSuggestions = []
        onFolderChange?(url)
        library.open(url) { [weak self] found in
            self?.didList(found, select: target ?? self?.library.lastPhoto(in: url))
        }
    }

    /// The folder's first photos are in: selects `target` if it's among them, else the first.
    private func didList(_ found: [LibraryItem], select target: URL?) {
        guard let folder else { return }
        detectStacks(in: found.map(\.url), folder: folder)
        if let next = target.flatMap({ library.index(of: $0) != nil ? $0 : nil }) ?? found.first?.url {
            select(next)
        }
        thumbnailLoader.warm(found)
    }

    func selectNext() {
        step(by: 1)
    }

    func selectPrevious() {
        step(by: -1)
    }

    private func step(by offset: Int) {
        guard let selection, let index = library.index(of: selection) else { return }
        let next = index + offset
        guard items.indices.contains(next) else { return }
        select(items[next].url)
    }

    /// The photo being opened, then its neighbours, the direction of travel first.
    internal func workingSet(around url: URL, comingFrom previous: URL?) -> [URL] {
        guard let index = library.index(of: url) else { return [url] }
        let backward = previous.flatMap(library.index(of:)).map { $0 > index }
        let offsets = backward == true ? [-1, 1, -2] : [1, -1, 2]
        return [url] + offsets.map { index + $0 }.filter(items.indices.contains).map { items[$0].url }
    }
}
