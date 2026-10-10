import AppKit
import RedlampDesign
import RedlampEngineAPI
import SwiftUI

// The Masks panel's parts, shared by the SwiftUI panel (`MasksPanel`) and its AppKit port
// (`MasksPanelView`). The lists read `maskOutlines`, so dragging a mask's sliders doesn't
// re-render them.

/// The overlay's mode, and for the modes that tint, its color and opacity, as Lightroom's overlay
/// options.
struct MaskOverlayOptions: View {
    @Environment(EditorModel.self) private var model
    private static let opacitySpec = FieldSpec(range: 0 ... 100, unit: "%")

    var body: some View {
        @Bindable var model = model
        let tints = model.maskOverlayStyle.tints
        Grid(alignment: .leading, verticalSpacing: 8) {
            GridRow {
                Text("Mode")
                Picker("Mode", selection: $model.maskOverlayStyle) {
                    ForEach(MaskOverlayStyle.menu, id: \.self) { style in
                        Text(style.name).tag(style)
                    }
                }
                .labelsHidden()
                .automationIdentifier("masks.overlay.mode")
            }
            GridRow {
                Text("Color")
                Picker("Color", selection: $model.maskOverlayColor) {
                    ForEach(MaskOverlayColor.allCases, id: \.self) { color in
                        Text(color.name).tag(color)
                    }
                }
                .labelsHidden()
                .disabled(!tints)
                .automationIdentifier("masks.overlay.color")
            }
            GridRow {
                Text("Opacity")
                HStack {
                    Slider(value: $model.maskOverlayOpacity, in: 0 ... 1)
                    ValueFieldControl(
                        spec: Self.opacitySpec, value: (model.maskOverlayOpacity * 100).rounded(),
                        identifier: "masks.overlay.opacity", onChange: { model.maskOverlayOpacity = $0 / 100 },
                    )
                    .frame(width: ValueFieldControl.width(for: "100%"), height: Metrics.rowHeight)
                }
                .disabled(!tints)
            }
        }
        .font(Theme.labelFont)
        .controlSize(.small)
        .padding(12)
        .frame(width: 250)
    }
}

/// Drag to reorder: the row carries `payload`, and a row dropped on by another of its kind gives
/// it its place.
private struct Reorderable: ViewModifier {
    let payload: String
    let isEnabled: Bool
    let drop: (String) -> Bool
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .draggable(payload)
                .dropDestination(for: String.self) { items, _ in
                    items.first.map(drop) ?? false
                } isTargeted: { isTargeted = $0 }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                    Color.accentColor,
                    lineWidth: isTargeted ? 1.5 : 0,
                ))
        } else {
            content
        }
    }

    /// The ID in a payload of `kind`, or nil for anything else dropped.
    static func id(in payload: String, kind: String) -> UUID? {
        guard payload.hasPrefix("redlamp.\(kind):") else { return nil }
        return UUID(uuidString: String(payload.dropFirst("redlamp.\(kind):".count)))
    }
}

/// The mask's Color swatch: a tint of a hue and saturation over what the mask covers, picked on a
/// wheel as Color Grading's are.
struct MaskColorSwatch: View {
    @Environment(EditorModel.self) private var model
    @State private var picking = false

    var body: some View {
        let hue = model.sliderValue(.localColorHue)
        let saturation = model.sliderValue(.localColorSaturation)
        HStack {
            Text("Color")
                .font(Theme.labelFont)
                .foregroundStyle(Theme.label)
            Spacer()
            Button {
                picking.toggle()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(saturation > 0 ? Color
                            .wheelHue(hue, saturation: saturation / 100, brightness: 0.95) : .clear)
                    if saturation == 0 {
                        Path { path in
                            path.move(to: CGPoint(x: 2, y: 14))
                            path.addLine(to: CGPoint(x: 32, y: 2))
                        }
                        .stroke(Color.red.opacity(0.7), lineWidth: 1)
                    }
                    RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.secondaryLabel, lineWidth: 1)
                }
                .frame(width: 34, height: 16)
            }
            .buttonStyle(.plain)
            .help(saturation > 0 ? "Color: hue \(Int(hue))°, saturation \(Int(saturation))" :
                "Color: none. Click to tint the mask")
            .popover(isPresented: $picking, arrowEdge: .leading) {
                VStack(spacing: 10) {
                    ColorWheel(
                        hue: .localColorHue, saturation: .localColorSaturation, label: "Color",
                        stepName: "\(model.selectedMask?.name ?? "Mask") Color", diameter: 150,
                    )
                    ParameterSlider(parameter: .localColorHue)
                    ParameterSlider(parameter: .localColorSaturation)
                }
                .padding(12)
                .frame(width: 240)
                .environment(model)
            }
        }
    }
}

