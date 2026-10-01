import AppKit
import RedlampDesign
import SwiftUI

/// The editor window. It is AppKit rather than a SwiftUI scene for the macOS 26 split view
/// (see `EditorSplitViewController`): the panels overlay the canvas instead of squeezing
/// it, and the toolbar's tracking separators put each panel's buttons in its own titlebar
/// section, which SwiftUI's split views don't offer.
@MainActor
public final class EditorWindowController: NSWindowController, NSToolbarDelegate {
    private let model: EditorModel
    private let theme: ThemeSettings
    private let onOpen: () -> Void
    private let onExport: () -> Void
    private var trackers: [Tracker] = []
    private weak var exportItem: NSToolbarItem?
    private weak var viewGroup: NSToolbarItemGroup?
    private lazy var themePopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ThemePopover(theme: theme))
        return popover
    }()

    public init(
        model: EditorModel, theme: ThemeSettings,
        onOpen: @escaping () -> Void, onExport: @escaping () -> Void,
        onExportWithPrevious: @escaping () -> Void,
    ) {
        self.model = model
        self.theme = theme
        self.onOpen = onOpen
        self.onExport = onExport

        let content = NSHostingController(rootView: EditorContentView(model: model, theme: theme, onOpen: onOpen))
        content.sizingOptions = []
        let split = EditorSplitViewController(model: model, theme: theme, content: content)
        let root = EditorRootViewController(
            split: split,
            overlays: EditorOverlays(
                model: model, theme: theme,
                onOpen: onOpen, onExport: onExport, onExportWithPrevious: onExportWithPrevious,
            ),
        )

        let window = RinglessWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false,
        )
        window.contentViewController = root
        window.contentMinSize = CGSize(width: 1100, height: 700)
        window.setContentSize(CGSize(width: 1600, height: 1000))
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName("Redlamp Editor")
        super.init(window: window)

        let toolbar = NSToolbar(identifier: "Editor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        startTracking(root: root)

        // The window starts focused on its own content rather than the first toolbar button.
        window.initialFirstResponder = root.view
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func startTracking(root: EditorRootViewController) {
        trackers = [
            Tracker { [weak self] in
                guard let self, let window else { return }
                window.title = model.info?.fileName ?? "Redlamp"
                window.subtitle = model.info?.cameraName ?? ""
            },
            Tracker { [weak self] in
                guard let self else { return }
                window?.appearance = NSAppearance(named: theme.selection.appearance == .dark ? .darkAqua : .aqua)
            },
            Tracker { [weak self] in
                guard let self else { return }
                exportItem?.isEnabled = model.info != nil
                viewGroup?.setSelected(model.showBefore, at: 0)
                viewGroup?.setSelected(model.filmstripVisible, at: 1)
                viewGroup?.subitems.first?.image = Self.symbol(model.compareLayout.symbol, "Before / After")
            },
            Tracker { [weak self] in
                guard let self else { return }
                root.showsOverlays = model.showShortcuts || model.commandPalette != nil
            },
        ]
    }

    // MARK: - Toolbar

    public func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar, .sidebarTrackingSeparator,
            .flexibleSpace, .openFolder, .export, .space, .view,
            .inspectorTrackingSeparator,
            .theme, .flexibleSpace, .toggleInspector,
        ]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(
        _: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar _: Bool,
    ) -> NSToolbarItem? {
        switch identifier {
        case .openFolder:
            return button(identifier, "Open Folder", "folder", help: "Open Folder (⌘O)", action: #selector(openFolder))
        case .export:
            let item = button(
                identifier,
                "Export",
                "square.and.arrow.up",
                help: "Export (⇧⌘E)",
                action: #selector(export),
            )
            item.autovalidates = false
            item.isEnabled = model.info != nil
            exportItem = item
            return item
        case .view:
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: [
                    Self.symbol(model.compareLayout.symbol, "Before / After"),
                    Self.symbol("film.stack", "Filmstrip"),
                ],
                selectionMode: .selectAny,
                labels: ["Before / After", "Filmstrip"],
                target: self,
                action: #selector(viewGroupChanged(_:)),
            )
            group.subitems[0].toolTip = "Before / After (\\)"
            group.subitems[1].toolTip = "Show Filmstrip"
            group.setSelected(model.showBefore, at: 0)
            group.setSelected(model.filmstripVisible, at: 1)
            viewGroup = group
            return group
        case .theme:
            return button(identifier, "Theme", "paintpalette", help: "Theme", action: #selector(showTheme(_:)))
        default:
            return nil
        }
    }

    private func button(
        _ identifier: NSToolbarItem.Identifier, _ label: String, _ symbol: String, help: String, action: Selector,
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.image = Self.symbol(symbol, label)
        item.toolTip = help
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    private static func symbol(_ name: String, _ description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
    }

    /// The toolbar's system Sidebar and Inspector toggles send these up the responder chain,
    /// which reaches the window controller but not the split view controller when nothing in
    /// it has focus. The model drives the panels.
    @objc func toggleSidebar(_: Any?) {
        model.leftPanelVisible.toggle()
    }

    @objc func toggleInspector(_: Any?) {
        model.rightPanelVisible.toggle()
    }

    @objc private func openFolder() {
        onOpen()
    }

    @objc private func export() {
        onExport()
    }

    @objc private func viewGroupChanged(_ group: NSToolbarItemGroup) {
        model.showBefore = group.isSelected(at: 0)
        model.filmstripVisible = group.isSelected(at: 1)
    }

    @objc private func showTheme(_ item: NSToolbarItem) {
        if themePopover.isShown {
            themePopover.close()
        } else {
            themePopover.show(relativeTo: item)
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let openFolder = Self("openFolder")
    static let export = Self("export")
    static let view = Self("view")
    static let theme = Self("theme")
}

/// The window's content: the split view, and the ⌘/ and ⌘K overlays above it, which must
/// cover the panels too. The overlays' view is only in the window while one is showing, so
/// it never takes clicks meant for the canvas or the panels.
private final class EditorRootViewController: NSViewController {
    private let split: NSSplitViewController
    private let overlays: NSHostingView<EditorOverlays>

    var showsOverlays = false {
        didSet {
            guard showsOverlays != oldValue else { return }
            if showsOverlays {
                overlays.frame = view.bounds
                view.addSubview(overlays)
            } else {
                overlays.removeFromSuperview()
                // The palette's field had focus: hand it back to the window's own view, so
                // single-key shortcuts work again straight away.
                view.window?.makeFirstResponder(view)
            }
        }
    }

    init(split: NSSplitViewController, overlays: EditorOverlays) {
        self.split = split
        self.overlays = NSHostingView(rootView: overlays)
        self.overlays.autoresizingMask = [.width, .height]
        self.overlays.sizingOptions = []
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = FocusRootView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        addChild(split)
        split.view.frame = view.bounds
        split.view.autoresizingMask = [.width, .height]
        view.addSubview(split.view)
    }
}

/// The window's own first responder at launch: it takes focus without drawing anything, so
/// no control starts out focused. Keys still reach the shortcut monitor and the menus.
private final class FocusRootView: NSView {
    override var acceptsFirstResponder: Bool {
        true
    }
}

private struct ThemePopover: View {
    @Bindable var theme: ThemeSettings

    var body: some View {
        ThemeControls(theme: $theme.selection, transparency: $theme.panelTransparency)
            .padding(14)
            .frame(width: 260)
            .focusEffectDisabled()
    }
}
