import AppKit
import RedlampLibrary

/// Photo › Move to Folder… (LIB-26): a folder of the library chosen in an Open panel on the editor window, then the
/// photos selected moved there as one batch, each with its raw or JPEG pair, its sidecars and other apps' `.xmp`;
/// across volumes each file is copied and checked by size and SHA-256 before its original goes. The photos leave
/// the folders shown at once, the photo after them becoming active; the batch's progress shows in a sheet, and
/// Library's Undo puts them back, selected as they were.
public extension EditorModel {
    @discardableResult
    func moveToFolder() -> Bool {
        guard canRenamePhotos, let window = EditorWindowController.frontWindow, window.attachedSheet == nil else {
            return false
        }
        if let folder = MoveFolderPanel.answer {
            Task { await move(to: folder) }
            return true
        }
        let count = selectedPhotos.count
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move"
        panel.message = "Choose a folder in the library to move \(count == 1 ? "the photo" : "\(count) photos") to."
        panel.directoryURL = folder
        let delegate = MoveFolderPanel(roots: library.roots.map(\.url))
        panel.delegate = delegate
        isModalDialogOpen = true
        panel.beginSheetModal(for: window) { [self] response in
            MainActor.assumeIsolated {
                withExtendedLifetime(delegate) {}
                isModalDialogOpen = false
                guard response == .OK, let url = panel.url else { return }
                Task { await move(to: url) }
            }
        }
        return true
    }
}

extension EditorModel {
    /// Moves the photos selected into `folder` with the batch's progress in a sheet, and says in an alert why it
    /// didn't happen.
    private func move(to folder: URL) async {
        let sheet = FileProgressSheet.present("Moving to \(folder.lastPathComponent)", editor: self)
        let error = await moveSelection(to: folder) { sheet?.show($0) }
        sheet?.close()
        guard let error, let window = EditorWindowController.frontWindow else { return }
        let alert = NSAlert()
        alert.messageText = "The photos weren't moved to \(folder.lastPathComponent)"
        alert.informativeText = error
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    /// Moves the photos selected, with their pairs, into `folder`, as one batch, `progress` hearing of its steps;
    /// why it didn't happen, or nil once it has.
    @discardableResult
    func moveSelection(
        to folder: URL, progress: (@MainActor @Sendable (FileProgress) -> Void)? = nil,
    ) async -> String? {
        guard let service = library.service, let core = service.core, service.isReady else {
            return "The library isn't open"
        }
        guard MoveFolderPanel.isInLibrary(folder, roots: library.roots.map(\.url)) else {
            return "\(folder.lastPathComponent) isn't in the library's folders"
        }
        let urls = selectedPhotos
        let found = await LibraryService.indexIDs(of: urls, in: core.index)
        let ids = urls.compactMap { found[$0] }
        guard !ids.isEmpty else { return "The library hasn't read these photos yet" }
        let destination = LibraryService.path(folder)
        let indexed = await (try? core.index.read { reader in
            try LibraryService.folder(at: destination, in: reader)?.path
        }) ?? nil
        let target = indexed ?? destination
        let all = await (try? core.files.withPairs(ids)) ?? ids
        let before = await service.paths(of: all)
        let photos = all.compactMap { id -> (id: Int64, from: String, to: String)? in
            guard let path = before[id], (path as NSString).deletingLastPathComponent != target else { return nil }
            let name = (path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
            return (id, path, target + "/" + name)
        }
        guard !photos.isEmpty else { return nil }
        let count = Set(photos.map(\.id)).count
        let step = LibraryFileStep(
            kind: .move(ids, folder),
            title: "Move \(count) Photo\(count == 1 ? "" : "s") to \(folder.lastPathComponent)", photos: photos,
        )
        let relay = FileProgressRelay { progress?($0) }
        push(step)
        let run = await fileSteps.make { [self] in
            await perform(step, undoing: false) { await service.move(ids, to: folder) { relay.send($0) } }
        }
        if let error = run.error {
            activity.record(.error, "\(step.title) wasn't done: \(error)")
        } else {
            activity.record(.action, step.title)
        }
        return run.error
    }
}

/// What the Open panel lets Move to Folder choose: any folder to go through, and one in the library to move to.
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

/// A batch's progress, in a sheet on the editor window while it runs.
@MainActor
final class FileProgressSheet {
    private let window: NSWindow
    private let label: NSTextField
    private let bar = NSProgressIndicator()
    private weak var editor: EditorModel?

    private init(_ title: String, editor: EditorModel) {
        self.editor = editor
        label = NSTextField(labelWithString: title + "…")
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.setAccessibilityIdentifier("files.progress")
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 360).isActive = true
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 90), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.title = title
        window.contentView = stack
    }

    /// Shows the sheet, unless another is up.
    static func present(_ title: String, editor: EditorModel) -> FileProgressSheet? {
        guard let parent = EditorWindowController.frontWindow, parent.attachedSheet == nil else { return nil }
        let sheet = FileProgressSheet(title, editor: editor)
        editor.isModalDialogOpen = true
        parent.beginSheet(sheet.window)
        return sheet
    }

    func show(_ progress: FileProgress) {
        bar.doubleValue = progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0
        let doing = progress.isRollingBack ? "Putting back" : "Moving"
        label.stringValue = "\(doing): \(RenameModel.count(progress.done)) of \(RenameModel.count(progress.total)) steps"
    }

    func close() {
        editor?.isModalDialogOpen = false
        window.sheetParent?.endSheet(window)
    }
}