/// The selected mask's Curves: a point curve for every channel, or for red, green or blue, as
/// Lightroom's masks have.
struct MaskCurvesEditor: View {
    @Environment(EditorModel.self) private var model
    @State private var channel = MaskCurves.Channel.rgb

    var body: some View {
        let name = model.selectedMask?.name ?? "Mask"
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Curve")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.label)
                Spacer()
                ChoiceMenu("Channel", selection: $channel)
                    .controlSize(.mini)
                    .fixedSize()
                Button {
                    model.resetMaskCurves()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.selectedMask?.curves == nil)
                .help("Reset the mask's Curves")
            }
            PointCurveGraph(
                points: model.maskCurve(channel), tint: channel.tint,
                begin: { model.beginEdit() },
                change: { model.setMaskCurve(channel, $0) },
                end: { model.endEdit(.mask(nil), "\(name) Curve") },
            )
            .frame(height: 210)
        }
    }
}

private extension MaskCurves.Channel {
    var tint: Color {
        switch self {
        case .rgb: Color(white: 0.9)
        case .red: Color(red: 0.95, green: 0.35, blue: 0.35)
        case .green: Color(red: 0.4, green: 0.85, blue: 0.4)
        case .blue: Color(red: 0.4, green: 0.6, blue: 1)
        }
    }
}

/// What acts on every mask: Update AI Masks (here, or on every selected photo) and Delete All.
struct MaskActionsMenu: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        Menu {
            Button("Update AI Masks") { Task { await model.updateAIMasks() } }
                .disabled(model.aiMaskCount == 0 || model.aiMaskProgress != nil)
            if model.isMultiSelecting {
                Button("Update AI Masks on \(model.selectedPhotos.count) Photos") {
                    Task { await model.updateAIMasksInSelection() }
                }
                .disabled(model.aiMaskProgress != nil || model.settingsSync.progress != nil)
            }
            Divider()
            Button("Delete All Masks", role: .destructive) { model.deleteAllMasks() }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Update AI Masks, Delete All Masks")
        .automationIdentifier("masks.actions")
    }
}

struct NoMaskSelected: View {
    var body: some View {
        Text("Select a mask to edit its adjustments.")
            .font(Theme.labelFont)
            .foregroundStyle(Theme.secondaryLabel)
            .padding(Theme.panelPadding)
    }
}

/// Mask presets: Lightroom-style adaptive ones, which compute their masks for the photo, and
/// the user's own. With several photos selected, a preset goes to each of them (UX-25).
struct MaskPresetsMenu: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        let presets = model.maskPresets
        let builtIn = Set(MaskPreset.builtIn.map(\.id))
        let photos = model.isMultiSelecting ? model.selectedPhotos.count : nil
        Menu {
            if let photos {
                Section("Apply to \(photos) Selected Photos") {
                    choices(presets)
                }
            } else {
                choices(presets)
            }
            let own = presets.filter { !builtIn.contains($0.id) }
            if !own.isEmpty {
                Divider()
                Menu("Delete Preset") {
                    ForEach(own) { preset in
                        Button(preset.name, role: .destructive) { model.deleteMaskPreset(preset.id) }
                    }
                }
            }
        } label: {
            // Its symbol alone: with a label, New Mask beside it has no room at the inspector's width.
            Image(systemName: "wand.and.stars").font(Theme.labelFont)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help(photos.map { "Mask Presets, applied to the \($0) selected photos" } ?? "Mask Presets")
        .accessibilityLabel("Mask Presets")
        .automationIdentifier("masks.presets")
    }

    private func choices(_ presets: [MaskPreset]) -> some View {
        ForEach(presets) { preset in
            Button(preset.name) { Task { await model.applyMaskPreset(preset) } }
                .disabled(!model.canApply(preset) || model.aiMaskProgress != nil)
        }
    }
}

