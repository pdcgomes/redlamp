import Foundation
import RedlampDocument

public extension EditorModel {
    /// Opens a folder, or loose files (their folder becomes the library).
    func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            openFolder(first, select: nil)
        } else {
            openFolder(first.deletingLastPathComponent(), select: first)
        }
    }

    internal func openFolder(_ url: URL, select target: URL?) {
        stackSuggestions = []
        thumbnails = [:]
        onFolderChange?(url)
        library.open(url) { [weak self] found in
            guard let self else { return }
            detectStacks(in: found.map(\.url), folder: url)
            if let next = target ?? found.first?.url {
                select(next)
            }
        }
    }

    func loadThumbnail(for url: URL) async {
        guard thumbnails[url] == nil else { return }
        if let image = await engine.thumbnail(for: url, maxPixelSize: 256) {
            thumbnails[url] = image
        }
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
