import AppKit

/// A scrolling column of panels whose document resizes as they expand and collapse: the
/// inspector's Develop panels and the sidebar's lists.
open class PanelColumnScrollView: NSView {
    public let scrollView = OverlayScrollView()
    public let document: PanelColumnDocumentView

    public init(views: [NSView]) {
        document = PanelColumnDocumentView(views: views)
        super.init(frame: .zero)
        scrollView.documentView = document
        addSubview(scrollView)
        document.onHeightChange = { [weak self] in self?.needsLayout = true }
        document.sizeNow = { [weak self] in self?.layoutSubtreeIfNeeded() }
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override open func layout() {
        super.layout()
        scrollView.frame = bounds
        sizeDocument()
    }

    private func sizeDocument() {
        let width = scrollView.contentView.bounds.width
        let size = CGSize(width: width, height: document.height(forWidth: width))
        if document.frame.size != size {
            document.setFrameSize(size)
        }
        document.layoutSubtreeIfNeeded()
    }
}

/// The scroll view's document: the panels, top to bottom.
public final class PanelColumnDocumentView: ColumnView, ColumnHost {
    /// Told when the panels' height may have changed; the document is sized in the next layout
    /// pass, once for however many changes.
    public var onHeightChange: () -> Void = {}

    /// Sizes the document now, for an animation that needs the new frames up front.
    var sizeNow: () -> Void = {}

    public init(views: [NSView]) {
        super.init(views: views)
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func columnContentDidChange() {
        onHeightChange()
    }
}