/// An AI mask's model to download, asked before anything downloads (App Review 4.2.3: the size
/// is shown, and nothing downloads without consent). `onDownload` runs as the download starts.
struct ModelDownloadNotice: View {
    var onDownload: () -> Void = {}
    @Environment(EditorModel.self) private var model

    var body: some View {
        if let pending = model.pendingModel {
            NoticeCard(
                "\(pending.kind.name) masks use \(pending.model.name), a \(pending.model.formattedSize) download. It runs on this Mac; your photos are never uploaded. You can remove it in Settings › Models."
                    + (pending.model.licence.map { " Its licence: \($0)." } ?? ""),
                tone: .info, symbol: "arrow.down.circle.fill",
            ) {
                HStack(spacing: 6) {
                    if let url = pending.model.licenceURL {
                        Link("Read the licence", destination: url).font(Theme.labelFont)
                    }
                    Spacer()
                    Button("Not Now") { model.declinePendingModel() }
                        .automationIdentifier("masks.download.notNow")
                    Button("Download") {
                        onDownload()
                        Task { await model.downloadPendingModel() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .automationIdentifier("masks.download")
                }
                .controlSize(.small)
            }
        }
    }
}

struct DrawingHint: View {
    @Environment(EditorModel.self) private var model

    private var hint: String {
        if model.isRefiningEdges {
            return "Paint over an edge to solve it again from the photo, hair by hair. [ and ] or ⌘-scroll change the size."
        }
        return switch model.drawingKind {
        case .radial: "Drag on the photo to draw the radial gradient. Shift keeps it circular."
        case .brush: "Paint on the photo. Hold Option to erase; [ and ] or ⌘-scroll change the size, with Shift the feather. Hold Space to move the photo."
        case .colorRange: "Click or drag on the photo to sample a color. Shift-click adds a sample (up to 5)."
        case .luminanceRange: "Click on the photo to select tones like the one there."
        case .objects: model.objectSelection == .rectangle
            ? "Click an object, or drag a box around it, to select it. Click again to add to it, Option-click to take away."
            : "Click an object, or brush over it, to select it. Click or brush again to add to it, with Option to take away."
        default: "Drag on the photo from full effect to no effect."
        }
    }

    /// Tools that stay armed until Done: each stroke or sample adds to the same component.
    private var staysArmed: Bool {
        [.brush, .colorRange, .luminanceRange, .objects].contains(model.drawingKind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: model.isRefiningEdges ? "wand.and.rays" : model.drawingKind?.symbol ?? "hand.draw")
                Text(hint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(model.isRefiningEdges || staysArmed && model.drawingComponentID != nil ? "Done" : "Cancel") {
                    model.cancelDrawing()
                }
                .controlSize(.mini)
                .automationIdentifier("masks.hint.done")
            }
            if model.isRefiningEdges {
                EdgeBrushSize()
            }
            if model.drawingKind == .objects {
                @Bindable var model = model
                ControlRow(label: "Drag") {
                    ChoiceMenu("Drag", selection: $model.objectSelection)
                        .controlSize(.small)
                        .help("What a drag on the photo selects with: a box around the object, or a stroke over it")
                }
            }
        }
        .font(Theme.captionFont)
        .foregroundStyle(Theme.label)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.selection))
        .padding(.horizontal, Theme.panelPadding)
        .padding(.bottom, 10)
    }
}

/// The Refine Edge brush's size, and whether a stroke is being solved.
struct EdgeBrushSize: View {
    @Environment(EditorModel.self) private var model
    private static let sizeSpec = FieldSpec(range: 1 ... 100)

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            Text("Size")
            Slider(value: $model.edgeBrushSize, in: Self.sizeSpec.range)
                .controlSize(.mini)
            ValueFieldControl(
                spec: Self.sizeSpec, value: model.edgeBrushSize.rounded(), identifier: "masks.edgeBrush.size",
                onChange: { model.edgeBrushSize = $0 },
            )
            .frame(width: ValueFieldControl.width(for: "100"), height: Metrics.rowHeight)
            ProgressView()
                .controlSize(.mini)
                .opacity(model.isSolvingEdges ? 1 : 0)
        }
    }
}

