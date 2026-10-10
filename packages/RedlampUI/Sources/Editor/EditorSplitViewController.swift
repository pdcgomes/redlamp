import AppKit
import RedlampDesign
import SwiftUI

/// The editor's three columns, on AppKit's macOS 26 split view: a floating sidebar, the
/// canvas, and an inspector. The canvas item lets both panels overlay it
/// (`automaticallyAdjustsSafeAreaInsets`), so it always spans the whole window and showing,
/// hiding or resizing a panel never resizes it; the toolbar's tracking separators give
/// each panel its own titlebar section for its buttons.
final class EditorSplitViewController: NSSplitViewController {
    private let model: EditorModel
    private let content: NSViewController
    private let sidebarItem: NSSplitViewItem
    private let inspectorItem: NSSplitViewItem
    private var tracker: Tracker?
    private var observations: [NSKeyValueObservation] = []
    private var pointer: PanelPointer?

    init(model: EditorModel, theme: ThemeSettings, content: NSViewController) {
        self.model = model
        self.content = content
        sidebarItem = NSSplitViewItem(sidebarWithViewController: PaneViewController(
            model: model, theme: theme, width: PanelMetrics.sidebarNominal,
        ) {
            if DevelopPanels.usesSwiftUI {
                NSHostingView(rootView: SidebarView().environment(model).environment(theme).focusEffectDisabled())
            } else {
                SidebarColumnView(model: model)
            }
        })
        sidebarItem.minimumThickness = PanelMetrics.sidebarRange.lowerBound
        sidebarItem.maximumThickness = PanelMetrics.sidebarRange.upperBound
        sidebarItem.canCollapseFromWindowResize = false

        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.automaticallyAdjustsSafeAreaInsets = true

        inspectorItem = NSSplitViewItem(inspectorWithViewController: PaneViewController(
            model: model, theme: theme, width: PanelMetrics.inspectorNominal,
        ) {
            if DevelopPanels.usesSwiftUI {
                NSHostingView(rootView: InspectorView().environment(model).environment(theme).focusEffectDisabled())
            } else {
                InspectorColumnView(model: model)
            }
        })
        inspectorItem.minimumThickness = PanelMetrics.inspectorRange.lowerBound
        inspectorItem.maximumThickness = PanelMetrics.inspectorRange.upperBound
        inspectorItem.canCollapseFromWindowResize = false

        super.init(nibName: nil, bundle: nil)
        splitViewItems = [sidebarItem, contentItem, inspectorItem]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sidebarItem.isCollapsed = !model.leftPanelVisible
        inspectorItem.isCollapsed = !model.rightPanelVisible
        // The model's visibility drives the items; the toolbar toggles and divider drags
        // collapse the items directly, and are written back.
        tracker = Tracker { [weak self] in
            guard let self else { return }
            setCollapsed(sidebarItem, !model.leftPanelVisible)
            setCollapsed(inspectorItem, !model.rightPanelVisible)
        }
        observations = [
            sidebarItem.observe(\.isCollapsed) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.sidebarCollapsedChanged() }
            },
            inspectorItem.observe(\.isCollapsed) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.inspectorCollapsedChanged() }
            },
        ]
        pointer = PanelPointer(model: model, tracking: view, canvas: content.view)
    }

    /// Each item writes back only its own state: the other may be mid-way through a change
    /// the model has already made.
    private func sidebarCollapsedChanged() {
        if model.leftPanelVisible == sidebarItem.isCollapsed {
            model.leftPanelVisible = !sidebarItem.isCollapsed
        }
    }

    private func inspectorCollapsedChanged() {
        if model.rightPanelVisible == inspectorItem.isCollapsed {
            model.rightPanelVisible = !inspectorItem.isCollapsed
        }
    }

    /// Slides the panel only while the window can be seen: behind other windows or on a display that
    /// sleeps, the slide doesn't advance, and a panel shown again stays where it slides in from, off the
    /// window, while the item and the model say it's showing.
    private func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool) {
        guard item.isCollapsed != collapsed else { return }
        if view.window?.occlusionState.contains(.visible) == true {
            item.animator().isCollapsed = collapsed
        } else {
            item.isCollapsed = collapsed
        }
    }
}

