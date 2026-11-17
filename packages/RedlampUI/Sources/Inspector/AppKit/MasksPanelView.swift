import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The Masking tool's panels (`MasksPanel`) in AppKit, cards as the Develop panels are: Masks,
/// the selected mask with its components, and its Adjustments.
///
/// The selected mask's sliders are AppKit. The header's controls, the picker, the list, the People
/// and Landscape pickers, the component rows, the Effect row and the menus are the SwiftUI panel's
/// own, hosted one by one; they read the model and update themselves, so they are made once. Only
/// the selected mask's two panels are rebuilt, when its name, its components or its tools change;
/// dragging a slider, or choosing an effect, touches only the sliders it moves.
final class MasksPanelView: ColumnView {
    private let model: EditorModel
    private var tracker: Tracker?
    private var structure: Structure?
    /// Finds who People components are of as the masks change, as the SwiftUI panel's task does.
    private var naming: Task<Void, Never>?

    private lazy var newMask = padded(NewMaskRow())
    private lazy var drawingHint = padded(DrawingHint())
    private lazy var messages = padded(MaskMessages())
    private lazy var peoplePicker = padded(OpenPeoplePicker())
    private lazy var landscapePicker = padded(OpenLandscapePicker())
    private lazy var picker = padded(MaskPicker(mode: .new, inline: true).padding(.bottom, 8))
    private lazy var list = panelRows.native(
        MaskList()
            .padding(.bottom, 8)
            .background(MaskThumbnailRefresher()),
    )
    private lazy var noSelection = padded(NoMaskSelected())
    /// The photo's masks, above New Mask, with the controls for every mask in its header. The list
    /// reaches the card's sides, so the rows pad themselves: at the sides (`padded`), and at the bottom, as the
    /// list and what takes its place need different room.
    private(set) lazy var masksPanel = PanelSectionView(
        maskPanel: .masks,
        model: model,
        accessory: panelRows.native(MasksHeaderControls()),
        insets: NSEdgeInsets(top: 0, left: 0, bottom: 2, right: 0),
        rows: [],
    )
    /// Each mask's panels, kept while the mask exists so switching between masks reuses them.
    private var editors: [UUID: Editor] = [:]

    private struct Editor {
        var mask: MaskOutline
        var tools: MaskKind?
        var settings: PanelSectionView
        var adjustments: PanelSectionView
    }

    private var panelRows: PanelRows {
        PanelRows(model: model)
    }

