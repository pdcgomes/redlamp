import Foundation

/// The actions of the sources the left panel chooses: Show Photos in Subfolders (LIB-10); the Library panel's
/// entries (LIB-23, `LibrarySources`); and Recently Trashed's (LIB-26, `EditorModel+Trash`), which come before
/// every other action's so that Recently Trashed can leave off those that would write to its photos.
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
