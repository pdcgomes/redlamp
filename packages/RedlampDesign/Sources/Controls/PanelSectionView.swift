import AppKit

/// A collapsible Develop panel: a header (chevron, title, optional badge, and a dot when
/// the panel has edits), its rows, and a divider.
///
/// Click the header to expand or collapse (Option-click for Solo Mode), double-click to
/// reset the panel. A collapsed panel's rows leave the window, so they cost nothing.
public final class PanelSectionView: NSView, HeightProviding {
    public struct Actions {
        public var isExpanded: @MainActor () -> Bool
        public var isEdited: @MainActor () -> Bool
        public var toggle: @MainActor (_ solo: Bool) -> Void
        public var reset: @MainActor () -> Void

        public init(
            isExpanded: @escaping @MainActor () -> Bool,
            isEdited: @escaping @MainActor () -> Bool,
            toggle: @escaping @MainActor (_ solo: Bool) -> Void,
            reset: @escaping @MainActor () -> Void,
        ) {
            self.isExpanded = isExpanded
            self.isEdited = isEdited
            self.toggle = toggle
            self.reset = reset
        }
    }

    private let header: PanelHeaderView
    private let body: ColumnView
    private let divider = DividerView()
    private let actions: Actions
    private var trackers: [Tracker] = []
    private(set) var isExpanded = false

    public init(title: String, badge: String? = nil, rows: [NSView], actions: Actions) {
        header = PanelHeaderView(title: title, badge: badge)
        body = ColumnView(
            spacing: Metrics.panelRowSpacing,
            insets: NSEdgeInsets(
                top: 0,
                left: Metrics.panelPadding,
                bottom: Metrics.panelBottomPadding,
                right: Metrics.panelPadding,
            ),
            views: rows,
        )
        self.actions = actions
        super.init(frame: CGRect(x: 0, y: 0, width: 316, height: Metrics.panelHeaderHeight))
        wantsLayer = true
        clipsToBounds = true
        addSubview(header)
        addSubview(divider)
        header.onClick = { [weak self] solo in self?.actions.toggle(solo) }
        header.onDoubleClick = {
            // The first click already toggled the panel; put it back, then reset.
            actions.toggle(false)
            actions.reset()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public var isFlipped: Bool {
        true
    }

    /// Replaces the panel's rows (a panel whose content depends on a mode).
    public func setRows(_ rows: [NSView]) {
        body.setArrangedViews(rows)
        invalidateColumnLayout()
    }

    /// Builds the header's right-click menu when it opens.
    public var headerMenu: (@MainActor () -> NSMenu)? {
        get { header.menuProvider }
        set { header.menuProvider = newValue }
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        Metrics.panelHeaderHeight + (isExpanded ? body.height(forWidth: width) : 0) + 1
    }

    override public var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width))
    }

    override public func layout() {
        super.layout()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Metrics.panelHeaderHeight)
        let bodyHeight = isExpanded ? body.height(forWidth: bounds.width) : 0
        body.frame = CGRect(x: 0, y: Metrics.panelHeaderHeight, width: bounds.width, height: bodyHeight)
        divider.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackers.forEach { $0.cancel() }
        trackers = []
        guard window != nil else { return }
        trackers = [
            Tracker { [weak self] in
                guard let self else { return }
                setExpanded(actions.isExpanded())
            },
            Tracker { [weak self] in
                guard let self else { return }
                header.isEdited = actions.isEdited()
            },
        ]
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded || (expanded && body.superview == nil) else { return }
        let animated = window != nil && isExpanded != expanded && header.hasBeenDisplayed
        isExpanded = expanded
        header.isExpanded = expanded
        if expanded {
            if body.superview == nil {
                addSubview(body, positioned: .below, relativeTo: divider)
            }
            body.alphaValue = animated ? 0 : 1
        }
        invalidateColumnLayout()
        guard animated else {
            if !expanded {
                body.removeFromSuperview()
            }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            body.animator().alphaValue = expanded ? 1 : 0
            enclosingColumnHost?.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isExpanded else { return }
                self.body.removeFromSuperview()
            }
        }
    }

    private var enclosingColumnHost: NSView? {
        var view = superview
        while let current = view {
            if current is ColumnHost {
                return current
            }
            view = current.superview
        }
        return superview
    }
}

/// The panel title bar.
final class PanelHeaderView: NSView {
    let title: String
    let badge: String?
    var onClick: (_ solo: Bool) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var menuProvider: (@MainActor () -> NSMenu)?
    private(set) var hasBeenDisplayed = false

    override func menu(for _: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    var isExpanded = false {
        didSet {
            if isExpanded != oldValue {
                needsDisplay = true
            }
        }
    }

    var isEdited = false {
        didSet {
            if isEdited != oldValue {
                needsDisplay = true
            }
        }
    }

    private var isHovering = false {
        didSet {
            if isHovering != oldValue {
                needsDisplay = true
            }
        }
    }

    private var hoverArea: NSTrackingArea?

    init(title: String, badge: String?) {
        self.title = title
        self.badge = badge
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_: NSRect) {
        hasBeenDisplayed = true
        let scale = backingScale
        var x = Metrics.panelPadding
        let midY = bounds.height / 2

        // Turned about its frame's center, as SwiftUI's `rotationEffect` does.
        let chevron = Symbol.layoutSize("chevron.right", pointSize: 9, weight: .bold)
        Symbol.draw(
            "chevron.right", pointSize: 9, weight: .bold, color: Palette.secondaryLabel,
            centeredAt: CGPoint(x: x + chevron.width / 2, y: midY), rotation: isExpanded ? 90 : 0, scale: scale,
        )
        x += chevron.width + 8

        let titleWidth = TextLine.width(title, font: Typography.panelTitle)
        TextLine.draw(
            title, font: Typography.panelTitle,
            color: (isHovering ? Palette.labelHover : Palette.value).nsColor,
            in: CGRect(x: x, y: 0, width: titleWidth, height: bounds.height), scale: scale,
        )
        x += titleWidth + 8

        if let badge {
            let textWidth = TextLine.width(badge, font: Typography.badge)
            let height = TextLine.lineHeight(Typography.badge) + 2
            let capsule = CGRect(x: x, y: midY - height / 2, width: textWidth + 10, height: height)
            Palette.selection.nsColor.setFill()
            NSBezierPath(roundedRect: capsule, xRadius: height / 2, yRadius: height / 2).fill()
            TextLine.draw(
                badge, font: Typography.badge, color: Palette.secondaryLabel.nsColor,
                in: capsule.insetBy(dx: 5, dy: 0), scale: scale,
            )
        }

        if isEdited {
            Palette.editedDot.nsColor.setFill()
            NSBezierPath(ovalIn: CGRect(x: bounds.width - Metrics.panelPadding - 4, y: midY - 2, width: 4, height: 4))
                .fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with _: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick()
        } else if event.clickCount == 1 {
            onClick(event.modifierFlags.contains(.option))
        }
    }
}

/// A one-point hairline in the divider color.
public final class DividerView: NSView {
    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override public func draw(_: NSRect) {
        Palette.divider.nsColor.setFill()
        bounds.fill(using: .sourceOver)
    }
}
