import AppKit
import RedlampDesign

/// Crop, healing, red eye and masking tools, as in Lightroom's tool strip. Click a tool to
/// open it, click it again to go back to Edit.
final class ToolStripView: LayerDrawnView, HeightProviding, NSViewToolTipOwner {
    private let model: EditorModel
    private var tracker: Tracker?
    private var active = EditTool.edit
    private static let tools = EditTool.allCases
    private static let padding: CGFloat = 3
    private static let spacing: CGFloat = 2
    private static let cellHeight: CGFloat = 26

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func height(forWidth _: CGFloat) -> CGFloat {
        Self.cellHeight + Self.padding * 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            active = model.activeTool
            setNeedsContentDisplay()
        }
    }

    override func layout() {
        super.layout()
        removeAllToolTips()
        for index in Self.tools.indices {
            addToolTip(cell(index), owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
    }

    /// The tools share the strip's width equally, like SwiftUI's `maxWidth: .infinity` cells.
    /// Backgrounds use the cell on the pixel grid; icons center on the exact cell, as the
    /// SwiftUI image frame does before it is rounded.
    private func exactCell(_ index: Int) -> CGRect {
        let count = CGFloat(Self.tools.count)
        let width = (bounds.width - Self.padding * 2 - Self.spacing * (count - 1)) / count
        return CGRect(
            x: Self.padding + CGFloat(index) * (width + Self.spacing),
            y: Self.padding,
            width: width,
            height: Self.cellHeight,
        )
    }

    private func cell(_ index: Int) -> CGRect {
        PixelGrid.snap(exactCell(index), scale: backingScale)
    }

    override func drawContent(in _: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.setFillColor(Palette.well.cgColor)
        context.fillPath()
        for (index, tool) in Self.tools.enumerated() {
            let rect = cell(index)
            let selected = tool == active
            if selected {
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                context.setFillColor(Palette.selection.cgColor)
                context.fillPath()
            }
            let exact = exactCell(index)
            Symbol.draw(
                tool.symbol, pointSize: 13, color: selected ? Palette.value : Palette.secondaryLabel,
                centeredAt: CGPoint(x: exact.midX, y: exact.midY), scale: backingScale,
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let index = Self.tools.indices.first(where: { cell($0).contains(location) }) else { return }
        let tool = Self.tools[index]
        model.activeTool = model.activeTool == tool && tool != .edit ? .edit : tool
    }

    func view(
        _: NSView,
        stringForToolTip _: NSView.ToolTipTag,
        point _: NSPoint,
        userData: UnsafeMutableRawPointer?,
    ) -> String {
        let tool = Self.tools[max(0, min(Int(bitPattern: userData) - 1, Self.tools.count - 1))]
        return tool.shortcut.isEmpty ? tool.title : "\(tool.title) (\(tool.shortcut))"
    }
}