/// The photo's masks, newest first: each row with its coverage, its name, its eye, and on the
/// selected row and the one under the pointer a menu of the context menu's actions. The canvas
/// previews the mask under the pointer.
struct MaskList: View {
    @Environment(EditorModel.self) private var model
    @State private var hovered: UUID?
    @State private var renaming: UUID?
    @State private var draftName = ""
    /// The mask Save as Mask Preset… names a preset after, while it asks.
    @State private var presetSource: UUID?
    @State private var presetName = ""

    var body: some View {
        VStack(spacing: 2) {
            ForEach(model.maskOutlines.reversed()) { mask in
                let selected = mask.id == model.selectedMaskID
                HStack(spacing: 8) {
                    MaskThumbnail(image: model.maskThumbnails[mask.id], symbol: mask.components.first?.kind?.symbol)
                    if renaming == mask.id {
                        TextField("Name", text: $draftName)
                            .textFieldStyle(.plain)
                            .font(Theme.labelFont)
                            .onSubmit {
                                model.renameMask(mask.id, to: draftName)
                                renaming = nil
                            }
                            .automationIdentifier("masks.row.\(mask.id.uuidString).name")
                    } else {
                        Text(mask.name)
                            .font(Theme.labelFont)
                            .foregroundStyle(mask.isVisible ? Theme.value : Theme.tertiaryLabel)
                    }
                    Spacer()
                    Button {
                        // The click's own flags, or the keyboard's when it arrives without them.
                        let option = NSApp.currentEvent?.modifierFlags.contains(.option) == true
                            || NSEvent.modifierFlags.contains(.option)
                        if option {
                            model.showMaskAlone(mask.id)
                        } else {
                            model.toggleMaskVisibility(mask.id)
                        }
                    } label: {
                        Image(systemName: mask.isVisible ? "eye" : "eye.slash")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mask.isVisible ? "Hide \(mask.name)" : "Show \(mask.name)")
                    .automationIdentifier("masks.row.\(mask.id.uuidString).eye")
                    .help(mask
                        .isVisible ? "Hide mask. Option-click to show it alone" :
                        "Show mask. Option-click to show it alone")
                    if selected || hovered == mask.id {
                        Menu {
                            actions(for: mask)
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.system(size: 11))
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .foregroundStyle(Theme.secondaryLabel)
                        .help("Rename, Duplicate, Save as Mask Preset, Delete")
                        .accessibilityLabel("\(mask.name)'s actions")
                        .automationIdentifier("masks.row.\(mask.id.uuidString).menu")
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.selection : .clear))
                .contentShape(Rectangle())
                .accessibilityElement(children: .contain)
                .accessibilityLabel(mask.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .automationIdentifier("masks.row.\(mask.id.uuidString)")
                .onHover { inside in
                    if inside {
                        hovered = mask.id
                    } else if hovered == mask.id {
                        hovered = nil
                    }
                    model.hoveredMaskID = hovered
                }
                // A row taken away under the pointer, as deleting its mask does, gets no hover's
                // end from SwiftUI.
                .onDisappear {
                    if hovered == mask.id {
                        hovered = nil
                    }
                    if model.hoveredMaskID == mask.id {
                        model.hoveredMaskID = nil
                    }
                }
                .onTapGesture(count: 2) {
                    draftName = mask.name
                    renaming = mask.id
                }
                .onTapGesture { model.selectMask(mask.id) }
                .modifier(Reorderable(payload: "redlamp.mask:\(mask.id.uuidString)", isEnabled: renaming != mask.id) {
                    guard let dragged = Reorderable.id(in: $0, kind: "mask") else { return false }
                    model.moveMask(dragged, onto: mask.id)
                    return true
                })
                .contextMenu {
                    actions(for: mask)
                }
            }
        }
        .onDisappear { model.hoveredMaskID = nil }
        // The list outlives photos and selections, so an unfinished rename mustn't.
        .onChange(of: model.selectedMaskID) { cancelRename() }
        .onChange(of: model.selection) { cancelRename() }
        .alert("Save Mask Preset", isPresented: Binding(
            get: { presetSource != nil }, set: {
                if !$0 {
                    presetSource = nil
                }
            },
        )) {
            TextField("Name", text: $presetName)
            Button("Save") {
                if let source = presetSource {
                    model.saveMaskPreset(from: source, name: presetName)
                }
                presetSource = nil
            }
            Button("Cancel", role: .cancel) { presetSource = nil }
        } message: {
            Text("A preset with the same name is replaced.")
        }
    }

    private func cancelRename() {
        renaming = nil
        draftName = ""
    }

    @ViewBuilder
    private func actions(for mask: MaskOutline) -> some View {
        Button("Rename…") {
            draftName = mask.name
            renaming = mask.id
        }
        Toggle("Invert", isOn: Binding(get: { mask.inverted }, set: { model.setMaskInverted(mask.id, $0) }))
        Button("Duplicate") { model.duplicateMask(mask.id) }
        Button("Duplicate and Invert") { model.duplicateMask(mask.id, inverted: true) }
        Button("Reset Adjustments") { model.resetMaskAdjustments(mask.id) }
        Button("Save as Mask Preset…") {
            presetName = mask.name
            presetSource = mask.id
        }
        Divider()
        Button("Delete \(mask.name)", role: .destructive) { model.deleteMask(mask.id) }
    }
}

/// The selected mask's settings: its name with Invert and Reset, Amount, its components, the
/// selected component's own settings, then its adjustments.
struct SelectedMaskEditor: View {
    let mask: MaskOutline
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SubsectionHeader(title: mask.name, parameters: []) {
                MaskHeaderControls(mask: mask)
            }
            ParameterSlider(parameter: .maskAmount)
            Spacer().frame(height: 6)
            SubsectionHeader(title: "Components, applied top to bottom", parameters: [])
            ForEach(mask.components) { component in
                ComponentRow(mask: mask, component: component)
            }
            ComponentOperationButtons(mask: mask)
                .padding(.top, 4)

