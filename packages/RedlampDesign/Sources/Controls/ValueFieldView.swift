import AppKit
import RedlampEngineAPI

/// A slider's numeric readout, in a well that shows it can be changed: subtle at rest, stronger
/// with the pointer over it (with the left-right cursor) or while scrubbing, and darker while
/// it's typed in. Drag to scrub (Shift for fine control), or click to type a value. Return
/// commits, Escape cancels, and the arrow keys step (Shift for ×10).
public final class ValueFieldView: LayerDrawnView, NSTextFieldDelegate {
    /// The drag that scrubs across the whole range, in points.
    public static let scrubSpan: CGFloat = 500
    /// How far a press moves before it scrubs rather than clicks, in points.
    public static let scrubThreshold: CGFloat = 3
    /// The room the well takes beside the number; a row gives the field this much beyond
    /// its value column, so the number stays where it was.
    public static let wellPadding: CGFloat = 4

    public var spec: any ValueFieldSpec {
        didSet {
            widestText = Self.widest(spec)
            setNeedsContentDisplay()
        }
    }

    /// The width of the widest number the field shows, its range's ends, so the well holds its
    /// width as the value changes.
    private var widestText: CGFloat

    public var value: Double {
        didSet {
            if value != oldValue, editor == nil {
                setNeedsContentDisplay()
            }
        }
    }

    public var isEnabled = true {
        didSet {
            if isEnabled != oldValue {
                window?.invalidateCursorRects(for: self)
                setNeedsContentDisplay()
            }
        }
    }

    /// See `SliderTrackView.opacity`.
    public var opacity: CGFloat = 1 {
        didSet {
            if opacity != oldValue {
                setNeedsContentDisplay()
            }
        }
    }

    /// Where the number ends, from the right: the well's padding when the field was given
    /// room for it, or nothing.
    public var trailingInset: CGFloat = 0 {
        didSet { setNeedsContentDisplay() }
    }

    /// A typed value, or an arrow-key step.
    public var onCommit: (Double) -> Void = { _ in }
    /// A scrub: its start, each value it passes and its end, one gesture.
    public var onBegin: () -> Void = {}
    public var onChange: (Double) -> Void = { _ in }
    public var onEnd: () -> Void = {}

    private var editor: NSTextField?
    private var cancelled = false
    private var hoverArea: NSTrackingArea?
    private var isHovering = false {
        didSet {
            if isHovering != oldValue {
                setNeedsContentDisplay()
            }
        }
    }

    /// A press: where it started, and where the scrub has reached once it moves far enough.
    private var press: (startX: CGFloat, lastX: CGFloat, position: Double?)?

    public init(spec: any ValueFieldSpec, value: Double = 0) {
        self.spec = spec
        self.value = value
        widestText = Self.widest(spec)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    /// Whether a drag is scrubbing the value.
    public var isScrubbing: Bool {
        press?.position != nil
    }

    // MARK: - Drawing

    private var textRect: CGRect {
        CGRect(x: 0, y: 0, width: max(bounds.width - trailingInset, 0), height: bounds.height)
    }

    private static func widest(_ spec: any ValueFieldSpec) -> CGFloat {
        [0.0, 1.0].map { TextLine.width(spec.formatted(spec.value(atPosition: $0)), font: Typography.value) }.max() ?? 0
    }

    /// The well, ending `wellPadding` beyond the number's right edge.
    public var wellRect: CGRect {
        let padding = Self.wellPadding
        let text = max(widestText, TextLine.width(spec.formatted(value), font: Typography.value))
        let width = min(text + 2 * padding, bounds.width)
        let height = min(TextLine.lineHeight(Typography.value) + 4, bounds.height)
        return PixelGrid.centered(
            CGSize(width: width, height: height),
            at: CGPoint(x: min(textRect.maxX + padding, bounds.width) - width / 2, y: bounds.midY),
            scale: backingScale,
        )
    }

    /// The well's colour, or nil for a disabled field, which has none.
    public var wellColor: RGBA? {
        guard isEnabled else { return nil }
        if editor != nil {
            return Palette.wellFocused
        }
        return isHovering || isScrubbing ? Palette.well : Palette.wellRest
    }

    override public func drawContent(in _: CGRect) {
        let text = spec.formatted(value)
        if let color = wellColor, let context = NSGraphicsContext.current?.cgContext {
            context.addPath(CGPath(roundedRect: wellRect, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.setFillColor(color.opacity(opacity).cgColor)
            context.fillPath()
        }
        guard editor == nil else { return }
        TextLine.draw(
            text, font: Typography.value, color: Palette.value.opacity(opacity).nsColor,
            in: textRect, alignment: .right, scale: backingScale,
        )
    }

    // MARK: - Pointer

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override public func mouseEntered(with _: NSEvent) {
        isHovering = true
    }

    override public func mouseExited(with _: NSEvent) {
        isHovering = false
    }

    override public func resetCursorRects() {
        if isEnabled, editor == nil {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
    }

    override public func mouseDown(with event: NSEvent) {
        guard isEnabled, editor == nil else { return }
        let x = convert(event.locationInWindow, from: nil).x
        press = (x, x, nil)
    }

    override public func mouseDragged(with event: NSEvent) {
        guard isEnabled, var current = press else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if current.position == nil {
            guard abs(x - current.startX) >= Self.scrubThreshold else { return }
            current.position = spec.position(for: value)
            onBegin()
        }
        let fine = event.modifierFlags.contains(.shift) ? 0.1 : 1.0
        let position = min(max(current.position! + Double((x - current.lastX) / Self.scrubSpan) * fine, 0), 1)
        current.position = position
        current.lastX = x
        press = current
        onChange(spec.quantize(spec.value(atPosition: position)))
        setNeedsContentDisplay()
    }

    override public func mouseUp(with _: NSEvent) {
        guard let ended = press else { return }
        press = nil
        if ended.position != nil {
            onEnd()
            setNeedsContentDisplay()
        } else if isEnabled {
            beginEditing()
        }
    }

    // MARK: - Typing a value

    private func beginEditing() {
        let field = NSTextField(string: spec.formatted(value))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typography.value.nsFont
        field.alignment = .right
        field.textColor = .labelColor
        field.cell?.isScrollable = true
        field.delegate = self
        let height = TextLine.lineHeight(Typography.value) + 2
        field.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: textRect.width, height: height)
        addSubview(field)
        editor = field
        cancelled = false
        window?.invalidateCursorRects(for: self)
        setNeedsContentDisplay()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endEditing(commit: Bool) {
        guard let field = editor else { return }
        editor = nil
        if commit, let parsed = spec.parse(field.stringValue, current: value) {
            onCommit(parsed)
        }
        field.delegate = nil
        field.removeFromSuperview()
        window?.invalidateCursorRects(for: self)
        setNeedsContentDisplay()
    }

    public func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelled = true
            window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.moveUp(_:)):
            step(1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            step(-1)
            return true
        default:
            return false
        }
    }

    public func controlTextDidEndEditing(_: Notification) {
        endEditing(commit: !cancelled)
    }

    private func step(_ direction: Double) {
        guard let field = editor else { return }
        let multiplier = NSEvent.modifierFlags.contains(.shift) ? 10.0 : 1.0
        let typed = spec.parse(field.stringValue, current: value) ?? value
        let next = spec.clamp(typed + direction * spec.step * multiplier)
        onCommit(next)
        field.stringValue = spec.formatted(next)
    }
}
