import AppKit

/// A vertical scroll view whose scroller is always the thin, translucent overlay kind that
/// fades out once scrolling stops, even with "Show scroll bars: Always": a permanent
/// opaque track beside the panels is a distraction while editing.
public final class OverlayScrollView: NSScrollView {
    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        verticalScroller?.controlSize = .small
        super.scrollerStyle = .overlay
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// AppKit sets the style again whenever the system preference changes.
    override public var scrollerStyle: NSScroller.Style {
        get { .overlay }
        // swiftlint:disable:next unused_setter_value
        set { super.scrollerStyle = .overlay }
    }
}
