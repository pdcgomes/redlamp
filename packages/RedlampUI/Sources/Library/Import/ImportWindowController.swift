import AppKit
import RedlampLibrary

/// File › Import Photos… (LIB-27): a window of its own, From and the photos (see `ImportWindowModel`),
/// and below them what's chosen. There's one at a time: asking again brings it forward; closed, it lets
/// its sources go.
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
    private let status = NSTextField(wrappingLabelWithString: "")

    init(model: ImportWindowModel) {
        self.model = model
        sourcesView = ImportSourcesViewController(model: model)
        grid = ImportGridViewController(
            model: model,
            thumbnails: model.library.store.map { ImportThumbnails(store: $0) },
        )
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
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func makeContent() -> NSView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        for view in [sourcesView.view, grid.view] {
            split.addArrangedSubview(view)
        }
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        sourcesView.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        grid.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        status.font = .systemFont(ofSize: 12)
        status.setAccessibilityIdentifier("import.summary")
        status.maximumNumberOfLines = 3
        let bar = NSStackView(views: [status])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = NSStackView(views: [split, NSBox.separator, bar])
        content.orientation = .vertical
        content.spacing = 0
        content.alignment = .width
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

    public func windowWillClose(_: Notification) {
        model.close()
        if Self.current === self {
            Self.current = nil
        }
    }

    // MARK: - The model

    private func changed(_ change: ImportWindowModel.Change) {
        sourcesView.modelChanged(change)
        grid.modelChanged(change)
        guard change == .status || change == .settings else { return }
        status.stringValue = model.summary
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
}

private extension NSBox {
    static var separator: NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
