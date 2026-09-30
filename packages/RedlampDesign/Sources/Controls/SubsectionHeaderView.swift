import AppKit
import RedlampEngineAPI

/// A small caps subsection title ("TONE", "PRESENCE") that resets its group on
/// double-click. Holding Option turns it into a one-click "Reset …", as in Lightroom.
public final class SubsectionHeaderView: NSView {
    private let title: String
    private let parameters: [ParameterID]
    private let editor: ParameterEditing
    private let accessory: NSView?
    private var tracker: Tracker?
    private var resetMode = false {
        didSet {
            if resetMode != oldValue {
                needsDisplay = true
            }
        }
    }

    private let update: (@MainActor () -> Void)?

    /// `update` brings the accessory in step with the model, tracked like the title.
    public init(
        title: String,
        parameters: [ParameterID],
        editor: ParameterEditing,
        accessory: NSView? = nil,
        update: (@MainActor () -> Void)? = nil,
    ) {
        self.title = title
        self.parameters = parameters
        self.editor = editor
        self.accessory = accessory
        self.update = update
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        if let accessory {
            addSubview(accessory)
        }
        toolTip = "Double-click, or Option-click, to reset \(title)"
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public var isFlipped: Bool {
        true
    }

    private var contentHeight: CGFloat {
        max(TextLine.lineHeight(Typography.section), accessory?.intrinsicContentSize.height ?? 0)
    }

    override public var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: Metrics.subsectionTopPadding + contentHeight + Metrics.subsectionBottomPadding,
        )
    }

    private var contentRect: CGRect {
        CGRect(x: 0, y: Metrics.subsectionTopPadding, width: bounds.width, height: contentHeight)
    }

    override public func layout() {
        super.layout()
        guard let accessory else { return }
        let size = accessory.intrinsicContentSize
        let content = contentRect
        accessory.frame = CGRect(
            x: content.maxX - size.width,
            y: content.minY + (content.height - size.height) / 2,
            width: size.width,
            height: size.height,
        )
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            resetMode = editor.optionKeyHeld && !parameters.isEmpty
            update?()
        }
    }

    override public func draw(_: NSRect) {
        let text = resetMode ? "RESET \(title.uppercased())" : title.uppercased()
        let color = resetMode ? Palette.accent : Palette.secondaryLabel.nsColor
        TextLine.draw(text, font: Typography.section, color: color, in: contentRect, scale: backingScale)
    }

    override public func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 || resetMode {
            editor.resetParameters(parameters, name: "Reset \(title)")
        }
    }
}
