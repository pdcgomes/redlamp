import Foundation

/// The actions of the sources the Folders panel chooses: Show Photos in Subfolders (LIB-10), and Recently
/// Trashed's (LIB-26, `EditorModel+Trash`), which come before every other action's so that Recently Trashed
/// can leave off those that would write to its photos.
extension EditorModel {
    /// Nil for every other action.
    func performSourceShortcut(_ action: ShortcutAction) -> Bool? {
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
        switch action {
        case .showPhotosInSubfolders: true
        default: canPerformTrashShortcut(action)
        }
    }
}
