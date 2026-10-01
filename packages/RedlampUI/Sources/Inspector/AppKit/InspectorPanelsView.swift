import AppKit
import RedlampDesign
import SwiftUI

/// The inspector's scrolling column, in AppKit: the Develop panels, or the Masking tool's
/// panel. Each control updates only when a value it shows changes.
final class InspectorPanelsView: NSView {
    private let scrollView = OverlayScrollView()
    private let document: InspectorDocumentView

    init(model: EditorModel, tool: EditTool) {
        document = InspectorDocumentView(views: Self.content(for: tool, model: model))
        super.init(frame: .zero)
        scrollView.documentView = document
        addSubview(scrollView)
        document.onHeightChange = { [weak self] in self?.sizeDocument() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func content(for tool: EditTool, model: EditorModel) -> [NSView] {
        switch tool {
        case .edit:
            [
                BasicPanelView.make(model: model),
                ToneCurvePanelView.make(model: model),
                ColorMixerPanelView.make(model: model),
                ColorGradingPanelView.make(model: model),
                ReferencePanelViews.detail(model: model),
                ReferencePanelViews.lens(model: model),
                ReferencePanelViews.transform(model: model),
                ReferencePanelViews.effects(model: model),
                ReferencePanelViews.calibration(model: model),
            ]
        case .masking:
            [MaskingPanelView(model: model)]
        case .crop:
            [HostedControl(model: model, CropToolPanel())] + PanelRows(model: model).sliders([.cropAngle])
        default:
            [HostedControl(model: model, PlannedToolCard(tool: tool))]
        }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        sizeDocument()
    }

    private func sizeDocument() {
        let width = scrollView.contentView.bounds.width
        let size = CGSize(width: width, height: document.height(forWidth: width))
        if document.frame.size != size {
            document.setFrameSize(size)
        }
        document.layoutSubtreeIfNeeded()
    }
}

/// The scroll view's document: the panels, top to bottom.
final class InspectorDocumentView: ColumnView, ColumnHost {
    var onHeightChange: () -> Void = {}

    init(views: [NSView]) {
        super.init(views: views)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func columnContentDidChange() {
        onHeightChange()
    }
}