            switch MasksPanel.componentTools(model) {
            case .radial:
                ParameterSlider(parameter: .maskFeather)
                    .padding(.top, 6)
            case .brush:
                BrushChoicePicker()
                    .padding(.top, 6)
                ForEach(ParameterID.brushParameters, id: \.self) { parameter in
                    ParameterSlider(parameter: parameter)
                }
                AutoMaskToggle()
            case .colorRange:
                ParameterSlider(parameter: .maskColorRefine)
                    .padding(.top, 6)
                ColorSampleList()
            case .luminanceRange:
                LuminanceRangeEditor()
                    .padding(.top, 6)
            case .depthRange:
                DepthRangeEditor()
                    .padding(.top, 6)
            case let kind? where kind.isAI:
                ParameterSlider(parameter: .maskAIFeather)
                    .padding(.top, 6)
                ParameterSlider(parameter: .maskAIEdge)
                AIComponentTools(mask: mask)
            default:
                EmptyView()
            }

            Spacer().frame(height: 6)
            ParameterSlider(parameter: .maskDetail)
            Spacer().frame(height: 4)
            ForEach(ParameterID.localParameters.filter { !ParameterID.swatchParameters.contains($0) }, id: \.self) {
                parameter in
                ParameterSlider(parameter: parameter)
                if MasksPanel.gapAfter.contains(parameter) {
                    Spacer().frame(height: 4)
                }
            }
            MaskColorSwatch()
            MaskCurvesEditor()
                .padding(.top, 6)
            MaskPointColor(mask: mask)
        }
        .padding(.horizontal, Theme.panelPadding)
        .padding(.bottom, 14)
    }
}

extension MasksPanel {
    /// Local adjustments come in groups, like the Basic panel's.
    static let gapAfter: Set<ParameterID> = [.localTint, .localBlacks, .localDehaze, .localDefringe]

    /// Which component settings to show: the brush while brushing, otherwise the selected
    /// component's own.
    @MainActor static func componentTools(_ model: EditorModel) -> MaskKind? {
        if model.isBrushing {
            return .brush
        }
        let kind = model.selectedComponentOutline?.kind
        if let kind, kind.isAI {
            return kind
        }
        return [.radial, .brush, .colorRange, .luminanceRange].contains(kind) ? kind : nil
    }
}

/// Lightroom's A, B and Erase brushes.
struct BrushChoicePicker: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ControlRow(label: "Brush") {
            ChoiceMenu("Brush", selection: $model.activeBrush)
                .controlSize(.small)
                .help("A, B and Erase each keep their own size, feather, flow and density; Erase takes paint away")
        }
    }
}

