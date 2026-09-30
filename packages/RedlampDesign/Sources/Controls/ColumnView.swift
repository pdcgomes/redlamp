import AppKit

/// A view whose height depends on its width (a panel, a column of rows).
@MainActor
public protocol HeightProviding: NSView {
    func height(forWidth width: CGFloat) -> CGFloat
}

/// Lays views out top to bottom at full width, like SwiftUI's
/// `VStack(alignment: .leading, spacing:)` plus padding, with plain frame math: rows are
/// laid out once, and changing a value inside one never re-lays out its neighbours.
open class ColumnView: NSView, HeightProviding {
    public var spacing: CGFloat {
        didSet { invalidateColumnLayout() }
    }

    public var insets: NSEdgeInsets {
        didSet { invalidateColumnLayout() }
    }

    public private(set) var arrangedViews: [NSView] = []

    public init(spacing: CGFloat = 0, insets: NSEdgeInsets = NSEdgeInsets(), views: [NSView] = []) {
        self.spacing = spacing
        self.insets = insets
        super.init(frame: CGRect(x: 0, y: 0, width: 300, height: 0))
        wantsLayer = true
        clipsToBounds = false
        setArrangedViews(views)
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override open var isFlipped: Bool {
        true
    }

    public func setArrangedViews(_ views: [NSView]) {
        for view in arrangedViews where !views.contains(view) {
            view.removeFromSuperview()
        }
        arrangedViews = views
        for view in views where view.superview !== self {
            addSubview(view)
        }
        invalidateColumnLayout()
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        let content = width - insets.left - insets.right
        let rows = arrangedViews.filter { !$0.isHidden }
        let heights = rows.reduce(0) { $0 + Self.height(of: $1, width: content) }
        return insets.top + heights + spacing * CGFloat(max(rows.count - 1, 0)) + insets.bottom
    }

    override open var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width))
    }

    override open func layout() {
        super.layout()
        let width = bounds.width - insets.left - insets.right
        var y = insets.top
        for view in arrangedViews where !view.isHidden {
            let height = Self.height(of: view, width: width)
            view.frame = CGRect(x: insets.left, y: y, width: width, height: height)
            y += height + spacing
        }
    }

    static func height(of view: NSView, width: CGFloat) -> CGFloat {
        if let provider = view as? HeightProviding {
            return provider.height(forWidth: width)
        }
        let intrinsic = view.intrinsicContentSize.height
        return intrinsic == NSView.noIntrinsicMetric ? view.fittingSize.height : intrinsic
    }
}

public extension NSView {
    /// Tells every enclosing column that this view's height may have changed.
    func invalidateColumnLayout() {
        var view: NSView? = self
        while let current = view {
            current.invalidateIntrinsicContentSize()
            current.needsLayout = true
            (current as? ColumnHost)?.columnContentDidChange()
            view = current.superview
        }
    }
}

/// The view at the top of a column hierarchy (a scroll view's document, say), told when
/// the content's height changes so it can resize.
@MainActor
public protocol ColumnHost: NSView {
    func columnContentDidChange()
}

/// A fixed-height gap (SwiftUI's `Spacer().frame(height:)` in a stack).
public final class GapView: NSView {
    private let height: CGFloat

    public init(height: CGFloat) {
        self.height = height
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height)
    }
}
