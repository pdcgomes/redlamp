import AppKit

/// A collapsible panel: a header (chevron, glyph, title, optional badge, then at the trailing
/// edge an Edited chip when the panel has edits and, for a Develop panel that can be turned off, an eye),
/// its rows, and a divider, or in the card style a card of its own.
///
/// Click the header to expand or collapse (Option-click for Solo Mode), double-click to
/// reset the panel. Clicking the eye turns the panel off or on without expanding it; while
/// it's off, its title and rows are dimmed and stay usable. A collapsed panel's rows leave the
/// window, so they cost nothing.
public final class PanelSectionView: NSView, HeightProviding {
    public struct Actions {
        public var isExpanded: @MainActor () -> Bool
        public var isEdited: @MainActor () -> Bool
        public var toggle: @MainActor (_ solo: Bool) -> Void
        public var reset: @MainActor () -> Void
        /// Whether the panel is on, for a panel with an eye.
        public var isOn: (@MainActor () -> Bool)?
        public var setOn: (@MainActor (Bool) -> Void)?

        public init(
            isExpanded: @escaping @MainActor () -> Bool,
            isEdited: @escaping @MainActor () -> Bool,
            toggle: @escaping @MainActor (_ solo: Bool) -> Void,
            reset: @escaping @MainActor () -> Void,
            isOn: (@MainActor () -> Bool)? = nil,
            setOn: (@MainActor (Bool) -> Void)? = nil,
        ) {
            self.isExpanded = isExpanded
            self.isEdited = isEdited
            self.toggle = toggle
            self.reset = reset
            self.isOn = isOn
            self.setOn = setOn
        }
    }

    /// How a panel sits in its column.
    public enum Style: Sendable {
        /// The column's full width, with a divider under it: the left column's panels.
        case plain
        /// A card with rounded corners, a fill a step above the column and a hairline edge, which
        /// the column insets and spaces (`cardColumnInsets`): the Develop panels.
        case card
    }

    private let header: PanelHeaderView
    private let body: ColumnView
    private let divider = DividerView()
    private let actions: Actions
    private let style: Style
    private var trackers: [Tracker] = []
    private(set) var isExpanded = false
    private(set) var isOn = true

    /// The rows' padding inside a panel.
    public static let bodyInsets = NSEdgeInsets(
        top: 0, left: Metrics.panelPadding, bottom: Metrics.panelBottomPadding, right: Metrics.panelPadding,
    )

    /// The margin a column of cards leaves around them; `Metrics.panelCardGap` goes between them.
    public static let cardColumnInsets = NSEdgeInsets(
        top: Metrics.panelCardGap, left: Metrics.panelCardMargin, bottom: Metrics.panelCardMargin,
        right: Metrics.panelCardMargin,
    )

