import AppKit

/// A view that, like a SwiftUI view, chooses its size from the space it is offered (a
/// menu button widens to fill a row, up to its maximum).
@MainActor
public protocol ProposalSizing: NSView {
    func size(proposing proposal: CGSize) -> CGSize
}

/// A compact label + controls row (Treatment, Profile, White Balance). Controls keep their
/// natural width and sit side by side, vertically centered.
public final class ControlRowView: NSView {
    private let label: String
    public let controls: [NSView]
    /// Brings the controls in step with the model; tracked while the row is in a window.
    private let update: (@MainActor () -> Void)?
    private var tracker: Tracker?

    public init(label: String, controls: [NSView], update: (@MainActor () -> Void)? = nil) {
        self.label = label
        self.controls = controls
        self.update = update
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        controls.forEach(addSubview)
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        if window != nil, let update {
            tracker = Tracker(update)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public var isFlipped: Bool {
        true
    }

    override public var intrinsicContentSize: NSSize {
        let tallest = controls.map(\.intrinsicContentSize.height).max() ?? 0
        return NSSize(width: NSView.noIntrinsicMetric, height: max(Metrics.controlRowMinHeight, tallest))
    }

    override public func layout() {
        super.layout()
        let scale = backingScale
        var x = Metrics.labelWidth + Metrics.rowSpacing
        for control in controls {
            let available = CGSize(width: max(bounds.width - x, 0), height: bounds.height)
            let size = (control as? ProposalSizing)?.size(proposing: available) ?? control.intrinsicContentSize
            control.frame = PixelGrid.centered(
                size,
                at: CGPoint(x: x + size.width / 2, y: bounds.height / 2),
                scale: scale,
            )
            x += size.width + Metrics.rowSpacing
        }
    }

    override public func draw(_: NSRect) {
        TextLine.draw(
            label, font: Typography.label, color: Palette.label.nsColor,
            in: CGRect(x: 0, y: 0, width: Metrics.labelWidth, height: bounds.height), scale: backingScale,
        )
    }
}
