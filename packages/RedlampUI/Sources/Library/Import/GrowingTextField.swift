import AppKit

/// A text field that wraps onto more lines, up to `lines`, when its text doesn't fit on one, as it's typed too. AppKit
/// keeps a bezeled field one line high whatever its text, so the field measures its own height. At one line it's a
/// field as AppKit has it, its text scrolling.
final class GrowingTextField: NSTextField {
    /// The lines the field grows to as its text needs them.
    var lines = 1 {
        didSet { growsChanged(lines) }
    }

    override var intrinsicContentSize: NSSize {
        lines > 1 ? grownSize(upTo: lines) : super.intrinsicContentSize
    }

    override var stringValue: String {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var objectValue: Any? {
        didSet { invalidateIntrinsicContentSize() }
    }

    override func setFrameSize(_ size: NSSize) {
        let resized = size.width != frame.width
        super.setFrameSize(size)
        if resized {
            invalidateIntrinsicContentSize()
        }
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        invalidateIntrinsicContentSize()
    }
}

/// The same for a token field: its tokens wrap onto more lines, up to `lines`.
final class GrowingTokenField: NSTokenField {
    var lines = 1 {
        didSet { growsChanged(lines) }
    }

    override var intrinsicContentSize: NSSize {
        lines > 1 ? grownSize(upTo: lines) : super.intrinsicContentSize
    }

    override var stringValue: String {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var objectValue: Any? {
        didSet { invalidateIntrinsicContentSize() }
    }

    override func setFrameSize(_ size: NSSize) {
        let resized = size.width != frame.width
        super.setFrameSize(size)
        if resized {
            invalidateIntrinsicContentSize()
        }
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        invalidateIntrinsicContentSize()
    }

    /// The text left over when editing ends becomes a token, which can take another line.
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        invalidateIntrinsicContentSize()
    }
}

private extension NSTextField {
    /// Wraps the text past one line, cut short with an ellipsis after the last; or scrolls it, as a field of one line.
    func growsChanged(_ lines: Int) {
        cell?.wraps = lines > 1
        cell?.isScrollable = lines <= 1
        cell?.truncatesLastVisibleLine = lines > 1
        invalidateIntrinsicContentSize()
    }

    /// As tall as the text needs at the field's width, up to `lines` lines: while it's edited, the text typed, which
    /// the cell has only once editing ends.
    func grownSize(upTo lines: Int) -> NSSize {
        guard let cell = cell?.copy() as? NSCell else {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
        let bounds = NSRect(x: 0, y: 0, width: bounds.width, height: .greatestFiniteMagnitude)
        let text = (currentEditor() as? NSTextView)?.attributedString() ?? cell.attributedStringValue
        cell.stringValue = ""
        let oneLine = cell.cellSize(forBounds: bounds).height
        // Before its first layout the field has no width to wrap in.
        guard bounds.width > 0 else {
            return NSSize(width: NSView.noIntrinsicMetric, height: oneLine)
        }
        cell.attributedStringValue = text
        let needed = cell.cellSize(forBounds: bounds).height
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font ?? .systemFont(ofSize: NSFont.systemFontSize))
        let height = min(max(needed, oneLine), oneLine + CGFloat(lines - 1) * lineHeight)
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }
}
