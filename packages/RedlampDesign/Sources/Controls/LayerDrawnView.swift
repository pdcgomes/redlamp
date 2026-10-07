import AppKit
import QuartzCore

/// A view that draws into a plain `CALayer` rather than through `NSView.draw(_:)`.
///
/// Redrawing through `draw(_:)` makes AppKit record and hash a display list for the view
/// on every commit, which cost ~0.4 ms per slider readout; a layer drawing its own
/// contents skips that. Subclasses override `drawContent(in:)`, which runs with a flipped
/// `NSGraphicsContext` current, exactly like `draw(_:)`, and call `setNeedsContentDisplay()`.
///
/// A view whose drawing includes an image that changes often (the histogram's channels) can
/// add an image layer above the drawing and a drawn overlay above that
/// (`addImageAndOverlayLayers()`): it makes the image off the main thread and hands it to
/// `setImage(_:frame:)`, and only the parts around it are drawn.
open class LayerDrawnView: NSView, @preconcurrency CALayerDelegate {
    private let contentLayer = CALayer()
    private var imageLayer: CALayer?
    private var overlayLayer: CALayer?

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        configure(contentLayer)
        layer?.addSublayer(contentLayer)
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure(_ drawn: CALayer) {
        drawn.delegate = self
        drawn.needsDisplayOnBoundsChange = true
        drawn.anchorPoint = .zero
        // A fixed format spares Core Animation a first pass over the drawing to choose one,
        // and drawing asynchronously rasterizes off the main thread.
        drawn.contentsFormat = .RGBA8Uint
        drawn.drawsAsynchronously = true
    }

    override open var isFlipped: Bool {
        true
    }

    override open var wantsUpdateLayer: Bool {
        true
    }

    override open func updateLayer() {}

    open func drawContent(in _: CGRect) {}

    /// Draws above the image layer; see `addImageAndOverlayLayers()`.
    open func drawOverlay(in _: CGRect) {}

    public func setNeedsContentDisplay() {
        contentLayer.setNeedsDisplay()
    }

    public func setNeedsOverlayDisplay() {
        overlayLayer?.setNeedsDisplay()
    }

    /// Adds the image layer and the overlay above the drawing.
    public func addImageAndOverlayLayers() {
        guard imageLayer == nil, let host = layer else { return }
        let image = CALayer()
        image.delegate = self
        image.anchorPoint = .zero
        let overlay = CALayer()
        configure(overlay)
        host.addSublayer(image)
        host.addSublayer(overlay)
        imageLayer = image
        overlayLayer = overlay
    }

    /// Shows `image` at `frame`, in the view's coordinates; nil shows nothing there.
    public func setImage(_ image: CGImage?, frame: CGRect) {
        guard let imageLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        imageLayer.frame = frame
        CATransaction.commit()
    }

    override open func layout() {
        super.layout()
        #if DEBUG || REDLAMP_PROFILING
            let previous = (size: contentLayer.frame.size, scale: contentLayer.contentsScale)
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for drawn in [contentLayer, overlayLayer].compactMap(\.self) {
            drawn.frame = bounds
            drawn.contentsScale = backingScale
        }
        CATransaction.commit()
        #if DEBUG || REDLAMP_PROFILING
            if previous.size != bounds.size || previous.scale != backingScale {
                Self.drawObserver?(self, .laidOut(size: bounds.size, scale: backingScale))
            }
        #endif
    }

    override open func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        for drawn in [contentLayer, overlayLayer].compactMap(\.self) {
            drawn.contentsScale = backingScale
            drawn.setNeedsDisplay()
        }
        #if DEBUG || REDLAMP_PROFILING
            Self.drawObserver?(self, .backingChanged(scale: backingScale))
        #endif
    }

    #if DEBUG || REDLAMP_PROFILING
        public enum DrawEvent {
            /// `drawContent` or `drawOverlay` ran, taking this long on the main thread.
            case drew(milliseconds: Double)
            /// Layout gave the content layer a new size or scale.
            case laidOut(size: CGSize, scale: CGFloat)
            /// The window's backing properties changed (for example, it moved to another screen).
            case backingChanged(scale: CGFloat)
        }

        /// Told of every layer-drawn view's draws and size and scale changes, for the profiling
        /// build's draw counter (`--count-graph-draws`); nil otherwise.
        public static var drawObserver: ((LayerDrawnView, DrawEvent) -> Void)?
    #endif

    // MARK: - CALayerDelegate

    /// Layers of a view display on the main thread.
    public func draw(_ layer: CALayer, in context: CGContext) {
        guard layer !== imageLayer else { return }
        #if DEBUG || REDLAMP_PROFILING
            let started = Self.drawObserver == nil ? nil : CFAbsoluteTimeGetCurrent()
            defer {
                if let started {
                    Self.drawObserver?(self, .drew(milliseconds: (CFAbsoluteTimeGetCurrent() - started) * 1000))
                }
            }
        #endif
        // Draw in the view's flipped coordinates, whichever way the layer is set up.
        if !layer.contentsAreFlipped() {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        // Dynamic colors (the accent, system blue) resolve for this view's appearance.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if layer === overlayLayer {
                drawOverlay(in: bounds)
            } else {
                drawContent(in: bounds)
            }
        }
        NSGraphicsContext.current = previous
    }

    public func action(for _: CALayer, forKey _: String) -> (any CAAction)? {
        NSNull()
    }
}
