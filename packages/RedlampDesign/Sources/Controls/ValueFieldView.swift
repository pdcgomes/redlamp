import AppKit
import RedlampEngineAPI

/// A slider's numeric readout. Click to type a value; Return commits, Escape cancels, and
/// the arrow keys step (Shift for ×10).
public final class ValueFieldView: LayerDrawnView, NSTextFieldDelegate {
    public var spec: ParameterSpec {
        didSet { setNeedsContentDisplay() }
    }

    public var value: Double {
        didSet {
            if value != oldValue, editor == nil {
                setNeedsContentDisplay()
            }
        }
    }

    public var isEnabled = true
    /// See `SliderTrackView.opacity`.
    public var opacity: CGFloat = 1 {
        didSet {
            if opacity != oldValue {
                setNeedsContentDisplay()
            }
        }
    }

    public var onCommit: (Double) -> Void = { _ in }

    private var editor: NSTextField?
    private var cancelled = false

    public init(spec: ParameterSpec, value: Double = 0) {
        self.spec = spec
        self.value = value
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public func drawContent(in _: CGRect) {
        guard editor == nil else { return }
        TextLine.draw(
            spec.formatted(value), font: Typography.value, color: Palette.value.opacity(opacity).nsColor,
            in: bounds, alignment: .right, scale: backingScale,
        )
    }

    override public func mouseDown(with _: NSEvent) {
        guard isEnabled, editor == nil else { return }
        beginEditing()
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
        field.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        addSubview(field)
        editor = field
        cancelled = false
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
        let next = spec.clamp((spec.parse(field.stringValue) ?? value) + direction * spec.step * multiplier)
        onCommit(next)
        field.stringValue = spec.formatted(next)
    }
}
