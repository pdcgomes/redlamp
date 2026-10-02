import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The Masking tool's panel: masks list, create menu, components and local adjustments.
///
/// The local adjustment sliders are AppKit, like the Develop panels'. The lists and menus
/// are the SwiftUI panel's own, hosted separately; they read `maskOutlines`, and the panel
/// rebuilds its rows only when that structure, the selection or the drawing state changes,
/// so dragging a mask's slider touches only that slider.
final class MaskingPanelView: ColumnView {
    private let model: EditorModel
    private var tracker: Tracker?
    private var structure: Structure?

    /// What the rows depend on (everything but adjustment values).
    private struct Structure: Equatable {
        var outlines: [MaskOutline]
        var selected: MaskOutline?
        /// Which component settings show (see `MaskingPanel.componentTools`).
        var tools: MaskKind?
        var drawing: Bool
        var status: Bool
    }

    init(model: EditorModel) {
        self.model = model
        super.init()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tracker?.cancel()
        tracker = nil
        guard window != nil else { return }
        // The Masking tool is open: get AI masks ready for this photo and the next ones.
        model.engine.warmUpMasks()
        tracker = Tracker { [weak self] in
            guard let self else { return }
            let next = Structure(
                outlines: model.maskOutlines,
                selected: model.selectedOutline,
                tools: MaskingPanel.componentTools(model),
                drawing: model.drawingKind != nil,
                status: model.aiMaskProgress != nil || model.maskMessage != nil || model.pendingModel != nil
                    || model.modelDownloadProgress != nil,
            )
            guard next != structure else { return }
            structure = next
            setArrangedViews(rows(for: next))
        }
    }

    private func rows(for structure: Structure) -> [NSView] {
        let rows = PanelRows(model: model)
        let hint: [NSView] = (structure.status ? [rows.native(MaskStatus())] : [])
            + (structure.drawing ? [rows.native(DrawingHint())] : [])
        guard !structure.outlines.isEmpty else {
            return [
                rows.native(MasksHeaderBar()),
                rows.native(CreateMaskGrid(title: "Create New Mask") { [model] kind in
                    model.startDrawing(kind)
                }.padding(.horizontal, Metrics.panelPadding).padding(.bottom, 12)),
            ] + hint
        }
        let editor: NSView = if let mask = structure.selected {
            editorColumn(mask, tools: structure.tools, rows: rows)
        } else {
            rows.native(NoMaskSelected())
        }
        return [
            rows.native(MasksHeaderBar()),
            rows.native(MaskList().padding(.horizontal, Metrics.panelPadding)),
            rows.native(MaskActionsBar()),
        ] + hint + [DividerView(), editor]
    }

    private func editorColumn(_ mask: MaskOutline, tools: MaskKind?, rows: PanelRows) -> ColumnView {
        var views: [NSView] = [rows.header("Components", [])]
        views += mask.components.map { rows.native(ComponentRow(mask: mask, component: $0)) }
        views.append(rows.native(ComponentOperationMenus(mask: mask).padding(.top, 4)))
        switch tools {
        case .radial:
            views.append(PaddingView(rows.slider(.maskFeather), top: 6))
        case .brush:
            views.append(PaddingView(rows.native(BrushChoicePicker()), top: 6))
            views += ParameterID.brushParameters.map { rows.slider($0) }
            views.append(rows.native(AutoMaskToggle()))
        case .colorRange:
            views.append(PaddingView(rows.slider(.maskColorRefine), top: 6))
            views.append(rows.native(ColorSampleList()))
        case .luminanceRange:
            views.append(PaddingView(rows.native(LuminanceRangeEditor()), top: 6))
        case .depthRange:
            views.append(PaddingView(rows.native(DepthRangeEditor()), top: 6))
        default:
            break
        }
        views.append(rows.header(mask.name, [], accessory: rows.native(ResetMaskButton(mask: mask))))
        views += [rows.slider(.maskAmount), rows.slider(.maskDetail), rows.gap()]
        for parameter in ParameterID.localParameters {
            views.append(rows.slider(parameter))
            if MaskingPanel.gapAfter.contains(parameter) {
                views.append(rows.gap())
            }
        }
        return ColumnView(
            spacing: Metrics.panelRowSpacing,
            insets: NSEdgeInsets(
                top: 0,
                left: Metrics.panelPadding,
                bottom: Metrics.panelBottomPadding,
                right: Metrics.panelPadding,
            ),
            views: views,
        )
    }
}

@_spi(Harness) public enum MaskingPanelViews {
    @MainActor public static func make(model: EditorModel) -> NSView {
        MaskingPanelView(model: model)
    }
}
