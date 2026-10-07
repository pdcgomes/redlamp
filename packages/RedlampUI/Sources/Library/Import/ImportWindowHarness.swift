import AppKit
import RedlampLibrary

/// What the regression suite reads and sets in the import window: what a person sets through its
/// panels, which can't be driven, and what it shows.
@_spi(Harness) public extension ImportWindowController {
    /// The destination, the backup and the templates, as the panels and fields would set them.
    func prepare(destination: URL, backup: URL?, folders: String, names: String) {
        model.setDestination(destination)
        model.setBackup(backup)
        model.setFolders(folders)
        model.setNames(names)
    }

    /// Add Folder…'s folder.
    func add(folder: URL) async throws {
        try await model.addFolder(folder)
    }

    /// The photos the grid shows.
    var photoCount: Int {
        model.photos.count
    }

    /// Every source is listed, and each of its photos read.
    var isBrowsed: Bool {
        !model.sources.isEmpty && model.sources.allSatisfy(\.isBrowsed)
    }

    /// Previews put on screen in the grid so far.
    var imagesShown: Int {
        grid.imagesShown
    }

    /// The grid's cells on screen.
    var visibleCount: Int {
        grid.collectionView.indexPathsForVisibleItems().count
    }

    /// The names of the photos given `rating` stars.
    func ratedNames(rating: Int) -> [String] {
        model.photos.filter { $0.choices.rating == rating }.map(\.primary.name)
    }

    /// Cancel Import.
    func stop() {
        model.cancel()
    }

    /// Selects the photos at these places in the grid, and gives the grid the keys.
    func select(_ items: [Int]) {
        grid.collectionView.selectionIndexPaths = Set(items.map { IndexPath(item: $0, section: 0) })
        window?.makeFirstResponder(grid.collectionView)
    }

    /// The rating, flag and label given the photo at `item`, as the grid's badges write them.
    func badges(at item: Int) -> String? {
        model.photo(at: item).map { ImportGridCell.badges($0, leftOut: false, copied: false) }
    }

    func scroll(to fraction: Double) {
        grid.scroll(to: fraction)
    }

    var isCopying: Bool {
        model.phase == .copying && model.progress != nil
    }

    var isFinished: Bool {
        model.phase == .finished
    }

    /// What the import did: photos verified, and whether every source can be erased.
    var result: (verified: Int, safeToErase: Bool)? {
        model.outcome.map { ($0.verified, $0.isSafeToErase) }
    }

    var summary: String {
        model.summary
    }

    /// Takes the folder holding `url` out of Folders, as the scenarios leave Folders as they found it.
    static func forget(_ url: URL, in editor: EditorModel) {
        if let root = editor.library.root(containing: url) {
            editor.library.remove(root)
        }
    }
}