struct AutoMaskToggle: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        Toggle("Auto Mask", isOn: Binding(
            get: { model.brushes[model.activeBrush].autoMask },
            set: { model.brushes[model.activeBrush].autoMask = $0 },
        ))
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .font(Theme.labelFont)
        // A small checkbox is 14.12 pt tall; a whole height puts it, and the rows under it, on
        // the same pixels in the AppKit panel, which hosts it on its own.
        .frame(height: 14)
        .help("Keeps the brush to colors like the one under its center")
        .automationIdentifier("masks.brush.autoMask")
    }
}

/// The selected Color Range's samples, removable while more than one is left.
struct ColorSampleList: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        let samples = model.selectedColorRange?.samples ?? []
        HStack(spacing: 6) {
            Text("\(samples.count) of \(ColorRangeMask.maximumSamples) samples")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.secondaryLabel)
            Spacer()
            if samples.count > 1 {
                Button("Remove Last") { model.removeColorSample(at: samples.count - 1) }
                    .controlSize(.mini)
                    .automationIdentifier("masks.colorRange.removeLast")
            }
        }
    }
}

/// Luminance Range: a lightness bar with four handles, and the luminance map.
struct LuminanceRangeEditor: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LuminanceRangeBar()
            LuminanceMapToggle()
        }
    }
}

struct LuminanceRangeBar: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        RangeBar(
            title: "Luminance Range", colors: [.black, .white],
            range: model.selectedLuminanceRange ?? LuminanceRangeMask(),
            onChange: { model.setLuminanceRange($0) }, historyName: "Luminance Range", kind: .luminanceRange,
        )
    }
}

/// Show Luminance Map, under the range's bar. The AppKit panel hosts it on its own, as it
/// does Auto Mask, so it lands on the same pixels.
struct LuminanceMapToggle: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Toggle("Show Luminance Map", isOn: $model.showLuminanceMap)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(Theme.labelFont)
            .frame(height: 14)
            .automationIdentifier("masks.luminanceMap")
    }
}

/// Depth Range: the same bar over depth, far on the left.
struct DepthRangeEditor: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        RangeBar(
            title: "Depth Range", colors: [Color(white: 0.15), Color(white: 0.95)],
            range: model.selectedDepthRange ?? LuminanceRangeMask(),
            onChange: { model.setDepthRange($0) }, historyName: "Depth Range", kind: .depthRange,
            ends: ("Far", "Near"),
        )
    }
}

/// A 0...100 bar with four handles: where the range starts, is full, stops being full, ends.
struct RangeBar: View {
    let title: String
    let colors: [Color]
    let range: LuminanceRangeMask
    let onChange: (LuminanceRangeMask) -> Void
    let historyName: String
    let kind: MaskKind
    var ends: (String, String)?
    @Environment(EditorModel.self) private var model
    @State private var dragging: Int?

    private static let stopSpec = FieldSpec(range: 0 ... 100)
    private static let stopNames = [
        "Where the range starts", "Where it's full from", "Where it stops being full", "Where it ends",
    ]

