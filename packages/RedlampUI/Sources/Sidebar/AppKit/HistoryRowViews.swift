import AppKit
import RedlampDesign

/// A history step's value in the value font, right-aligned: "0.00 → +0.50". Too narrow for both,
/// it shows only the value after, truncated if it must be.
final class HistoryValuesView: LayerDrawnView {
    static let font = Typography.value
    private static let arrow = " → "

    private let before: String?
    private let after: String
    private let dimmed: Bool

    init(before: String?, after: String, dimmed: Bool) {
        self.before = before
        self.after = after
        self.dimmed = dimmed
        super.init(frame: .zero)
    }

    /// The width that shows both values.
    var fullWidth: CGFloat {
        segments.reduce(0) { $0 + $1.width }
    }

    /// The width that shows the value after.
    var afterWidth: CGFloat {
        width(of: after)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: fullWidth, height: TextLine.lineHeight(Self.font))
    }

    private struct Segment {
        let text: String
        let color: RGBA
        let width: CGFloat
    }

    /// Right to left, each as wide as it draws: whole pixels, as `TextLine` lays out a line.
    private var segments: [Segment] {
        let afterColor = dimmed ? Palette.tertiaryLabel : Palette.label
        let shown = Segment(text: after, color: afterColor, width: width(of: after))
        guard let before else { return [shown] }
        return [
            shown,
            Segment(text: Self.arrow, color: Palette.tertiaryLabel, width: width(of: Self.arrow)),
            Segment(
                text: before, color: dimmed ? Palette.tertiaryLabel : Palette.secondaryLabel, width: width(of: before),
            ),
        ]
    }

    private func width(of text: String) -> CGFloat {
        ceil(TextLine.width(text, font: Self.font) * backingScale) / backingScale
    }

    override func drawContent(in _: CGRect) {
        let scale = backingScale
        let segments = bounds.width + 0.25 >= fullWidth ? segments : Array(segments.prefix(1))
        var right = bounds.maxX
        for segment in segments {
            let width = min(segment.width, right - bounds.minX)
            TextLine.draw(
                segment.text, font: Self.font, color: segment.color.nsColor,
                in: CGRect(x: right - width, y: 0, width: width, height: bounds.height), alignment: .right,
                scale: scale,
            )
            right -= width
        }
    }
}

/// A sidebar row. The current history step is highlighted, which leaves the row's trailing
/// edge to its values.
final class SidebarRowView: NSTableRowView {
    var isCurrentStep = false {
        didSet { needsDisplay = true }
    }

    /// How far the highlight reaches past the row's content.
    static let highlightOutset: CGFloat = 6

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isCurrentStep, let content = view(atColumn: 0) as? NSView else { return }
        let rect = CGRect(
            x: max(content.frame.minX - Self.highlightOutset, 0), y: 0,
            width: min(content.frame.width + Self.highlightOutset * 2, bounds.width), height: bounds.height,
        )
        Palette.selection.nsColor.setFill()
        NSBezierPath(roundedRect: PixelGrid.snap(rect, scale: window?.backingScaleFactor ?? 2), xRadius: 5, yRadius: 5)
            .fill()
    }
}
