import AppKit
import RedlampLibrary

/// File › Import Photos… (LIB-27): a window of its own in three columns, From, the photos and To (see
/// `ImportWindowModel`), and below them what's chosen and how the import is going, with Import, Cancel,
/// Resume and Roll Back. There's one at a time: asking again brings it forward. Closing it while it copies
/// or rolls back lets that carry on, and asking again shows it; closed otherwise, it lets its sources go.
@MainActor
public final class ImportWindowController: NSWindowController, NSWindowDelegate {
    public nonisolated static let title = "Import Photos"
    /// The window open now.
    @_spi(Harness) public private(set) static var current: ImportWindowController?

    /// Leaves this Mac's volumes alone, for the regression suite: no card is listed or heard of.
    @_spi(Harness) public static var ignoresVolumes: Bool {
        get { ImportCards.ignoresVolumes }
        set { ImportCards.ignoresVolumes = newValue }
    }

    let model: ImportWindowModel
    let sourcesView: ImportSourcesViewController
    let grid: ImportGridViewController
    let destinationView: ImportDestinationViewController
    private let status = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel Import", target: nil, action: nil)
    private let resumeButton = NSButton(title: "Resume", target: nil, action: nil)
    private let rollBackButton = NSButton(title: "Roll Back", target: nil, action: nil)
    private let progress = NSProgressIndicator()

    init(model: ImportWindowModel) {
        self.model = model
        sourcesView = ImportSourcesViewController(model: model)
        grid = ImportGridViewController(
            model: model,
            thumbnails: model.library.store.map { ImportThumbnails(store: $0) },
        )
        destinationView = ImportDestinationViewController(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false,
        )
        window.title = Self.title
        window.minSize = NSSize(width: 860, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
        window.setFrameAutosaveName("ImportWindow")
        model.onChange = { [weak self] change in self?.changed(change) }
        sourcesView.onAddFolder = { [weak self] in self?.askForFolder() }
        destinationView.onChooseFolder = { [weak self] backup in self?.askForDestination(backup: backup) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func makeContent() -> NSView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        for view in [sourcesView.view, grid.view, destinationView.view] {
            split.addArrangedSubview(view)
        }
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 2)
        sourcesView.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        grid.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        destinationView.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        status.font = .systemFont(ofSize: NSFont.systemFontSize)
        status.textColor = .secondaryLabelColor
        status.setAccessibilityIdentifier("import.summary")
        status.maximumNumberOfLines = 3
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        importButton.target = self
        importButton.action = #selector(importChosen)
        importButton.keyEquivalent = "\r"
        importButton.setAccessibilityIdentifier("import.import")
        cancelButton.target = self
        cancelButton.action = #selector(cancelImport)
        cancelButton.setAccessibilityIdentifier("import.cancel")
        resumeButton.target = self
        resumeButton.action = #selector(resume)
        resumeButton.setAccessibilityIdentifier("import.resume")
        rollBackButton.target = self
        rollBackButton.action = #selector(rollBack)
        rollBackButton.setAccessibilityIdentifier("import.roll-back")
        rollBackButton.toolTip = "Moves the copies the import made to the Trash, takes its photos out of the library "
            + "and removes the folders it made"
        for button in [rollBackButton, resumeButton, cancelButton, importButton] {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: PanelSheet.Layout.buttonWidth).isActive = true
        }
        let bar = NSStackView(views: [status, progress, rollBackButton, resumeButton, cancelButton, importButton])
        bar.orientation = .horizontal
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 14, right: 16)
        // The line takes the bar's room, so the buttons stay at its trailing edge.
        status.setContentHuggingPriority(.init(1), for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let separator = NSBox.separator
        let content = NSStackView(views: [split, separator, bar])
        content.orientation = .vertical
        content.spacing = 0
        content.alignment = .leading
        // A stack view leaves its views their width: these take the window's, however it's resized.
        for view in [split, separator, bar] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        return content
    }