    var body: some View {
        let stops = Self.stops(of: range)
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.labelFont)
                .foregroundStyle(Theme.label)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                        .frame(height: 10)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .offset(y: 4)
                    Path { path in
                        let xs = stops.map { $0 / 100 * width }
                        path.move(to: CGPoint(x: xs[0], y: 22))
                        path.addLine(to: CGPoint(x: xs[1], y: 16))
                        path.addLine(to: CGPoint(x: xs[2], y: 16))
                        path.addLine(to: CGPoint(x: xs[3], y: 22))
                    }
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    ForEach(0 ..< 4, id: \.self) { index in
                        let inner = index == 1 || index == 2
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(inner ? Color.white : Color.white.opacity(0.6))
                            .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.black.opacity(0.6)))
                            .frame(width: inner ? 7 : 5, height: 18)
                            .position(x: stops[index] / 100 * width, y: 9)
                            .gesture(handleDrag(index, width: width))
                    }
                }
            }
            .frame(height: 24)
            HStack(spacing: 0) {
                ForEach(0 ..< 4, id: \.self) { index in
                    if index > 0 {
                        Spacer(minLength: 4)
                    }
                    stopField(index, value: stops[index])
                }
            }
            if let ends {
                HStack {
                    Text(ends.0)
                    Spacer()
                    Text(ends.1)
                }
                .font(Theme.captionFont)
                .foregroundStyle(Theme.secondaryLabel)
            }
        }
    }

    /// Where the range starts, is full from, stops being full, and ends.
    static func stops(of range: LuminanceRangeMask) -> [Double] {
        [range.lower - range.lowerFeather, range.lower, range.upper, range.upper + range.upperFeather]
    }

    /// The range with stop `index` moved to `value`, the other stops where they were.
    static func moving(_ index: Int, to value: Double, in range: LuminanceRangeMask) -> LuminanceRangeMask {
        var range = range
        let value = min(max(value, 0), 100)
        switch index {
        case 0: range.lowerFeather = max(range.lower - value, 0)
        case 1:
            let start = range.lower - range.lowerFeather
            range.lower = min(max(value, start), range.upper)
            range.lowerFeather = range.lower - start
        case 2:
            let end = range.upper + range.upperFeather
            range.upper = max(min(value, end), range.lower)
            range.upperFeather = end - range.upper
        default: range.upperFeather = max(value - range.upper, 0)
        }
        return range
    }

    /// A stop's value, scrubbed or typed.
    private func stopField(_ index: Int, value: Double) -> some View {
        ValueFieldControl(
            spec: Self.stopSpec, value: value.rounded(), identifier: "masks.\(kind.rawValue).stop\(index + 1)",
            onBegin: { model.beginEdit() },
            onChange: { onChange(Self.moving(index, to: $0, in: range)) },
            onEnd: { model.endEdit(.mask(kind), historyName) },
            onCommit: { typed in
                model.beginEdit()
                onChange(Self.moving(index, to: typed, in: range))
                model.endEdit(.mask(kind), historyName)
            },
        )
        .frame(width: ValueFieldControl.width(for: "100"), height: Metrics.rowHeight)
        .help(Self.stopNames[index])
    }

    private func handleDrag(_ index: Int, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if dragging == nil {
                    dragging = index
                    model.beginEdit()
                }
                onChange(Self.moving(index, to: gesture.location.x / max(width, 1) * 100, in: range))
            }
            .onEnded { _ in
                dragging = nil
                model.endEdit(.mask(kind), historyName)
            }
    }
}

struct ResetMaskButton: View {
    let mask: MaskOutline
    @Environment(EditorModel.self) private var model

    var body: some View {
        Button("Reset") { model.resetMaskAdjustments(mask.id) }
            .controlSize(.mini)
            .automationIdentifier("masks.mask.reset")
    }
}

/// Invert for the whole mask, and Reset, beside its name at the top of its settings. The AppKit
/// panel keeps a mask's settings through an Invert, so this reads the mask's state from the model.
struct MaskHeaderControls: View {
    let mask: MaskOutline
    @Environment(EditorModel.self) private var model

    var body: some View {
        let inverted = model.maskOutlines.first { $0.id == mask.id }?.inverted ?? mask.inverted
        Toggle("Invert", isOn: Binding(get: { inverted }, set: { model.setMaskInverted(mask.id, $0) }))
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .font(Theme.captionFont)
            .help("Invert the whole mask")
            .automationIdentifier("masks.mask.invert")
        ResetMaskButton(mask: mask)
    }
}

/// Refine Edges and the Refine Edge Brush, under an AI component's Feather and Edge, for the
/// component selected when they're clicked.
struct AIComponentTools: View {
    let mask: MaskOutline
    @Environment(EditorModel.self) private var model

    var body: some View {
        if let component = model.selectedComponentOutline {
            HStack(spacing: 6) {
                Button("Refine Edges") { Task { await model.refineEdges(component.id, in: mask.id) } }
                    .help("Solve the mask's edge again from the photo")
                    .automationIdentifier("masks.refineEdges")
                Button("Refine Edge Brush") { model.startRefiningEdges(component.id, in: mask.id) }
                    .help("Paint over an edge to solve it again, hair by hair")
                    .automationIdentifier("masks.refineEdgeBrush")
            }
            .controlSize(.small)
            .font(Theme.labelFont)
            .frame(height: Metrics.rowHeight)
            .padding(.top, 2)
        }
    }
}

