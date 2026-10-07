import AppKit
import Foundation
import Observation
import RedlampLibrary

/// How the app reaches the import window (LIB-27): File › Import Photos… (⇧⌘I, as in Lightroom Classic)
/// and the command palette.
@MainActor
public enum ImportActions {
    /// From launch: follows the cards.
    public static func start(model _: EditorModel) {
        let cards = ImportCards.shared
        cards.start()
    }

    /// Opens the import window, or brings it forward, with `source` among its sources.
    @discardableResult
    static func open(model: EditorModel, adding source: ImportSource? = nil) -> Bool {
        ImportWindowController.show(library: { await library(of: model) }, adding: source)
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
