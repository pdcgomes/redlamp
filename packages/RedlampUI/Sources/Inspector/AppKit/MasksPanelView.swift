import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The Masks panel (`MasksPanel`) in AppKit, as the Develop panels are.
///
/// The selected mask's sliders are AppKit. The header, the picker, the list, the People and
/// Landscape pickers, the component rows and the menus are the SwiftUI panel's own, hosted one
/// by one; they read the model and update themselves, so they are made once. Only the selected
/// mask's settings are rebuilt, when its name, its components or its tools change; dragging a
/// slider touches only that slider.
final class MasksPanelView: ColumnView {
    private let model: EditorModel
    private var tracker: Tracker?
    private var structure: Structure?
    /// Finds who People components are of as the masks change, as the SwiftUI panel's task does.
    private var naming: Task<Void, Never>?

    private lazy var header = panelRows.native(MasksHeaderNext())
    private lazy var drawingHint = panelRows.native(DrawingHint())
    private lazy var messages = panelRows.native(MaskMessages())
    private lazy var peoplePicker = panelRows.native(OpenPeoplePicker())
    private lazy var landscapePicker = panelRows.native(OpenLandscapePicker())
    private lazy var picker = panelRows.native(
        MaskPicker(mode: .new, inline: true)
            .padding(.horizontal, Metrics.panelPadding)
            .padding(.bottom, 12),
    )
    private lazy var list = panelRows.native(
        MaskList()
            .padding(.horizontal, Metrics.panelPadding)
            .padding(.bottom, 8)
            .background(MaskThumbnailRefresher()),
    )
    private lazy var noSelection = panelRows.native(NoMaskSelected())
    private let divider = DividerView()
    /// Each mask's settings, kept while the mask exists so switching between masks reuses them.
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
        /// Which component settings show (see `MasksPanel.componentTools`).
        var tools: MaskKind?
        var drawing: Bool
        var messages: Bool
        var choosingPeople: Bool
        var choosingLandscape: Bool
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
        naming?.cancel()
        naming = nil
        guard window != nil else { return }
        // The Masking tool is open: get AI masks ready for this photo and the next ones.
        model.engine.warmUpMasks()
        tracker = Tracker { [weak self] in
            guard let self else { return }
            let next = Structure(
                outlines: model.maskOutlines,
                selected: model.selectedOutline,
                tools: MasksPanel.componentTools(model),
                drawing: model.drawingKind != nil || model.isRefiningEdges,
                messages: model.aiMaskProgress != nil || model.maskMessage != nil || model.pendingModel != nil
                    || model.modelDownloadProgress != nil,
                choosingPeople: model.peoplePicker != nil,
                choosingLandscape: model.landscapePicker != nil,
            )
            guard next != structure else { return }
            let previous = structure
            structure = next
            if next.outlines != previous?.outlines {
                naming?.cancel()
                naming = Task { [model] in await model.findPeopleForNames() }
            }
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
        let ids = Set(structure.outlines.map(\.id))
        editors = editors.filter { ids.contains($0.key) }
        var views: [NSView] = [header]
        if structure.drawing {
            views.append(drawingHint)
        }
        if structure.messages {
            views.append(messages)
        }
        if structure.choosingPeople {
            return views + [peoplePicker]
        }
        if structure.choosingLandscape {
            return views + [landscapePicker]
        }
        guard !structure.outlines.isEmpty else {
            return views + [picker]
        }
        return views + [list, divider, editorView(for: structure)]
    }

    private func editorView(for structure: Structure) -> NSView {
        guard let mask = structure.selected else {
            return noSelection
        }
        // Showing, hiding or inverting the mask changes nothing in its settings' rows.
        if let editor = editors[mask.id], editor.mask.name == mask.name,
           editor.mask.components == mask.components, editor.mask.hasPointColor == mask.hasPointColor,
           editor.tools == structure.tools {
            return editor.view
        }
        let view = editorColumn(mask, tools: structure.tools, rows: panelRows)
        editors[mask.id] = Editor(mask: mask, tools: structure.tools, view: view)
        return view
    }

    /// The selected mask's settings, in `SelectedMaskEditor`'s order: the mask's name with
    /// Invert and Amount, its components, the selected component's settings, then the adjustments.
    private func editorColumn(_ mask: MaskOutline, tools: MaskKind?, rows: PanelRows) -> ColumnView {
        var views: [NSView] = [
            rows.header(mask.name, [], accessory: rows.native(HStack { MaskHeaderControls(mask: mask) })),
            rows.slider(.maskAmount),
            rows.gap(6),
            rows.header("Components, applied top to bottom", []),
        ]
        views += mask.components.map { rows.native(ComponentRow(mask: mask, component: $0)) }
        views.append(rows.native(ComponentOperationButtons(mask: mask).padding(.top, 4)))
        views += componentTools(tools, mask: mask, rows: rows)
        views += [rows.gap(6), rows.slider(.maskDetail), rows.gap()]
        for parameter in ParameterID.localParameters where !ParameterID.swatchParameters.contains(parameter) {
            views.append(rows.slider(parameter))
            if MasksPanel.gapAfter.contains(parameter) {
                views.append(rows.gap())
            }
        }
        views.append(rows.native(MaskColorSwatch()))
        views.append(rows.native(MaskCurvesEditor().padding(.top, 6)))
        views += pointColorRows(mask, rows: rows)
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

extension MasksPanelView {
    /// The selected component's own settings: the brush's while brushing, a radial gradient's
    /// feather, a range's samples or stops, and an AI component's Feather, Edge and refinements.
    private func componentTools(_ tools: MaskKind?, mask: MaskOutline, rows: PanelRows) -> [NSView] {
        switch tools {
        case .radial:
            [PaddingView(rows.slider(.maskFeather), top: 6)]
        case .brush:
            [PaddingView(rows.native(BrushChoicePicker()), top: 6)]
                + ParameterID.brushParameters.map { rows.slider($0) }
                + [rows.native(AutoMaskToggle())]
        case .colorRange:
            [PaddingView(rows.slider(.maskColorRefine), top: 6), rows.native(ColorSampleList())]
        case .luminanceRange:
            // `LuminanceRangeEditor`'s two parts, 6 pt apart.
            [
                PaddingView(rows.native(LuminanceRangeBar()), top: 6),
                PaddingView(rows.native(LuminanceMapToggle()), top: 6 - Metrics.panelRowSpacing),
            ]
        case .depthRange:
            [PaddingView(rows.native(DepthRangeEditor()), top: 6)]
        case let kind? where kind.isAI:
            [
                PaddingView(rows.slider(.maskAIFeather), top: 6),
                rows.slider(.maskAIEdge),
                rows.native(AIComponentTools(mask: mask)),
            ]
        default:
            []
        }
    }

    /// The mask's Point Color: its swatches, and once it has one, the selected swatch's sliders.
    private func pointColorRows(_ mask: MaskOutline, rows: PanelRows) -> [NSView] {
        var views: [NSView] = [
            rows.header("Point Color", ParameterID.pointColorParameters),
            rows.native(PointColorSwatches(ownColor: true).padding(.bottom, 2)),
        ]
        guard mask.hasPointColor else { return views }
        for group in PointColorGroup.all {
            views += group.parameters.map { rows.slider($0) }
            views.append(rows.gap())
        }
        views.append(rows.native(PointColorVisualizeToggle()))
        return views
    }
}

@_spi(Harness) public enum MasksPanelViews {
    @MainActor public static func make(model: EditorModel) -> NSView {
        MasksPanelView(model: model)
    }
}
