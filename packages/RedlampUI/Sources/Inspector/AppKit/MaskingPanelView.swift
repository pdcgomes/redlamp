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
        var componentKind: MaskKind?
        var drawing: Bool
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
        tracker = Tracker { [weak self] in
            guard let self else { return }
            let next = Structure(
                outlines: model.maskOutlines,
                selected: model.selectedOutline,
                componentKind: model.selectedComponentOutline?.kind,
                drawing: model.drawingKind != nil,
            )
            guard next != structure else { return }
            structure = next
            setArrangedViews(rows(for: next))
        }
    }

    private func rows(for structure: Structure) -> [NSView] {
        let rows = PanelRows(model: model)
        let hint: [NSView] = structure.drawing ? [rows.native(DrawingHint())] : []
        guard !structure.outlines.isEmpty else {
            return [
                rows.native(MasksHeaderBar()),
                rows.native(CreateMaskGrid(title: "Create New Mask") { [model] kind in
                    model.startDrawing(kind)
                }.padding(.horizontal, Metrics.panelPadding).padding(.bottom, 12)),
            ] + hint
        }
        let editor: NSView = if let mask = structure.selected {
            editorColumn(mask, radial: structure.componentKind == .radial, rows: rows)
        } else {
            rows.native(NoMaskSelected())
        }
        return [
            rows.native(MasksHeaderBar()),
            rows.native(MaskList().padding(.horizontal, Metrics.panelPadding)),
            rows.native(MaskActionsBar()),
        ] + hint + [DividerView(), editor]
    }

    private func editorColumn(_ mask: MaskOutline, radial: Bool, rows: PanelRows) -> ColumnView {
        var views: [NSView] = [rows.header("Components", [])]
        views += mask.components.map { rows.native(ComponentRow(mask: mask, component: $0)) }
        views.append(rows.native(ComponentOperationMenus(mask: mask).padding(.top, 4)))
        if radial {
            views.append(PaddingView(rows.slider(.maskFeather), top: 6))
        }
        views.append(rows.header(mask.name, [], accessory: rows.native(ResetMaskButton(mask: mask))))
        views += [rows.slider(.maskAmount), rows.gap()]
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
