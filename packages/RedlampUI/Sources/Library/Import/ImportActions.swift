import AppKit
import Foundation
import Observation
import RedlampLibrary

/// How the app reaches the import window (LIB-27): File › Import Photos… (⇧⌘I, as in Lightroom Classic)
/// and the command palette, and an import a forced quit cut short, found at launch, to be resumed.
@MainActor
public enum ImportActions {
    /// From launch: follows the cards, and opens the import window on an import a forced quit cut short.
    public static func start(model: EditorModel) {
        let cards = ImportCards.shared
        cards.start()
        Task { [weak model] in
            guard let model else { return }
            let library = await library(of: model)
            if await (try? Importer(library: library).unfinishedEntries())?.isEmpty == false {
                open(model: model)
            }
        }
    }

    /// Opens the import window, or brings it forward, with `source` among its sources.
    @discardableResult
    static func open(model: EditorModel, adding source: ImportSource? = nil) -> Bool {
        ImportWindowController.show(library: { await library(of: model) }, adding: source) { [weak model] window in
            window.showInLibrary = { urls in model?.showImported(urls) }
        }
        return true
    }

    /// The library an import goes into, once it has opened: its index, store, indexer and live lists.
    /// With the library off, or while its index can't open, imports are journaled in its folder and
    /// nothing is indexed.
    static func library(of model: EditorModel) async -> ImportLibrary {
        guard let service = model.library.service else { return ImportLibrary(paths: .standard) }
        while service.state == .opening {
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = service.state
                } onChange: {
                    continuation.resume()
                }
            }
        }
        guard let core = service.core else { return ImportLibrary(paths: service.paths) }
        return ImportLibrary(
            paths: core.paths, index: core.index, store: core.store, indexer: core.indexer, live: core.live,
        )
    }
}

extension EditorModel {
    /// Shows an import's photos at its destination in Library's grid, selected, the first active: their
    /// folder, or the folder holding all of theirs with Show Photos in Subfolders on, added to Folders
    /// when no folder there holds it.
    func showImported(_ photos: [URL]) {
        guard let first = photos.first else { return }
        let folders = Set(photos.map { LibraryService.path($0.deletingLastPathComponent()) })
        var common = folders.first ?? LibraryService.path(first.deletingLastPathComponent())
        for folder in folders {
            while common != "/", folder != common, !folder.hasPrefix(common + "/") {
                common = (common as NSString).deletingLastPathComponent
            }
        }
        let folder = URL(fileURLWithPath: common, isDirectory: true)
        if library.root(containing: folder) == nil {
            library.add([folder])
        }
        if folders.count > 1, !library.includesSubfolders {
            library.setIncludesSubfolders(true)
        }
        showLibrary(.grid)
        openFolder(folder, select: first)
        if let source = sourceKey {
            libraryViews.remember(source, selection: photos, active: first)
        }
    }
}