/// A component of the selected mask: the operation's icon as a menu, its kind and name, its
/// Invert, and a menu button for Delete and an AI component's refinements.
struct ComponentRow: View {
    let mask: MaskOutline
    let component: MaskOutline.Component
    @Environment(EditorModel.self) private var model

    /// "Subject 1"; a People component names its part and person, "Face Skin · Person 2".
    private func title(_ index: Int) -> String {
        guard component.kind == .people else {
            return "\(component.kind?.name ?? "Newer Component") \(index)"
        }
        let part = component.part.flatMap(PersonPart.init(rawValue:)) ?? .entirePerson
        guard let person = model.personNumber(part: part, instance: component.instance) else { return part.name }
        return "\(part.name) · Person \(person)"
    }

    var body: some View {
        let selected = component.id == model.selectedComponentOutline?.id
        let index = (mask.components.firstIndex(of: component) ?? 0) + 1
        HStack(spacing: 8) {
            Menu {
                operations
            } label: {
                Image(systemName: component.operation.symbol)
                    .font(.system(size: 9, weight: .bold))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 14)
            .foregroundStyle(Theme.secondaryLabel)
            .help("\(component.operation.name): choose how it combines")
            .accessibilityLabel(component.operation.name)
            .automationIdentifier("masks.component.\(component.id.uuidString).operation")
            Image(systemName: component.kind?.symbol ?? "questionmark.square.dashed")
                .font(.system(size: 11))
            Text(title(index))
                .font(Theme.labelFont)
            Spacer()
            if component.kind == .brush || component.kind == .colorRange || component.kind == .luminanceRange {
                Button {
                    if component.kind == .brush {
                        model.editBrush(component.id, in: mask.id)
                    } else {
                        model.resampleRange(component.id, in: mask.id)
                    }
                } label: {
                    Image(systemName: component.kind == .brush ? "paintbrush.pointed" : "eyedropper")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryLabel)
                .help(component.kind == .brush ? "Paint into this brush" : "Sample again")
                .automationIdentifier("masks.component.\(component.id.uuidString).edit")
            }
            Toggle("Invert", isOn: Binding(
                get: { component.inverted },
                set: { model.setComponentInverted(component.id, in: mask.id, $0) },
            ))
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .font(Theme.captionFont)
            .automationIdentifier("masks.component.\(component.id.uuidString).invert")
            Menu {
                refinements
                Button("Delete", role: .destructive) { model.deleteComponent(component.id, in: mask.id) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 10))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Theme.secondaryLabel)
            .help(component.kind?.isAI == true ? "Refine Edges, Refine Edge Brush, Delete" : "Delete")
            .accessibilityLabel("\(title(index))'s actions")
            .automationIdentifier("masks.component.\(component.id.uuidString).menu")
        }
        .foregroundStyle(selected ? Theme.value : Theme.label)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.selection : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title(index))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .automationIdentifier("masks.component.\(component.id.uuidString)")
        .onTapGesture { model.selectedComponentID = component.id }
        .onHover { inside in
            if inside {
                model.hoveredComponentID = component.id
            } else if model.hoveredComponentID == component.id {
                model.hoveredComponentID = nil
            }
        }
        // A row taken away under the pointer, as deleting its component does, gets no hover's end
        // from SwiftUI.
        .onDisappear {
            if model.hoveredComponentID == component.id {
                model.hoveredComponentID = nil
            }
        }
        .modifier(Reorderable(payload: "redlamp.component:\(component.id.uuidString)", isEnabled: true) {
            guard let dragged = Reorderable.id(in: $0, kind: "component") else { return false }
            model.moveComponent(dragged, in: mask.id, onto: component.id)
            return true
        })
        .contextMenu {
            operations
            refinements
        }
    }

    private var operations: some View {
        ForEach(MaskOperation.allCases, id: \.self) { operation in
            Button("Set to \(operation.name)") { model.setComponentOperation(component.id, in: mask.id, operation) }
        }
    }

    @ViewBuilder
    private var refinements: some View {
        if let kind = component.kind, kind.isAI, kind != .depthRange {
            Divider()
            Button("Refine Edges") { Task { await model.refineEdges(component.id, in: mask.id) } }
            Button("Refine Edge Brush") { model.startRefiningEdges(component.id, in: mask.id) }
        }
    }
}