    /// A row of the Masks panel, in from the card's sides as a panel's rows are.
    private func padded(_ view: some View) -> HostedControl {
        panelRows.native(view.padding(.horizontal, Metrics.panelCardPadding))
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
        super.init(spacing: Metrics.panelCardGap)
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
                    || model.offeredModels != nil || model.modelDownloadProgress != nil,
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
            let rows = masksRows(for: next)
            if !rows.elementsEqual(masksPanel.rows, by: ===) {
                masksPanel.setRows(rows)
            } else if next.outlines.count != previous?.outlines.count {
                // The list has a row per mask; nothing else re-measures the column when it grows or shrinks.
                list.invalidateColumnLayout()
            }
            if next.outlines.isEmpty != previous?.outlines.isEmpty {
                // New Mask's row gives way to Mask Presets under a label, which is taller.
                newMask.invalidateColumnLayout()
            }
            let panels = [masksPanel] + editorPanels(for: next)
            if !panels.elementsEqual(arrangedViews, by: ===) {
                setArrangedViews(panels)
            }
        }
    }

    /// The Masks panel's rows: the drawing hint and messages, then the list, or the picker or the
    /// People or Landscape picker in its place, and New Mask last.
    private func masksRows(for structure: Structure) -> [NSView] {
        var views: [NSView] = []
        if structure.drawing {
            views.append(drawingHint)
        }
        if structure.messages {
            views.append(messages)
        }
        if structure.choosingPeople {
            return views + [peoplePicker, newMask]
        }
        if structure.choosingLandscape {
            return views + [landscapePicker, newMask]
        }
        guard !structure.outlines.isEmpty else {
            return views + [picker, newMask]
        }
        return views + [list] + (structure.selected == nil ? [noSelection] : []) + [newMask]
    }

    /// The selected mask's panels, which the People and Landscape pickers put away while they're open.
    private func editorPanels(for structure: Structure) -> [NSView] {
        let ids = Set(structure.outlines.map(\.id))
        editors = editors.filter { ids.contains($0.key) }
        guard !structure.choosingPeople, !structure.choosingLandscape, let mask = structure.selected else {
            return []
        }
        // Showing, hiding or inverting the mask changes nothing in its panels' rows.
        if let editor = editors[mask.id], editor.mask.name == mask.name,
           editor.mask.components == mask.components, editor.mask.hasPointColor == mask.hasPointColor,
           editor.tools == structure.tools {
            return [editor.settings, editor.adjustments]
        }
        let editor = Editor(
            mask: mask,
            tools: structure.tools,
            settings: settingsPanel(mask, tools: structure.tools, rows: panelRows),
            adjustments: adjustmentsPanel(mask, rows: panelRows),
        )
        editors[mask.id] = editor
        return [editor.settings, editor.adjustments]
    }

    /// The selected mask's own panel, in `MaskSettings`' order under its name and Invert: Amount
    /// and Detail, its components, then the selected component's settings.
    private func settingsPanel(_ mask: MaskOutline, tools: MaskKind?, rows: PanelRows) -> PanelSectionView {
        var views: [NSView] = [
            rows.slider(.maskAmount),
            rows.slider(.maskDetail),
            rows.gap(6),
            rows.header("Components, applied top to bottom", []),
        ]
        views += mask.components.map { rows.native(ComponentRow(mask: mask, component: $0)) }
        views.append(rows.native(ComponentOperationButtons(mask: mask).padding(.top, 4)))
        views += componentTools(tools, mask: mask, rows: rows)
        return PanelSectionView(
            maskPanel: .mask,
            model: model,
            title: mask.name,
            accessory: rows.native(HStack { MaskHeaderControls(mask: mask) }),
            rows: views,
        )
    }

    /// The selected mask's adjustments, in `MaskAdjustments`' order: the effect, the sliders, Color,
    /// Curves and Point Color.
    private func adjustmentsPanel(_ mask: MaskOutline, rows: PanelRows) -> PanelSectionView {
        var views: [NSView] = [rows.native(MaskEffectMenu(mask: mask))]
        for parameter in ParameterID.localParameters where !ParameterID.swatchParameters.contains(parameter) {
            views.append(rows.slider(parameter))
            if MasksPanel.gapAfter.contains(parameter) {
                views.append(rows.gap())
            }
        }
        views.append(rows.native(MaskColorSwatch()))
        views.append(rows.native(MaskCurvesEditor().padding(.top, 6)))
        views += pointColorRows(mask, rows: rows)
        let id = mask.id
        return PanelSectionView(
            maskPanel: .adjustments,
            model: model,
            rows: views,
            editedItems: { [model] in model.editedAdjustments(of: id) },
            reset: { [model] in model.resetMaskAdjustments(id) },
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

extension PanelSectionView {
    /// One of the Masking tool's panels, as a card: it expands and collapses as a Develop panel
    /// does, Solo Mode included, and has no eye. With `editedItems` it shows an Edited chip, and
    /// with `reset` a double-click on its header and its menu reset it.
    convenience init(
        maskPanel panel: MaskPanelID,
        model: EditorModel,
        title: String? = nil,
        accessory: NSView? = nil,
        insets: NSEdgeInsets = PanelSectionView.bodyInsets,
        rows: [NSView],
        editedItems: (@MainActor () -> [String])? = nil,
        reset: (@MainActor () -> Void)? = nil,
    ) {
        self.init(
            title: title ?? panel.title,
            symbol: panel.symbol,
            accessory: accessory,
            style: .card,
            insets: insets,
            rows: rows,
            actions: Actions(
                isExpanded: { model.isExpanded(panel) },
                isEdited: { editedItems.map { !$0().isEmpty } ?? false },
                toggle: { solo in model.toggleMaskPanel(panel, solo: solo) },
                reset: { reset?() },
                editedItems: editedItems,
            ),
        )
        identify(as: "masks.panel.\(panel.rawValue)")
        headerMenu = {
            let menu = NSMenu()
            if let reset {
                menu.addItem(NSMenuItem(title: "Reset \(panel.title)") { reset() })
                menu.addItem(.separator())
            }
            menu.addItem(NSMenuItem(title: "Solo Mode", state: model.soloMode ? .on : .off) { model.soloMode.toggle() })
            let all = Set(MaskPanelID.allCases)
            menu.addItem(NSMenuItem(title: "Expand All Panels") { model.expandedMaskPanels = all })
            menu.addItem(NSMenuItem(title: "Collapse All Panels") { model.expandedMaskPanels = [] })
            return menu
        }
    }
}

@_spi(Harness) public enum MasksPanelViews {
    @MainActor public static func make(model: EditorModel) -> NSView {
        MasksPanelView(model: model)
    }
}
