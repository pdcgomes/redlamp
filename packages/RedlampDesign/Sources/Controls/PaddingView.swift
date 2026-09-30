import AppKit

/// Adds padding around a row, as SwiftUI's `.padding` does: the row itself grows, rather
/// than gaining a neighbour (a `GapView` would also bring the column's spacing).
public final class PaddingView: NSView, HeightProviding {
    public let content: NSView
    private let insets: NSEdgeInsets

    public init(_ content: NSView, top: CGFloat = 0, bottom: CGFloat = 0) {
        self.content = content
        insets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        super.init(frame: .zero)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public var isFlipped: Bool {
        true
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        insets.top + ColumnView.height(of: content, width: width) + insets.bottom
    }

    override public func layout() {
        super.layout()
        content.frame = CGRect(
            x: 0, y: insets.top, width: bounds.width, height: ColumnView.height(of: content, width: bounds.width),
        )
    }
}