    // MARK: - Showing

    /// Brings the window forward, making it first with `library` when there's none.
    static func show(
        library: @escaping @MainActor () async -> ImportLibrary,
        adding source: ImportSource? = nil,
        configure: @escaping @MainActor (ImportWindowModel) -> Void = { _ in },
    ) {
        if let current {
            if let source {
                current.model.add(source)
                current.model.show(source.id)
            }
            current.showWindow(nil)
            current.window?.makeKeyAndOrderFront(nil)
            return
        }
        Task {
            let model = await ImportWindowModel(library: library())
            guard current == nil else {
                show(library: library, adding: source, configure: configure)
                return
            }
            configure(model)
            let controller = ImportWindowController(model: model)
            self.current = controller
            model.start()
            if let source {
                model.add(source)
                model.show(source.id)
            }
            controller.changed(.status)
            controller.changed(.sources)
            controller.changed(.settings)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.window?.makeFirstResponder(controller.grid.collectionView)
        }
    }

    /// Presets made or changed in Library's Metadata panel meanwhile are offered.
    public func windowDidBecomeKey(_: Notification) {
        Task { await model.readPresets() }
    }

    public func windowWillClose(_: Notification) {
        guard !model.isBusy else { return }
        model.close()
        if Self.current === self {
            Self.current = nil
        }
    }

    // MARK: - The model

    private func changed(_ change: ImportWindowModel.Change) {
        sourcesView.modelChanged(change)
        grid.modelChanged(change)
        destinationView.modelChanged(change)
        guard change == .status || change == .settings else { return }
        status.stringValue = model.summary
        let blocker = model.importBlocker
        importButton.isEnabled = blocker == nil
        importButton.toolTip = blocker
        importButton.title = model.phase == .finished ? "Import Again" : "Import"
        cancelButton.isHidden = !model.isBusy
        cancelButton.title = model.phase == .rollingBack ? "Stop Rolling Back" : "Cancel Import"
        resumeButton.isHidden = model.interrupted.isEmpty || model.isBusy
        rollBackButton.isHidden = model.rollBackTarget == nil || model.isBusy
        if model.phase == .copying, let progress = model.progress, progress.photos > 0 {
            self.progress.isHidden = false
            self.progress.doubleValue = Double(progress.done + progress.failed) / Double(progress.photos)
        } else if model.phase == .rollingBack, let progress = model.rollbackProgress, progress.photos > 0 {
            self.progress.isHidden = false
            self.progress.doubleValue = Double(progress.done) / Double(progress.photos)
        } else {
            progress.isHidden = true
        }
        if model.phase == .finished, window?.isVisible != true, Self.current === self {
            model.close()
            Self.current = nil
        }
    }

    /// Import, which asks where the photos go first while no destination is chosen.
    @objc private func importChosen() {
        window?.makeFirstResponder(grid.collectionView)
        guard model.hasDestination else {
            askForDestination(backup: false) { [weak self] in self?.model.startImport() }
            return
        }
        model.startImport()
    }

    @objc private func cancelImport() {
        model.cancel()
    }

    @objc private func resume() {
        model.resume()
    }

    @objc private func rollBack() {
        model.rollBack()
    }

    // MARK: - Folders

    private func askForFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders of photos to import from."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            for url in panel.urls {
                Task { try? await self.model.addFolder(url) }
            }
        }
    }

    /// The destination's or the backup's panel; `chosen` runs once one is chosen.
    private func askForDestination(backup: Bool, then chosen: @escaping @MainActor () -> Void = {}) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = backup ? "Choose where the backup copies go." : "Choose where the photos are copied to."
        panel.directoryURL = backup ? model.settings.backup : model.settings.destination
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                changed(.settings)
                return
            }
            if backup {
                model.setBackup(url)
            } else {
                model.setDestination(url)
            }
            chosen()
        }
    }
}

private extension NSBox {
    static var separator: NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
