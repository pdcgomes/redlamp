import AppKit
import RedlampLibrary

/// Photo › Move to Folder… and Copy to Folder… (LIB-26): a folder of the library chosen in an Open panel on the editor
/// window, then the photos selected moved or copied there as one batch, each with its raw or JPEG pair, its sidecars
/// and other apps' `.xmp`; across volumes each file is copied and checked by size and SHA-256 before its original
/// goes. Moved, the photos leave the folders shown at once, the photo after them becoming active; copied, each copy
/// is a photo of its own, numbered where its name is held. The batch's progress shows in a sheet with Stop, and
/// Library's Undo puts the photos back, selected as they were, or moves the copies to the Trash.
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

    /// Moves or copies the photos selected into `folder` with the batch's progress and Stop in a sheet, and says in
    /// an alert why it didn't happen.
    private func place(in folder: URL, copying: Bool) async {
        let stop = FileStop()
        let doing = copying ? "Copying" : "Moving"
        let sheet = FileProgressSheet.present(doing, to: folder, editor: self, stop: stop)
        let error = await placeSelection(in: folder, copying: copying, progress: { sheet?.show($0) }, stop: stop)
        sheet?.close()
        guard let error, let window = EditorWindowController.frontWindow else { return }
        let alert = NSAlert()
        alert.messageText = "The photos weren't \(copying ? "copied" : "moved") to \(folder.lastPathComponent)"
        alert.informativeText = error
        alert.beginSheetModal(for: window, completionHandler: nil)
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
        in folder: URL, copying: Bool, progress: (@MainActor @Sendable (FileProgress) -> Void)?, stop: FileStop?,
    ) async -> String? {
        guard library.service?.isReady == true else { return "The library isn't open" }
        return await place(
            selectedIndexIDs(), in: folder, copying: copying, progress: progress, done: nil, stop: stop,
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

/// A batch's progress, in a sheet on the editor window while it runs, with Stop.
@MainActor
final class FileProgressSheet {
    private let window: NSWindow
    private let label: NSTextField
    private let bar = NSProgressIndicator()
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let stop: FileStop?
    /// What the batch does, "Moving", as the label says while it runs.
    private let doing: String
    private weak var editor: EditorModel?

    private init(_ doing: String, to folder: URL, editor: EditorModel, stop: FileStop?) {
        self.editor = editor
        self.stop = stop
        self.doing = doing
        let title = "\(doing) to \(folder.lastPathComponent)"
        label = NSTextField(labelWithString: title + "…")
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.setAccessibilityIdentifier("files.progress")
        stopButton.bezelStyle = .push
        stopButton.keyEquivalent = "\u{1b}"
        stopButton.isHidden = stop == nil
        stopButton.setAccessibilityIdentifier("files.stop")
        let buttons = NSStackView(views: [NSView(), stopButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [label, bar, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 360).isActive = true
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalToConstant: 360).isActive = true
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.title = title
        window.contentView = stack
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
    }

    /// Shows the sheet for a batch `doing` what it does to `folder`, unless another is up.
    static func present(
        _ doing: String, to folder: URL, editor: EditorModel, stop: FileStop? = nil,
    ) -> FileProgressSheet? {
        guard let parent = EditorWindowController.frontWindow, parent.attachedSheet == nil else { return nil }
        let sheet = FileProgressSheet(doing, to: folder, editor: editor, stop: stop)
        editor.isModalDialogOpen = true
        parent.beginSheet(sheet.window)
        return sheet
    }

    func show(_ progress: FileProgress) {
        bar.doubleValue = progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0
        let doing = progress.isRollingBack ? "Putting back" : stop?.isStopped == true ? "Stopping" : doing
        label.stringValue = "\(doing): \(RenameModel.count(progress.done)) of \(RenameModel.count(progress.total)) steps"
    }

    @objc private func stopClicked() {
        guard let stop, !stop.isStopped else { return }
        stop.stop()
        stopButton.isEnabled = false
        label.stringValue = "Stopping after the photo in hand…"
    }

    func close() {
        editor?.isModalDialogOpen = false
        window.sheetParent?.endSheet(window)
    }
}
