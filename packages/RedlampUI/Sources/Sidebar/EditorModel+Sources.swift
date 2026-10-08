import Foundation

/// The actions of the sources the left panel chooses: Show Photos in Subfolders (LIB-10); the Library panel's
/// entries and the collections' (LIB-23, `LibrarySources`); and Recently Trashed's (LIB-26, `EditorModel+Trash`),
/// which come before every other action's so that Recently Trashed can leave off those that would write to its
/// photos.
extension EditorModel {
    /// Nil for every other action.
    func performSourceShortcut(_ action: ShortcutAction) -> Bool? {
        if let source = action.librarySource {
            return librarySources.show(source)
        }
        switch action {
        case .showPhotosInSubfolders:
            setIncludesSubfolders(!library.includesSubfolders)
            return true
        case .newCollection:
            return CollectionSheets.create(.collection, model: self)
        case .newSmartCollection:
            return SmartCollectionSheet.create(model: self)
        case .newCollectionSet:
            return CollectionSheets.create(.set, model: self)
        case .addToCollection:
            return CollectionSheets.addToCollection(model: self)
        case .addToTargetCollection:
            return librarySources.addToTarget()
        case .removeFromCollection:
            return librarySources.removeFromShown()
        default:
            return performTrashShortcut(action)
        }
    }

    /// Whether `performSourceShortcut` would do something now; nil for the actions it leaves alone.
    func canPerformSourceShortcut(_ action: ShortcutAction) -> Bool? {
        if let source = action.librarySource {
            return librarySources.canShow(source)
        }
        switch action {
        case .showPhotosInSubfolders: return true
        case .newCollection, .newSmartCollection, .newCollectionSet: return library.service?.isReady == true
        case .addToCollection: return librarySources.canAdd && !librarySources.collectionsTakingPhotos.isEmpty
        case .addToTargetCollection: return librarySources.canAdd
        case .removeFromCollection: return librarySources.canRemove
        default: return canPerformTrashShortcut(action)
        }
    }
}

extension ShortcutAction {
    /// The Library panel's entry the action shows; nil for every other action.
    var librarySource: LibrarySource? {
        switch self {
        case .showAllPhotographs: .allPhotographs
        case .showPreviousImport: .previousImport
        case .showMarked: .marked
        case .showRejected: .rejected
        default: nil
        }
    }
}
