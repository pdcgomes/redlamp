import AppKit
import QuartzCore
import RedlampDesign
import RedlampDocument
import RedlampLibrary

extension LibraryGridLayout {
    var geometry: GridCellGeometry {
        GridCellGeometry(size: size, style: style)
    }
}

/// The grid's document view: the cells' layers' host. It takes the keyboard in the Library module and
/// hands its keys, clicks and drags to the grid.
final class LibraryGridContentView: NSView {
    weak var grid: LibraryGridView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(true)
        setAccessibilityRole(.grid)
        setAccessibilityLabel("Grid")
        setAccessibilityIdentifier("library.grid")
        registerForDraggedTypes([LibraryDrags.keyword, LibraryDrags.photos])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {}

    override var acceptsFirstResponder: Bool {
        true
    }

    override func resetCursorRects() {
        if grid?.model.keywordPainter.isOn == true {
            addCursorRect(visibleRect, cursor: KeywordPainter.cursor)
        }
    }

    override func keyDown(with event: NSEvent) {
        if grid?.handle(event) != true {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        grid?.pressed(event)
    }

    override func mouseDragged(with event: NSEvent) {
        grid?.dragged(event)
    }

    override func mouseUp(with event: NSEvent) {
        grid?.released(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        grid?.menu(at: convert(event.locationInWindow, from: nil))
    }

    override func didCloseMenu(_: NSMenu, with _: NSEvent?) {
        grid?.menuClosed()
    }

    override func accessibilityChildren() -> [Any]? {
        grid?.accessibleCells()
    }

    // MARK: - A keyword dropped (`LibraryGridView+Drag`), or photos moved in their stack (`LibraryGridView+StackDrop`)

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        grid?.dropOperation(sender) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        grid?.dropOperation(sender) ?? []
    }

    override func draggingExited(_: (any NSDraggingInfo)?) {
        grid?.showKeywordTarget(nil)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        grid?.dropped(sender) ?? false
    }

    override func concludeDragOperation(_: (any NSDraggingInfo)?) {
        grid?.showKeywordTarget(nil)
    }
}

@_spi(Harness) public enum LibraryGridViews {
    /// The Library grid on its own, for measurements.
    @MainActor public static func make(model: EditorModel) -> NSView {
        LibraryGridView(model: model)
    }

    /// Scrolls a grid made by `make` to `fraction` (0 ... 1) of its height.
    @MainActor public static func scroll(_ view: NSView, to fraction: Double) {
        guard let grid = view as? LibraryGridView else { return }
        let clip = grid.scrollView.contentView
        let height = max(grid.content.frame.height - clip.bounds.height, 0)
        clip.scroll(to: CGPoint(x: 0, y: height * fraction))
        grid.scrollView.reflectScrolledClipView(clip)
    }

    /// The grid's thumbnails in memory, in bytes.
    @MainActor public static func memoryUsed(_ view: NSView) -> Int {
        (view as? LibraryGridView)?.thumbnails.memoryUsed ?? 0
    }

    /// How many times the grid in `window` has reloaded every cell.
    @MainActor public static func reloads(in window: NSWindow) -> Int? {
        (grid(in: window) as? LibraryGridView)?.reloads
    }

    /// The Library grid in `window`, made by the editor.
    @MainActor public static func grid(in window: NSWindow) -> NSView? {
        func find(_ view: NSView) -> LibraryGridView? {
            (view as? LibraryGridView) ?? view.subviews.lazy.compactMap(find).first
        }
        return (window.contentView?.superview ?? window.contentView).flatMap(find)
    }

    /// The items a grid made by `make` or found by `grid(in:)` has: its cells, and grouped, its headers.
    @MainActor public static func items(in view: NSView) -> Int {
        (view as? LibraryGridView)?.shownCount ?? 0
    }

    /// What the cells on screen of a grid made by `make` or found by `grid(in:)` draw of a Library Health check's
    /// proposals (LIB-40), by the photo's name: the badge's word, and " (framed)" when it's framed.
    @MainActor public static func proposals(in view: NSView) -> [String: String] {
        guard let grid = view as? LibraryGridView else { return [:] }
        var shown: [String: String] = [:]
        for cell in grid.cells.values where !cell.root.isHidden {
            guard let item = cell.item, cell.proposalShown != nil, let mark = cell.healthMark else { continue }
            shown[item.name] = mark.word + (cell.proposalFrames?.frame == nil ? "" : " (framed)")
        }
        return shown
    }

    /// What a click sets in an expanded cell.
    public enum CellPart: Sendable {
        case star(Int), flag, mark
    }

    /// Where a compact cell `size` points wide shows a closed stack's count of `count` photos (LIB-28), 0 ... 1 across
    /// and down the cell.
    public static func point(ofStackCount count: Int, size: Double) -> CGPoint {
        let width = GridBadges.Kind.stackCount(count, open: false).size.width
        return CGPoint(x: (size - 18 - width / 2) / size, y: 9 / size)
    }

    /// Where `part` of an expanded cell `size` points wide is, 0 ... 1 across and down the cell.
    public static func point(of part: CellPart, size: Double) -> CGPoint {
        let geometry = GridCellGeometry(size: CGFloat(size), style: .expanded)
        let cell = geometry.cellSize
        let point = switch part {
        case let .star(stars):
            CGPoint(
                x: geometry.rating.x + 4 + 7 * CGFloat(stars - 1) + 3.5,
                y: cell.height - GridCellGeometry.footerHeight / 2,
            )
        case .flag: geometry.flag
        case .mark: geometry.mark
        }
        return CGPoint(x: point.x / cell.width, y: point.y / cell.height)
    }
}
