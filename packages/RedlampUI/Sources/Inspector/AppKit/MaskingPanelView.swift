import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The Masking tool's panel: masks list, create menu, components and local adjustments.
///
/// The local adjustment sliders are AppKit, like the Develop panels'. The lists and menus
/// are the SwiftUI panel's own, hosted separately; they read `maskOutlines` and update
/// themselves, so they are made once. Only the selected mask's editor is rebuilt, when that
/// mask's outline or its tools change; dragging a mask's slider touches only that slider.
final class MaskingPanelView: ColumnView {
    private let model: EditorModel
    private var tracker: Tracker?
    private var structure: Structure?

    private lazy var header = panelRows.native(MasksHeaderBar())
    private lazy var createGrid = panelRows.native(CreateMaskGrid(
        title: "Create New Mask",
        onLandscapeClass: { [model] cls in Task { await model.createAIMask(.landscape, landscape: cls) } },
    ) { [model] kind in
        model.startDrawing(kind)
    }.padding(.horizontal, Metrics.panelPadding).padding(.bottom, 12))
    private lazy var list = panelRows.native(MaskList().padding(.horizontal, Metrics.panelPadding))
    private lazy var actions = panelRows.native(MaskActionsBar())
    private lazy var status = panelRows.native(MaskStatus())
    private lazy var drawingHint = panelRows.native(DrawingHint())
    private lazy var noSelection = panelRows.native(NoMaskSelected())
    private let divider = DividerView()
    /// Each mask's editor, kept while the mask exists so switching between masks reuses it.
    private var editors: [UUID: Editor] = [:]

    private struct Editor {
        var mask: MaskOutline
        var tools: MaskKind?
        var view: ColumnView
    }

    private var panelRows: PanelRows {
        PanelRows(model: model)
    }

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
                drawing: model.drawingKind != nil || model.isRefiningEdges,
                status: model.aiMaskProgress != nil || model.maskMessage != nil || model.pendingModel != nil
                    || model.modelDownloadProgress != nil,
            )
            guard next != structure else { return }
            let previous = structure
            structure = next
            let views = rows(for: next)
            if !views.elementsEqual(arrangedViews, by: ===) {
                setArrangedViews(views)
            } else if next.outlines.count != previous?.outlines.count {
                // The list has a row per mask; nothing else re-measures the column when it grows or shrinks.
                invalidateColumnLayout()
            }
        }
    }

    private func rows(for structure: Structure) -> [NSView] {
        let hint: [NSView] = (structure.status ? [status] : []) + (structure.drawing ? [drawingHint] : [])
        let ids = Set(structure.outlines.map(\.id))
        editors = editors.filter { ids.contains($0.key) }
        guard !structure.outlines.isEmpty else {
            return [header, createGrid] + hint
        }
        return [header, list, actions] + hint + [divider, editorView(for: structure)]
    }

    private func editorView(for structure: Structure) -> NSView {
        guard let mask = structure.selected else {
            return noSelection
        }
        // Showing or hiding the mask changes nothing in its editor.
        if let editor = editors[mask.id], editor.mask.name == mask.name,
           editor.mask.components == mask.components, editor.tools == structure.tools {
            return editor.view
        }
        let view = editorColumn(mask, tools: structure.tools, rows: panelRows)
        editors[mask.id] = Editor(mask: mask, tools: structure.tools, view: view)
        return view
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
