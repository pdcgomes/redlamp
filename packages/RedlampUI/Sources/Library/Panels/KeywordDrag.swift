import AppKit
import RedlampDesign
import RedlampLibrary

/// A keyword's name in the Keyword List, which drags the keyword onto photos in the grid (LIB-21): a press that moves
/// a few points starts the drag (`LibraryDrags`); one let go without moving is a click on its row, which selects the
/// row, and a double click edits the keyword, as clicks elsewhere in the row do.
final class KeywordDragLabel: NSTextField, NSDraggingSource, LibraryDragSource {
    var keyword: KeywordPath?
    private var press: (point: CGPoint, clicks: Int)?

    static func make() -> KeywordDragLabel {
        let label = KeywordDragLabel(labelWithString: "")
        label.font = Typography.label.nsFont
        label.textColor = Palette.value.nsColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    override func mouseDown(with event: NSEvent) {
        press = (convert(event.locationInWindow, from: nil), event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !LibraryDrags.follow(event), let press, let keyword else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - press.point.x, point.y - press.point.y) >= LibraryGridView.dragDistance else { return }
        self.press = nil
        let pasteboard = NSPasteboardItem()
        pasteboard.setString(keyword.text, forType: LibraryDrags.keyword)
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        let text = attributedStringValue
        let size = CGSize(width: min(text.size().width + 12, 240), height: bounds.height + 4)
        item.setDraggingFrame(
            CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size),
            contents: NSImage(size: size, flipped: false) { rect in
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
                text.draw(in: rect.insetBy(dx: 6, dy: 2))
                return true
            },
        )
        LibraryDrags.begin(item, event: event, from: self, mask: Self.operations)
    }

    override func mouseUp(with event: NSEvent) {
        guard !LibraryDrags.follow(event), let press else { return }
        self.press = nil
        guard let outline = enclosingOutline else { return }
        let row = outline.row(for: self)
        if row >= 0 {
            outline.click(row: row, count: press.clicks)
        }
    }

    private var enclosingOutline: KeywordOutlineView? {
        var view = superview
        while let current = view, !(current is KeywordOutlineView) {
            view = current.superview
        }
        return view as? KeywordOutlineView
    }

    /// What a keyword's drag offers: tagging photos.
    static let operations: NSDragOperation = [.copy, .generic]

    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? Self.operations : []
    }

    func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
        libraryDragEnded()
        LibraryDrags.ended()
    }

    func libraryDragEnded() {
        press = nil
    }
}

/// The Keyword List's outline: a press on a keyword's name goes to the name, which drags it, and its click comes back
/// as a click on its row.
final class KeywordOutlineView: NSOutlineView {
    /// The row whose name a click passed on was in, as `clickedRow` while the click's action runs.
    private var passedClick: Int?

    override var clickedRow: Int {
        passedClick ?? super.clickedRow
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        responder is KeywordDragLabel || super.validateProposedFirstResponder(responder, for: event)
    }

    /// A press on a keyword's name reaches the name, which a table keeps for itself unless it's a control's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let found = super.hitTest(point)
        let local = convert(point, from: superview)
        let row = row(at: local)
        guard row >= 0, let cell = view(atColumn: 0, row: row, makeIfNecessary: false), let holder = cell.superview
        else { return found }
        let label = cell.hitTest(holder.convert(local, from: self))
        return label is KeywordDragLabel ? label : found
    }

    /// A click on row `row`'s keyword name: it selects the row, and a second edits the keyword.
    func click(row: Int, count: Int) {
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard count == 2, let action = doubleAction else { return }
        passedClick = row
        defer { passedClick = nil }
        sendAction(action, to: target)
    }
}