    /// `accessory` (a button) sits at the header's trailing edge. Rows that pad themselves (a
    /// list whose highlight reaches past its text) can be given other `insets`; in a card, the
    /// rows' sides come in as its padding does. With `eyeSlot`, a header without an eye keeps
    /// its room, so the Edited chips of a column line up.
    public init(
        title: String,
        symbol: String? = nil,
        badge: String? = nil,
        accessory: NSView? = nil,
        style: Style = .plain,
        eyeSlot: Bool = false,
        insets: NSEdgeInsets = PanelSectionView.bodyInsets,
        rows: [NSView],
        actions: Actions,
    ) {
        let eye = actions.isOn.map { _ in
            PanelEyeView(title: title) { on in actions.setOn?(on) }
        }
        let padding = style == .card ? Metrics.panelCardPadding : Metrics.panelPadding
        header = PanelHeaderView(
            title: title, symbol: symbol, badge: badge, accessory: accessory, eye: eye,
            eyeSlot: eyeSlot || eye != nil, padding: padding, highlightsOnHover: style == .card,
        )
        var insets = insets
        if style == .card {
            let narrower = Metrics.panelPadding - Metrics.panelCardPadding
            insets.left = max(0, insets.left - narrower)
            insets.right = max(0, insets.right - narrower)
        }
        body = ColumnView(spacing: Metrics.panelRowSpacing, insets: insets, views: rows)
        self.actions = actions
        self.style = style
        super.init(frame: CGRect(x: 0, y: 0, width: 316, height: Metrics.panelHeaderHeight))
        wantsLayer = true
        clipsToBounds = true
        addSubview(header)
        if style == .card {
            layer?.cornerRadius = Metrics.panelCardRadius
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = Palette.card.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = Palette.divider.cgColor
        } else {
            addSubview(divider)
        }
        alignValueColumn()
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

    #if DEBUG || REDLAMP_PROFILING
        /// Draws the headers' Edited chips in capitals, for comparing in snapshots (`--script chip=upper`).
        public static var uppercaseEditedChip: Bool {
            get { PanelHeaderView.uppercaseEditedChip }
            set { PanelHeaderView.uppercaseEditedChip = newValue }
        }
    #endif

    /// Names the section, its header and its eye for VoiceOver and the regression suite, such as
    /// `panel.detail`, `panel.detail.header` and `panel.detail.switch`.
    public func identify(as identifier: String) {
        setAccessibilityIdentifier(identifier)
        header.setAccessibilityIdentifier("\(identifier).header")
        header.eye?.setAccessibilityIdentifier("\(identifier).switch")
    }

    override public var isFlipped: Bool {
        true
    }

    /// Replaces the panel's rows (a panel whose content depends on a mode).
    public func setRows(_ rows: [NSView]) {
        body.setArrangedViews(rows)
        alignValueColumn()
        invalidateColumnLayout()
    }

    /// A card's slider rows, its sub-groups' included, share one value column as wide as the
    /// widest number among them, so their wells line up and their tracks end at one x.
    private func alignValueColumn() {
        guard style == .card else { return }
        func rows(in view: NSView) -> [SliderRowView] {
            view.subviews.flatMap { ($0 as? SliderRowView).map { [$0] } ?? rows(in: $0) }
        }
        let sliders = rows(in: body)
        let column = sliders.map(\.widestValueWidth).max()
        sliders.forEach { $0.valueColumnWidth = column }
    }

    /// Builds the header's right-click menu when it opens.
    public var headerMenu: (@MainActor () -> NSMenu)? {
        get { header.menuProvider }
        set { header.menuProvider = newValue }
    }

    /// The divider's point, which a card hasn't.
    private var dividerHeight: CGFloat {
        style == .card ? 0 : 1
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        Metrics.panelHeaderHeight + (isExpanded ? body.height(forWidth: width) : 0) + dividerHeight
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
        if let isOn = actions.isOn {
            trackers.append(Tracker { [weak self] in
                guard let self else { return }
                setOn(isOn())
            })
        }
    }

    private var bodyAlpha: CGFloat {
        isOn ? 1 : Metrics.switchedOffOpacity
    }

    private func setOn(_ on: Bool) {
        isOn = on
        header.isOn = on
        if body.superview != nil, body.alphaValue > 0 {
            body.alphaValue = bodyAlpha
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded || (expanded && body.superview == nil) else { return }
        let animated = window != nil && isExpanded != expanded && header.hasBeenDisplayed
        isExpanded = expanded
        header.isExpanded = expanded
        if expanded {
            if body.superview == nil {
                addSubview(body, positioned: .above, relativeTo: header)
            }
            body.alphaValue = animated ? 0 : bodyAlpha
        }
        invalidateColumnLayout()
        guard animated else {
            if !expanded {
                body.removeFromSuperview()
            }
            return
        }
        (enclosingColumnHost as? PanelColumnDocumentView)?.sizeNow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            body.animator().alphaValue = expanded ? bodyAlpha : 0
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

/// The panel title bar: chevron, glyph, title and badge, then at the trailing edge the eye (or
/// its slot), and left of it the Edited chip or an accessory.
final class PanelHeaderView: NSView {
    let title: String
    let symbol: String?
    let badge: String?
    let accessory: NSView?
    let eye: PanelEyeView?
    let eyeSlot: Bool
    /// From the header's sides to its first and last glyph.
    let padding: CGFloat
    let highlightsOnHover: Bool
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
                setAccessibilityHelp(isEdited ? "\(title) has edits" : nil)
            }
        }
    }

    var isOn = true {
        didSet {
            if isOn != oldValue {
                eye?.isOn = isOn
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

    init(
        title: String, symbol: String?, badge: String?, accessory: NSView? = nil, eye: PanelEyeView? = nil,
        eyeSlot: Bool = false, padding: CGFloat = Metrics.panelPadding, highlightsOnHover: Bool = false,
    ) {
        self.title = title
        self.symbol = symbol
        self.badge = badge
        self.accessory = accessory
        self.eye = eye
        self.eyeSlot = eyeSlot
        self.padding = padding
        self.highlightsOnHover = highlightsOnHover
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        if let accessory {
            addSubview(accessory)
        }
        if let eye {
            addSubview(eye)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    /// The eye's hit target, its glyph's right edge at the padding.
    private var eyeFrame: CGRect {
        let side = Metrics.panelEyeTarget
        let glyph = Symbol.layoutSize("eye", pointSize: Metrics.panelEyePointSize, weight: .regular).width
        let center = CGPoint(x: bounds.width - padding - glyph / 2, y: bounds.height / 2)
        return PixelGrid.centered(CGSize(width: side, height: side), at: center, scale: backingScale)
    }

    /// Where the Edited chip and an accessory end: left of the eye's slot, or at the padding.
    private var trailingEdge: CGFloat {
        eyeSlot ? eyeFrame.minX : bounds.width - padding
    }

    override func layout() {
        super.layout()
        eye?.frame = eyeFrame
        guard let accessory else { return }
        let size = accessory.intrinsicContentSize
        accessory.frame = PixelGrid.centered(
            size, at: CGPoint(x: trailingEdge - size.width / 2, y: bounds.height / 2), scale: backingScale,
        )
    }

    override func draw(_: NSRect) {
        hasBeenDisplayed = true
        let scale = backingScale
        var x = padding
        let midY = bounds.height / 2

        if highlightsOnHover, isHovering {
            Palette.cardHover.nsColor.setFill()
            bounds.fill(using: .sourceOver)
        }

        // Turned about its frame's center, as SwiftUI's `rotationEffect` does.
        let chevron = Symbol.layoutSize("chevron.right", pointSize: 9, weight: .bold)
        Symbol.draw(
            "chevron.right", pointSize: 9, weight: .bold, color: Palette.secondaryLabel,
            centeredAt: CGPoint(x: x + chevron.width / 2, y: midY), rotation: isExpanded ? 90 : 0, scale: scale,
        )
        x += chevron.width + 8

        if let symbol {
            // A fixed slot, so titles line up whatever each glyph's width.
            let slot = Metrics.panelSymbolSlot
            Symbol.draw(
                symbol, pointSize: 11, color: Palette.secondaryLabel,
                centeredAt: CGPoint(x: x + slot / 2, y: midY), scale: scale,
            )
            x += slot + 6
        }

        let titleWidth = TextLine.width(title, font: Typography.panelTitle)
        let titleColor = isOn ? (isHovering ? Palette.labelHover : Palette.value)
            : (isHovering ? Palette.secondaryLabel : Palette.tertiaryLabel)
        TextLine.draw(
            title, font: Typography.panelTitle,
            color: titleColor.nsColor,
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

        if isEdited, accessory == nil {
            let font = Self.editedChipFont
            let text = Self.editedChipTitle
            let height = TextLine.lineHeight(font) + 3
            let width = TextLine.width(text, font: font) + 2 * Metrics.editedChipPadding
            let chip = PixelGrid.centered(
                CGSize(width: width, height: height),
                at: CGPoint(x: trailingEdge - (eyeSlot ? 2 : 0) - width / 2, y: midY), scale: scale,
            )
            // A switched-off panel's chip dims with its title.
            let alpha: CGFloat = isOn ? 1 : Metrics.switchedOffOpacity
            Palette.editedChipFill.withAlphaComponent(Palette.editedChipFill.alphaComponent * alpha).setFill()
            NSBezierPath(roundedRect: chip, xRadius: height / 2, yRadius: height / 2).fill()
            TextLine.draw(
                text, font: font, color: Palette.editedChipText.withAlphaComponent(alpha),
                in: chip.insetBy(dx: Metrics.editedChipPadding, dy: 0), alignment: .center, scale: scale,
            )
        }
    }

    /// The chip on a header whose panel has edits.
    static var editedChipTitle: String {
        uppercaseEditedChip ? "EDITED" : "Edited"
    }

    static var editedChipFont: FontSpec {
        uppercaseEditedChip ? FontSpec(size: 8.5, weight: .semibold, tracking: 0.5) : Typography.badge
    }

    #if DEBUG || REDLAMP_PROFILING
        /// The chip in capitals, for comparing in snapshots (`PanelSectionView.uppercaseEditedChip`).
        static var uppercaseEditedChip = false
    #else
        static let uppercaseEditedChip = false
    #endif

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

/// A panel header's eye: `eye` while the panel is on, `eye.slash` while it's off. A click turns
/// the panel off or on without expanding it; VoiceOver reads it as a switch.
final class PanelEyeView: NSView {
    let title: String
    let onChange: (Bool) -> Void

    var isOn = true {
        didSet {
            if isOn != oldValue {
                needsDisplay = true
                toolTip = Self.toolTip(title, on: isOn)
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

    init(title: String, onChange: @escaping (Bool) -> Void) {
        self.title = title
        self.onChange = onChange
        super.init(frame: CGRect(x: 0, y: 0, width: Metrics.panelEyeTarget, height: Metrics.panelEyeTarget))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        toolTip = Self.toolTip(title, on: true)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static func toolTip(_ title: String, on: Bool) -> String {
        "Turn \(title) \(on ? "off" : "on")"
    }

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.panelEyeTarget, height: Metrics.panelEyeTarget)
    }

    /// Quiet while on, clearer while off, brighter under the pointer.
    var glyphColor: RGBA {
        isHovering ? Palette.labelHover : isOn ? Palette.tertiaryLabel : Palette.secondaryLabel
    }

    override func draw(_: NSRect) {
        Symbol.draw(
            isOn ? "eye" : "eye.slash", pointSize: Metrics.panelEyePointSize, color: glyphColor,
            centeredAt: CGPoint(x: bounds.midX, y: bounds.midY), scale: backingScale,
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
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

    override func mouseDown(with _: NSEvent) {
        onChange(!isOn)
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .checkBox
    }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        .switch
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityLabel() -> String? {
        title
    }

    override func accessibilityHelp() -> String? {
        toolTip
    }

    override func accessibilityValue() -> Any? {
        isOn ? 1 : 0
    }

    override func accessibilityPerformPress() -> Bool {
        onChange(!isOn)
        return true
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
