import AppKit
import RedlampDesign
import SwiftUI

/// The whole right-hand column in AppKit: histogram and tool strip, the active tool's
/// panels, and the Previous / Reset footer. SwiftUI lays out none of it; its native
/// controls are hosted one by one.
final class InspectorColumnView: NSView {
    private let model: EditorModel
    private let top: ColumnView
    private let topDivider = DividerView()
    private let bottomDivider = DividerView()
    private let footer: HostedControl
    private var panels: InspectorPanelsView
    private var shownTool: EditTool
    private var tracker: Tracker?

    init(model: EditorModel) {
        self.model = model
        top = ColumnView(
            spacing: 10,
            insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12),
            views: [HistogramGraphView(model: model), ToolStripView(model: model)],
        )
        footer = HostedControl(model: model, InspectorFooter())
        shownTool = model.activeTool
        panels = InspectorPanelsView(model: model, tool: shownTool)
        super.init(frame: .zero)
        [top, topDivider, panels, bottomDivider, footer].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        tracker = Tracker { [weak self] in
            guard let self else { return }
            let tool = model.activeTool
            guard tool != shownTool else { return }
            shownTool = tool
            let next = InspectorPanelsView(model: model, tool: tool)
            replaceSubview(panels, with: next)
            panels = next
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let topHeight = top.height(forWidth: width)
        top.frame = CGRect(x: 0, y: 0, width: width, height: topHeight)
        topDivider.frame = CGRect(x: 0, y: topHeight, width: width, height: 1)
        let footerHeight = footer.height(forWidth: width)
        footer.frame = CGRect(x: 0, y: bounds.height - footerHeight, width: width, height: footerHeight)
        bottomDivider.frame = CGRect(x: 0, y: footer.frame.minY - 1, width: width, height: 1)
        panels.frame = CGRect(
            x: 0,
            y: topHeight + 1,
            width: width,
            height: max(bottomDivider.frame.minY - topHeight - 1, 0),
        )
    }
}

@_spi(Harness) public enum InspectorColumnViews {
    @MainActor public static func make(model: EditorModel) -> NSView {
        InspectorColumnView(model: model)
    }
}