/// A panel column: its AppKit content below the toolbar, over the system's glass, washed
/// with the theme's panel color as far as the theme's transparency setting allows (at 0 %
/// the photo sliding beneath a zoomed-in canvas can't tint the panels). Lights Out shades
/// it. A theme change rebuilds the content, since AppKit views take their colors when they
/// are made.
private final class PaneViewController: NSViewController {
    private let model: EditorModel
    private let theme: ThemeSettings
    private let width: CGFloat
    private let makeContent: @MainActor () -> NSView
    private var content: NSView?
    private var shownTheme: ThemeSelection?
    private let shade = ShadeView()
    private var trackers: [Tracker] = []

    init(model: EditorModel, theme: ThemeSettings, width: CGFloat, content: @escaping @MainActor () -> NSView) {
        self.model = model
        self.theme = theme
        self.width = width
        makeContent = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        // The split view takes a panel's first width from its view.
        let view = NSView(frame: CGRect(x: 0, y: 0, width: width, height: 600))
        view.wantsLayer = true
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.cgColor
        shade.alphaValue = 0
        shade.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shade)
        NSLayoutConstraint.activate([
            shade.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shade.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            shade.topAnchor.constraint(equalTo: view.topAnchor),
            shade.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyTheme()
        trackers = [
            // Watches only the theme: building the content reads model state, which must
            // not rebuild the panel when it changes.
            Tracker { [weak self] in
                guard let self, theme.selection != shownTheme else { return }
                Task { @MainActor in self.applyTheme() }
            },
            Tracker { [weak self] in
                guard let self else { return }
                _ = theme.selection
                view.layer?.backgroundColor = Palette.panelBackground.opacity(theme.panelOpacity).nsColor.cgColor
            },
            Tracker { [weak self] in
                guard let self else { return }
                let level = model.lightsOut
                shade.blocksClicks = level == 2
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    shade.animator().alphaValue = level == 0 ? 0 : level == 1 ? 0.8 : 1
                }
            },
        ]
    }

    private func applyTheme() {
        shownTheme = theme.selection
        content?.removeFromSuperview()
        let next = makeContent()
        next.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(next, positioned: .below, relativeTo: shade)
        NSLayoutConstraint.activate([
            next.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            next.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            next.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            next.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        content = next
    }
}

/// Lights Out's shade over a panel. Dimmed (level 1) the panel still works; blacked out
/// (level 2) it takes no clicks. Transparent, it must not take them either: AppKit hit-tests
/// a view whatever its alpha.
private final class ShadeView: NSView {
    var blocksClicks = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        blocksClicks ? super.hitTest(point) : nil
    }
}

/// Keeps `EditorModel.pointerOverPanel`: whether the window's hit test finds a panel or the
/// toolbar under the pointer, rather than the canvas. AppKit reports the pointer to every
/// tracking area it's in, whatever covers the area's view, so the canvas's own hovers can't tell.
private final class PanelPointer: NSResponder {
    private let model: EditorModel
    private weak var canvas: NSView?

    init(model: EditorModel, tracking view: NSView, canvas: NSView) {
        self.model = model
        self.canvas = canvas
        super.init()
        view.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self,
        ))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseEntered(with event: NSEvent) {
        update(event)
    }

    override func mouseMoved(with event: NSEvent) {
        update(event)
    }

    override func mouseExited(with _: NSEvent) {
        set(false)
    }

    private func update(_ event: NSEvent) {
        guard let canvas, let frame = canvas.window?.contentView?.superview,
              let hit = frame.hitTest(event.locationInWindow) else { return }
        // Where nothing on the canvas takes the point, the hit test finds a view holding it.
        set(!hit.isDescendant(of: canvas) && !canvas.isDescendant(of: hit))
    }

    private func set(_ over: Bool) {
        if model.pointerOverPanel != over {
            model.pointerOverPanel = over
        }
    }
}
