import AppKit
import RedlampLibrary

/// Photo › Move to Folder… and Copy to Folder… (LIB-26): a folder of the library chosen in an Open panel on the editor
/// window, then the photos selected moved or copied there as one batch, each with its raw or JPEG pair, its sidecars
/// and other apps' `.xmp`; across volumes each file is copied and checked by size and SHA-256 before its original
/// goes. Moved, the photos leave the folders shown at once, the photo after them becoming active; copied, each copy
/// is a photo of its own, numbered where its name is held. The batch's progress shows in the grid's toolbar with Stop,
/// as a drop's does, rather than in a sheet, whose opening and closing each hold the main thread about 0.3 s. Library's
/// Undo puts the photos back, selected as they were, or moves the copies to the Trash.
public extension EditorModel {
    @discardableResult
    func moveToFolder() -> Bool {
        chooseFolder(copying: false)
    }

    @discardableResult
    func copyToFolder() -> Bool {
        chooseFolder(copying: true)
    }
}

extension EditorModel {
    private func chooseFolder(copying: Bool) -> Bool {
        guard canRenamePhotos, let window = EditorWindowController.frontWindow, window.attachedSheet == nil else {
            return false
        }
        if let folder = MoveFolderPanel.answer {
            Task { await place(in: folder, copying: copying) }
            return true
        }
        let count = selectedCount
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = copying ? "Copy" : "Move"
        panel.message = "Choose a folder in the library to \(copying ? "copy" : "move") "
            + "\(count == 1 ? "the photo" : "\(count) photos") to."
        panel.directoryURL = folder
        let delegate = MoveFolderPanel(roots: library.roots.map(\.url))
        panel.delegate = delegate
        isModalDialogOpen = true
        panel.beginSheetModal(for: window) { [self] response in
            MainActor.assumeIsolated {
                withExtendedLifetime(delegate) {}
                isModalDialogOpen = false
                guard response == .OK, let url = panel.url else { return }
                Task { await place(in: url, copying: copying) }
            }
        }
        return true
    }

    /// Moves or copies the photos selected into `folder`, as `showingPlace` runs it.
    private func place(in folder: URL, copying: Bool) async {
        await showingPlace(in: folder, copying: copying) { progress, done, stop in
            await self.placeSelection(in: folder, copying: copying, progress: progress, done: done, stop: stop)
        }
    }

    /// Moves the photos selected, with their pairs, into `folder`, as one batch, `progress` hearing of its steps;
    /// why it didn't happen, or nil once it has.
    @discardableResult
    func moveSelection(
        to folder: URL, progress: (@MainActor @Sendable (FileProgress) -> Void)? = nil, stop: FileStop? = nil,
    ) async -> String? {
        await placeSelection(in: folder, copying: false, progress: progress, stop: stop)
    }

    /// Copies the photos selected, with their pairs, into `folder`, as one batch, as `moveSelection` moves them.
    @discardableResult
    func copySelection(
        to folder: URL, progress: (@MainActor @Sendable (FileProgress) -> Void)? = nil, stop: FileStop? = nil,
    ) async -> String? {
        await placeSelection(in: folder, copying: true, progress: progress, stop: stop)
    }

    private func placeSelection(
        in folder: URL, copying: Bool, progress: (@MainActor @Sendable (FileProgress) -> Void)?,
        done: (@MainActor () -> Void)? = nil, stop: FileStop?,
    ) async -> String? {
        guard library.service?.isReady == true else { return "The library isn't open" }
        return await place(
            selectedIndexIDs(), in: folder, copying: copying, progress: progress, done: done, stop: stop,
        )
    }
}

/// What the Open panel lets Move to Folder and Copy to Folder choose: any folder to go through, and one in the
/// library to put the photos in.
@MainActor
final class MoveFolderPanel: NSObject, NSOpenSavePanelDelegate {
    /// The folder the regression suite chooses, as the panel, which it can't drive, would.
    static var answer: URL?

    private let roots: [String]

    init(roots: [URL]) {
        self.roots = roots.map(LibraryService.path)
    }

    /// Whether `folder` is a folder of Folders, or inside one.
    static func isInLibrary(_ folder: URL, roots: [URL]) -> Bool {
        let path = LibraryService.path(folder)
        return roots.map(LibraryService.path).contains { path == $0 || path.hasPrefix($0 == "/" ? $0 : $0 + "/") }
    }

    func panel(_: Any, validate url: URL) throws {
        guard Self.isInLibrary(url, roots: roots.map { URL(fileURLWithPath: $0, isDirectory: true) }) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "\(url.lastPathComponent) isn't in the library's folders",
                NSLocalizedRecoverySuggestionErrorKey: "Choose a folder in Folders, or one inside it.",
            ])
        }
    }
}
