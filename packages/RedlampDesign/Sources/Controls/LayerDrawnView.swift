import AppKit
import QuartzCore

/// A view that draws into a plain `CALayer` rather than through `NSView.draw(_:)`.
///
/// Redrawing through `draw(_:)` makes AppKit record and hash a display list for the view
/// on every commit, which cost ~0.4 ms per slider readout; a layer drawing its own
/// contents skips that. Subclasses override `drawContent(in:)`, which runs with a flipped
/// `NSGraphicsContext` current, exactly like `draw(_:)`, and call `setNeedsContentDisplay()`.
open class LayerDrawnView: NSView, @preconcurrency CALayerDelegate {
    private let contentLayer = CALayer()

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        contentLayer.delegate = self
        contentLayer.needsDisplayOnBoundsChange = true
        contentLayer.anchorPoint = .zero
        layer?.addSublayer(contentLayer)
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override open var isFlipped: Bool {
        true
    }

    override open var wantsUpdateLayer: Bool {
        true
    }

    override open func updateLayer() {}

    open func drawContent(in _: CGRect) {}

    public func setNeedsContentDisplay() {
        contentLayer.setNeedsDisplay()
    }

    override open func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds
        contentLayer.contentsScale = backingScale
        CATransaction.commit()
    }

    override open func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        contentLayer.contentsScale = backingScale
        contentLayer.setNeedsDisplay()
    }

    // MARK: - CALayerDelegate

    /// Layers of a view display on the main thread.
    public func draw(_ layer: CALayer, in context: CGContext) {
        // Draw in the view's flipped coordinates, whichever way the layer is set up.
        if !layer.contentsAreFlipped() {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        drawContent(in: bounds)
        NSGraphicsContext.current = previous
    }

    public func action(for _: CALayer, forKey _: String) -> (any CAAction)? {
        NSNull()
    }
}
