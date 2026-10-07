import Foundation

/// The actions of the sources the Folders panel chooses (LIB-10): Show Photos in Subfolders.
extension EditorModel {
    /// Nil for every other action.
    func performSourceShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .showPhotosInSubfolders:
            setIncludesSubfolders(!library.includesSubfolders)
            return true
        default:
            return nil
        }
    }

    /// Whether `performSourceShortcut` would do something now; nil for the actions it leaves alone.
    func canPerformSourceShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .showPhotosInSubfolders: true
        default: nil
        }
    }
}
