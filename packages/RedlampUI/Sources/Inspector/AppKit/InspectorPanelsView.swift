import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The inspector's scrolling column, in AppKit: the Develop panels, or the active tool's
/// panel. Each control updates only when a value it shows changes.
final class InspectorPanelsView: PanelColumnScrollView {
    init(model: EditorModel, tool: EditTool) {
        super.init(views: Self.content(for: tool, model: model))
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
            [
                HostedControl(model: model, CropToolPanel()),
                // Slider rows get their insets from a panel; this one has no panel around it.
                ColumnView(
                    spacing: Metrics.panelRowSpacing,
                    insets: NSEdgeInsets(
                        top: 0, left: Metrics.panelPadding, bottom: Metrics.panelBottomPadding,
                        right: Metrics.panelPadding,
                    ),
                    views: PanelRows(model: model).sliders([.cropAngle]),
                ),
            ]
        case .heal:
            [
                HostedControl(model: model, HealToolPanel()),
                ColumnView(
                    spacing: Metrics.panelRowSpacing,
                    insets: NSEdgeInsets(
                        top: 0, left: Metrics.panelPadding, bottom: Metrics.panelBottomPadding,
                        right: Metrics.panelPadding,
                    ),
                    views: PanelRows(model: model).sliders(ParameterID.spotParameters),
                ),
            ]
        default:
            [HostedControl(model: model, PlannedToolCard(tool: tool))]
        }
    }
}
