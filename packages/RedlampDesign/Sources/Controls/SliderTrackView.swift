import AppKit
import RedlampEngineAPI

/// A Lightroom-style slider track: a thin track (plain, or a color gradient), the fill
/// from the origin to the thumb, a tick at zero for bipolar sliders, and the thumb.
///
/// - Drag the thumb for relative changes, or click the track to jump.
/// - Shift-drag for fine control; double-click to reset.
public final class SliderTrackView: LayerDrawnView {
    public var spec: ParameterSpec {
        didSet { setNeedsContentDisplay() }
    }

    public var value: Double {
        didSet {
            if value != oldValue {
                setNeedsContentDisplay()
            }
        }
    }

    public var isEnabled = true

    /// Applied to each shape on its own, as SwiftUI's `.opacity` on a row does: a dimmed
    /// thumb lets the track show through.
    public var opacity: CGFloat = 1 {
        didSet {
            if opacity != oldValue {
                setNeedsContentDisplay()
            }
        }
    }

    public var onBegin: () -> Void = {}
    public var onChange: (Double) -> Void = { _ in }
    public var onEnd: () -> Void = {}
    public var onReset: () -> Void = {}

    /// The thumb's shadow blur, as CoreGraphics measures it (tuned against SwiftUI's
    /// `.shadow(radius: 1.5)` in the harness).
    public static var thumbShadowBlur: CGFloat = 2

    private var dragStart: (location: CGFloat, position: Double)?

    public init(spec: ParameterSpec, value: Double = 0) {
        self.spec = spec
        self.value = value
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Metrics.trackHeight)
    }

    override public func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    // MARK: - Geometry

    private var inset: CGFloat {
        Metrics.thumbSize / 2
    }

    private var usable: CGFloat {
        max(bounds.width - Metrics.thumbSize, 1)
    }

    private var thumbX: CGFloat {
        inset + spec.position(for: value) * usable
    }

    private var originX: CGFloat {
        inset + (spec.isBipolar ? spec.position(for: 0) : 0) * usable
    }

    // MARK: - Drawing

    override public func drawContent(in _: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = backingScale
        let midY = bounds.height / 2
        let space = window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let gradient = spec.track.cgGradient(in: space)
        context.setAlpha(opacity)

        // Each shape as SwiftUI lays it out: a fixed-size frame positioned by its center.
        let trackHeight: CGFloat = gradient == nil ? 2 : 3
        let track = PixelGrid.centered(
            CGSize(width: usable, height: trackHeight),
            at: CGPoint(x: bounds.width / 2, y: midY),
            scale: scale,
        )
        let trackPath = CGPath(
            roundedRect: track,
            cornerWidth: trackHeight / 2,
            cornerHeight: trackHeight / 2,
            transform: nil,
        )
        if let gradient {
            context.saveGState()
            context.setAlpha(0.9 * opacity)
            context.addPath(trackPath)
            context.clip()
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: track.minX, y: midY),
                end: CGPoint(x: track.maxX, y: midY),
                options: [],
            )
            context.restoreGState()
        } else {
            context.addPath(trackPath)
            context.setFillColor(Palette.track.cgColor)
            context.fillPath()

            let fillWidth = abs(thumbX - originX)
            if fillWidth > 0 {
                let fill = PixelGrid.centered(
                    CGSize(width: fillWidth, height: 2), at: CGPoint(x: (thumbX + originX) / 2, y: midY), scale: scale,
                )
                let radius = min(1, fill.width / 2)
                context.addPath(CGPath(roundedRect: fill, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.setFillColor(Palette.trackFill.cgColor)
                context.fillPath()
            }
        }

        if spec.isBipolar {
            context.setFillColor(Palette.secondaryLabel.cgColor)
            context.fill(PixelGrid.centered(
                CGSize(width: 1, height: 7),
                at: CGPoint(x: originX, y: midY),
                scale: scale,
            ))
        }

        let size = Metrics.thumbSize
        let thumb = PixelGrid.centered(CGSize(width: size, height: size), at: CGPoint(x: thumbX, y: midY), scale: scale)
        context.saveGState()
        // Shadow offsets are in the unflipped base space: negative is down.
        context.setShadow(
            offset: CGSize(width: 0, height: -0.5),
            blur: Self.thumbShadowBlur,
            color: Palette.thumbShadow.cgColor,
        )
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(Palette.thumb.cgColor)
        context.fillEllipse(in: thumb)
        context.setStrokeColor(Palette.thumbStroke.cgColor)
        context.setLineWidth(0.5)
        context.strokeEllipse(in: thumb.insetBy(dx: 0.25, dy: 0.25))
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // MARK: - Events

    override public func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount >= 2 {
            onReset()
            return
        }
        onBegin()
        let x = convert(event.locationInWindow, from: nil).x
        if abs(x - thumbX) <= Metrics.thumbSize {
            dragStart = (x, spec.position(for: value))
        } else {
            let jumped = Double((x - inset) / usable)
            dragStart = (x, jumped)
            onChange(spec.value(atPosition: jumped))
        }
    }

    override public func mouseDragged(with event: NSEvent) {
        guard isEnabled, let start = dragStart else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let fine = event.modifierFlags.contains(.shift) ? 0.1 : 1.0
        let delta = (x - start.location) / usable * fine
        onChange(spec.value(atPosition: start.position + delta))
    }

    override public func mouseUp(with _: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        onEnd()
    }
}
