import AppKit
import RedlampLibrary
import UniformTypeIdentifiers

/// File › Import from Lightroom Classic… (LIB-29): a window of its own that chooses a catalog, lists its root
/// folders with where each is now and Locate… for one that moved, shows the report of what would come across and
/// what wouldn't, and imports with progress and Stop, then offers Undo Import (`LightroomImportModel`). There's
/// one at a time: asking again brings it forward. Closing it while it imports lets the import carry on.
@MainActor
public final class LightroomWindowController: NSWindowController, NSWindowDelegate {
    public nonisolated static let title = "Import from Lightroom Classic"
    /// The window open now.
    @_spi(Harness) public private(set) static var current: LightroomWindowController?

    let model: LightroomImportModel
    private let catalogLabel = NSTextField(labelWithString: "No catalog chosen")
    private let chooseButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let roots = NSStackView()
    private let reportView = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let undoButton = NSButton(title: "Undo Import", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    /// The root folders' rows, by the paths the catalog gives them, for Locate….
    private var rootPaths: [Int: String] = [:]
    /// Closed while it imported, which carries on: the window goes once it's done.
    private var closedWhileBusy = false
    /// The report the roots and the text show, and whether the roots' Locate… buttons were enabled.
    private var shown: (report: LightroomReport?, locating: Bool)?

    init(model: LightroomImportModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false,
        )
        window.title = Self.title
        window.minSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
        window.setFrameAutosaveName("LightroomImportWindow")
        model.onChange = { [weak self] in self?.changed() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func makeContent() -> NSView {
        let heading = NSTextField(labelWithString: "Catalog")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        catalogLabel.lineBreakMode = .byTruncatingMiddle
        catalogLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        catalogLabel.setAccessibilityIdentifier("lightroom.catalog")
        chooseButton.target = self
        chooseButton.action = #selector(chooseCatalog)
        chooseButton.setAccessibilityIdentifier("lightroom.choose")
        let header = NSStackView(views: [heading, catalogLabel, chooseButton])
        header.orientation = .horizontal
        header.spacing = 8

        let rootsHeading = NSTextField(labelWithString: "Root folders")
        rootsHeading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        roots.orientation = .vertical
        roots.alignment = .leading
        roots.spacing = 6
        roots.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        roots.setAccessibilityIdentifier("lightroom.roots")
        roots.translatesAutoresizingMaskIntoConstraints = false
        let rootsContainer = FlippedView()
        rootsContainer.translatesAutoresizingMaskIntoConstraints = false
        rootsContainer.addSubview(roots)
        let rootsScroll = NSScrollView()
        rootsScroll.documentView = rootsContainer
        rootsScroll.hasVerticalScroller = true
        rootsScroll.autohidesScrollers = true
        rootsScroll.drawsBackground = false
        NSLayoutConstraint.activate([
            roots.topAnchor.constraint(equalTo: rootsContainer.topAnchor),
            roots.leadingAnchor.constraint(equalTo: rootsContainer.leadingAnchor),
            roots.trailingAnchor.constraint(equalTo: rootsContainer.trailingAnchor),
            roots.bottomAnchor.constraint(equalTo: rootsContainer.bottomAnchor),
            rootsContainer.widthAnchor.constraint(equalTo: rootsScroll.contentView.widthAnchor),
            rootsScroll.heightAnchor.constraint(lessThanOrEqualToConstant: 150),
            rootsScroll.heightAnchor.constraint(greaterThanOrEqualTo: rootsContainer.heightAnchor)
                .with(priority: .defaultHigh),
            rootsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])

        reportView.isEditable = false
        reportView.isSelectable = true
        reportView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        reportView.textContainerInset = NSSize(width: 6, height: 6)
        reportView.setAccessibilityIdentifier("lightroom.report")
        let scroll = NSScrollView()
        scroll.documentView = reportView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        reportView.autoresizingMask = [.width]
        reportView.isVerticallyResizable = true
        reportView.textContainer?.widthTracksTextView = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        status.font = .systemFont(ofSize: 12)
        status.maximumNumberOfLines = 3
        status.setAccessibilityIdentifier("lightroom.status")
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.widthAnchor.constraint(equalToConstant: 140).isActive = true
        for (button, action, identifier) in [
            (undoButton, #selector(undoImport), "lightroom.undo"), (
                stopButton,
                #selector(stopImport),
                "lightroom.stop",
            ),
            (importButton, #selector(startImport), "lightroom.import"),
        ] {
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(identifier)
        }
        importButton.keyEquivalent = "\r"
        let bar = NSStackView(views: [status, progress, undoButton, stopButton, importButton])
        bar.orientation = .horizontal
        bar.spacing = 10

        let line = NSBox()
        line.boxType = .separator
        let content = NSStackView(views: [header, rootsHeading, rootsScroll, scroll, line, bar])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        content.setCustomSpacing(4, after: rootsHeading)
        return content
    }

    // MARK: - Showing

    /// Brings the window forward, making it first for `editor` when there's none.
    static func show(editor: EditorModel) {
        if let current {
            current.closedWhileBusy = false
            current.showWindow(nil)
            current.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = LightroomWindowController(model: LightroomImportModel(editor: editor))
        current = controller
        controller.changed()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_: Notification) {
        guard Self.current === self else { return }
        if model.isBusy {
            closedWhileBusy = true
        } else {
            Self.current = nil
        }
    }

    // MARK: - The model

    private func changed() {
        catalogLabel.stringValue = model.catalogURL?.path ?? "No catalog chosen"
        if shown.map({ $0.report != model.report || $0.locating == model.isBusy }) ?? true {
            shown = (model.report, !model.isBusy)
            showRoots(model.report?.roots ?? [])
            reportView.string = model.report.map { $0.lines(roots: false).dropFirst().joined(separator: "\n") } ?? ""
        }
        status.stringValue = model.status
        chooseButton.isEnabled = !model.isBusy
        importButton.isEnabled = model.canImport
        importButton.title = model.phase == .imported ? "Import Again" : "Import"
        stopButton.isHidden = !(model.phase == .adding || model.phase == .importing || model.phase == .stopping)
        stopButton.isEnabled = model.phase != .stopping
        undoButton.isHidden = !model.canUndo && model.phase != .undoing
        undoButton.isEnabled = model.canUndo
        if let done = model.progress.map({ Double($0.done) / Double(max($0.total, 1)) })
            ?? model.indexed.map({ Double($0.done) / Double(max($0.total, 1)) }) {
            progress.isHidden = false
            progress.doubleValue = done
        } else {
            progress.isHidden = true
        }
        if closedWhileBusy, !model.isBusy, Self.current === self {
            Self.current = nil
        }
    }

    private func showRoots(_ list: [LightroomReport.Root]) {
        for view in roots.arrangedSubviews {
            roots.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rootPaths = [:]
        guard !list.isEmpty else {
            roots.addArrangedSubview(NSTextField(labelWithString: model.report == nil ? "—" : "None"))
            return
        }
        for (place, root) in list.enumerated() {
            let location = root.path.map { root.moved ? "\(root.lightroomPath) → \($0)" : $0 } ?? root.lightroomPath
            let label = NSTextField(labelWithString: location)
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let state = NSTextField(labelWithString: Self.describe(root))
            state.textColor = root.state == .missing || root.state == .offline ? .systemRed : .secondaryLabelColor
            state.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            let locate = NSButton(title: "Locate…", target: self, action: #selector(locateRoot(_:)))
            locate.tag = place
            locate.controlSize = .small
            locate.isEnabled = !model.isBusy
            locate.setAccessibilityIdentifier("lightroom.locate.\(place)")
            rootPaths[place] = root.lightroomPath
            let row = NSStackView(views: [label, state, locate])
            row.orientation = .horizontal
            row.spacing = 8
            roots.addArrangedSubview(row)
        }
    }

    static func describe(_ root: LightroomReport.Root) -> String {
        switch root.state {
        case .inLibrary: "In the library: \(LightroomImportModel.number(root.found)) of "
            + "\(LightroomImportModel.count(root.photos, "photo")) found"
        case .notInLibrary: "Not in the library yet: Import adds it (\(LightroomImportModel.count(root.photos, "photo")))"
        case .missing: "Not found: Locate… says where it is now"
        case .offline: "On a disk that isn’t connected: connect it, then import"
        }
    }

    // MARK: - Actions

    @objc private func chooseCatalog() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "lrcat") ?? .data]
        panel.prompt = "Choose"
        panel.message = "Choose a Lightroom Classic catalog, or a copy of one. It's read, never changed."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.model.choose(url)
        }
    }

    @objc private func locateRoot(_ sender: NSButton) {
        guard let window, let path = rootPaths[sender.tag] else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Locate"
        panel.message = "Where is this folder now? Lightroom Classic had it at \(path)."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.model.locate(path, at: url)
        }
    }

    @objc private func startImport() {
        model.startImport()
    }

    @objc private func stopImport() {
        model.stop()
    }

    @objc private func undoImport() {
        model.undo()
    }
}

/// The File menu's Import from Lightroom Classic….
@MainActor
enum LightroomActions {
    /// Opens the window, or brings it forward; false while the library isn't open.
    @discardableResult
    static func open(model: EditorModel) -> Bool {
        guard model.library.service?.isReady == true else { return false }
        LightroomWindowController.show(editor: model)
        return true
    }
}

/// A document view laid out from the top, as a list scrolls.
private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

private extension NSLayoutConstraint {
    func with(priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
