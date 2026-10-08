import AppKit
import Foundation
import RedlampLibrary

/// Recently Trashed in the editor (LIB-26): showing it, from the Folders panel, the View menu and the palette,
/// and Put Back for a photo, the selection or a whole batch, from a photo's context menu, the Photo menu, the
/// palette and ⌘⌫, Finder's key for it; Library's ⌘Z and ⇧⌘Z take a Put Back back and make it again
/// (`EditorModel+PutBackUndo`).
///
/// Its photos are in the Trash, and don't open in Develop: Recently Trashed is shown in the Library module,
/// and from it Develop, culling and everything else that would write to a photo is off, leaving Library's
/// views, moving about, Show in Finder and Put Back. A photo put back is where it was, its edit with it.
public extension EditorModel {
    /// Recently Trashed as the source of the grid and the filmstrip, in the Library module.
    func showRecentlyTrashed() {
        guard library.canShowRecentlyTrashed else { return }
        showModule(.library)
        rememberSourceView()
        stackSuggestions = []
        library.showRecentlyTrashed { [weak self] found in self?.didList(found, select: nil) }
    }

    /// The photos of Recently Trashed that Put Back puts back for `photo`: the selection when `photo` is in it
    /// or not given, and `photo` alone when it isn't.
    func trashedPhotos(for photo: URL? = nil) -> [TrashedPhoto] {
        let urls: [URL] = if let photo, photo != selection,
                             library.photoID(of: photo).map(photoSelection.contains) != true {
            [photo]
        } else {
            selectedPhotos
        }
        return urls.compactMap(library.trashedPhoto(at:))
    }

    /// Put Back: the photos `trashedPhotos(for:)` gives back where they were, as one batch of the library's
    /// file operations, which Library's Undo takes back. Nil when there's nothing to put back.
    @discardableResult
    func putBack(_ photo: URL? = nil) -> Task<Void, Never>? {
        let photos = trashedPhotos(for: photo)
        guard !photos.isEmpty, let service = library.service else { return nil }
        let ids = photos.map(\.id)
        return makePutBack(originals: originals(of: photos)) { try await service.putBack(ids) }
    }

    /// Put Back Whole Batch: every photo still in the Trash of the batch that moved `photo` there, or the
    /// active photo.
    @discardableResult
    func putBackBatch(of photo: URL? = nil) -> Task<Void, Never>? {
        guard let target = photo ?? selection, let batch = library.trashedPhoto(at: target)?.id.batch,
              let service = library.service
        else { return nil }
        let photos = library.trash.photos.filter { $0.id.batch == batch }
        return makePutBack(originals: originals(of: photos)) { try await service.putBack([], batch: batch) }
    }

    /// Where `photos` and their pairs go back to.
    private func originals(of photos: [TrashedPhoto]) -> [URL] {
        let pairs = Set(photos.flatMap(\.pair))
        let paired = library.trash.photos.filter { pairs.contains($0.id) }
        return Array(Set((photos + paired).map { URL(fileURLWithPath: $0.original) }))
    }

    /// What stopped a Put Back, said in the activity log and an alert.
    internal func putBackFailed(_ error: any Error) {
        let message = Self.putBackFailure(error)
        activity.record(.error, message)
        guard let window = NSApp.keyWindow else { return }
        let alert = NSAlert()
        alert.messageText = "The photos weren't put back"
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in }
    }

    /// Why a Put Back stopped, in a sentence.
    private static func putBackFailure(_ error: any Error) -> String {
        switch error as? FileOperationError {
        case let .conflicts(conflicts):
            "Nothing moved: " + conflicts.map(\.description).joined(separator: "; ") + "."
        case .unfinished:
            "Nothing moved: Redlamp is finishing the file operations a forced quit cut short. Try again in a moment."
        case let .failed(path, message):
            "\(path) couldn't be moved (\(message)), so everything was put back as it was."
        case let .stuck(_, path, message):
            "\(path) couldn't be moved (\(message)). The next launch finishes or rolls back what was done."
        default:
            "Nothing moved: \(error)."
        }
    }

    // MARK: - Keys, menus and the palette

    /// What Recently Trashed leaves on while it's shown: Library's views, moving about, the panels, Show in
    /// Finder and Put Back, and what reaches no photo.
    internal static let actionsInRecentlyTrashed: Set<ShortcutAction> = [
        .libraryModule, .gridView, .loupeView, .compareView, .surveyView,
        .cycleGridStyle, .largerThumbnails, .smallerThumbnails, .showInFinder, .showPhotosInSubfolders,
        .showRecentlyTrashed, .putBack, .putBackBatch,
        .toggleZoom, .lightsOut, .fullScreenPreview, .toggleToolbar,
        .toggleSidePanels, .toggleAllPanels, .toggleFilmstrip, .toggleLeftPanel, .toggleRightPanel,
        .previousPhoto, .nextPhoto, .selectAllPhotos, .deselectOtherPhotos, .autoAdvance,
        .openFolder, .showShortcuts, .commandPalette, .sendFeedback, .testCamera, .filmLooks, .cancel,
    ]

    /// Recently Trashed's actions, Library's Undo and Redo when a Put Back is the newest change, and in Recently
    /// Trashed every action it leaves off; nil for every other.
    internal func performTrashShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .showRecentlyTrashed:
            guard library.canShowRecentlyTrashed else { return false }
            showRecentlyTrashed()
        case .putBack:
            return putBack() != nil
        case .putBackBatch:
            return putBackBatch() != nil
        case .undo where putBackUndoIsNewest:
            return undoPutBack()
        case .redo where putBackRedoIsNewest:
            return redoPutBack()
        default:
            guard library.showsRecentlyTrashed, !Self.actionsInRecentlyTrashed.contains(action) else { return nil }
            return false
        }
        return true
    }

    /// Whether `performTrashShortcut` would do something now; nil for the actions it leaves alone.
    internal func canPerformTrashShortcut(_ action: ShortcutAction) -> Bool? {
        switch action {
        case .showRecentlyTrashed:
            library.canShowRecentlyTrashed
        case .putBack:
            library.showsRecentlyTrashed && !trashedPhotos().isEmpty
        case .putBackBatch:
            library.showsRecentlyTrashed && selection.flatMap(library.trashedPhoto(at:)) != nil
        case .undo where putBackUndoIsNewest, .redo where putBackRedoIsNewest:
            true
        default:
            library.showsRecentlyTrashed && !Self.actionsInRecentlyTrashed.contains(action) ? false : nil
        }
    }
}
