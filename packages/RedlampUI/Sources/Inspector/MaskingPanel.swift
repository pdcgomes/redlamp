import RedlampEngineAPI
import SwiftUI

/// The Masking tool's panel: masks list, create menu, components and local adjustments.
@_spi(Harness) public struct MaskingPanel: View {
    @Environment(EditorModel.self) private var model

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MasksHeaderBar()

            if model.maskOutlines.isEmpty {
                CreateMaskGrid(
                    title: "Create New Mask",
                    onLandscapeClass: { cls in Task { await model.createAIMask(.landscape, landscape: cls) } },
                ) { kind in model.startDrawing(kind) }
                    .padding(.horizontal, Theme.panelPadding)
                    .padding(.bottom, 8)
                HStack {
                    MaskPresetsMenu()
                    Spacer()
                }
                .padding(.horizontal, Theme.panelPadding)
                .padding(.bottom, 12)
                MaskStatus()
                if model.drawingKind != nil || model.isRefiningEdges {
                    DrawingHint()
                }
            } else {
                MaskList()
                    .padding(.horizontal, Theme.panelPadding)
                MaskActionsBar()
                MaskStatus()

                if model.drawingKind != nil || model.isRefiningEdges {
                    DrawingHint()
                }

                Rectangle().fill(Theme.divider).frame(height: 1)

                if let mask = model.selectedOutline {
                    SelectedMaskEditor(mask: mask)
                } else {
                    NoMaskSelected()
                }
            }
        }
    }
}

// The Masking panel's parts, shared by the SwiftUI panel and its AppKit port. The lists
// read `maskOutlines`, so dragging a mask's sliders doesn't re-render them.

struct MasksHeaderBar: View {
    @Environment(EditorModel.self) private var model
    @State private var choosingOverlay = false

    var body: some View {
        @Bindable var model = model
        HStack {
            Text("Masks")
                .font(Theme.panelTitleFont)
                .foregroundStyle(Theme.value)
            Spacer()
            Toggle("Show Overlay", isOn: $model.showMaskOverlay)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(Theme.captionFont)
                .help("Show Overlay (O)")
            Button {
                choosingOverlay.toggle()
            } label: {
                Image(systemName: "circle.lefthalf.striped.horizontal")
            }
            .buttonStyle(.plain)
            .help("Overlay mode, color and opacity")
            .popover(isPresented: $choosingOverlay, arrowEdge: .leading) {
                MaskOverlayOptions()
                    .environment(model)
            }
        }
        .padding(.horizontal, Theme.panelPadding)
        .padding(.vertical, 10)
    }
}

/// The overlay's mode, and for the modes that tint, its color and opacity, as Lightroom's overlay
/// options.
struct MaskOverlayOptions: View {
    @Environment(EditorModel.self) private var model

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
            }
            GridRow {
                Text("Opacity")
                HStack {
                    Slider(value: $model.maskOverlayOpacity, in: 0 ... 1)
                    Text("\(Int((model.maskOverlayOpacity * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
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

struct MaskActionsBar: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        HStack {
            CreateMaskMenu(
                title: "Create New Mask", systemImage: "plus",
                onPersonPart: { part in Task { await model.createAIMask(.people, part: part) } },
                onLandscapeClass: { cls in Task { await model.createAIMask(.landscape, landscape: cls) } },
            ) { kind in
                model.startDrawing(kind)
            }
            MaskPresetsMenu()
            Spacer()
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
        }
        .padding(.horizontal, Theme.panelPadding)
        .padding(.vertical, 8)
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
/// the user's own.
struct MaskPresetsMenu: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        let presets = model.maskPresets
        let builtIn = Set(MaskPreset.builtIn.map(\.id))
        Menu {
            ForEach(presets) { preset in
                Button(preset.name) { Task { await model.applyMaskPreset(preset) } }
                    .disabled(!model.canApply(preset) || model.aiMaskProgress != nil)
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
            Label("Presets", systemImage: "wand.and.stars").font(Theme.labelFont)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help("Apply a mask preset")
    }
}

/// An AI mask being computed, or why the last one couldn't be.
struct MaskStatus: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        if let pending = model.pendingModel {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(pending.kind.name) masks use \(pending.model.name), a \(pending.model.formattedSize) download.")
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.value)
                Text(
                    "It runs on this Mac; your photos are never uploaded. You can remove it in Settings › Models."
                        + (pending.model.licence.map { " Its licence: \($0)." } ?? ""),
                )
                .font(Theme.captionFont)
                .foregroundStyle(Theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                if let url = pending.model.licenceURL {
                    Link("Read the licence", destination: url)
                        .font(Theme.captionFont)
                }
                HStack {
                    Spacer()
                    Button("Not Now") { model.declinePendingModel() }
                    Button("Download") { Task { await model.downloadPendingModel() } }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.selection))
            .padding(.horizontal, Theme.panelPadding)
            .padding(.bottom, 10)
        } else if let progress = model.modelDownloadProgress {
            HStack(spacing: 8) {
                ProgressView(value: progress).controlSize(.small)
                Text("Downloading model… \(Int(progress * 100))%")
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.label)
            .padding(.horizontal, Theme.panelPadding)
            .padding(.bottom, 10)
        } else if let kind = model.aiMaskProgress {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(kind == .subject && model
                    .aiMaskCount > 0 ? "Updating AI masks…" : "Finding \(kind.name.lowercased())…")
                Spacer()
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.label)
            .padding(.horizontal, Theme.panelPadding)
            .padding(.bottom, 10)
        } else if let message = model.maskMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text(message).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Report…") {
                    model.sendFeedback(FeedbackPrefill(featureID: FeedbackContext.suggestion(model), message: message))
                }
                .buttonStyle(.link)
                .help("Report a Bug about this message")
                Button {
                    model.maskMessage = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.label)
            .padding(.horizontal, Theme.panelPadding)
            .padding(.bottom, 10)
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
            }
            if model.isRefiningEdges {
                EdgeBrushSize()
            }
            if model.drawingKind == .objects {
                @Bindable var model = model
                Picker("Drag", selection: $model.objectSelection) {
                    ForEach(ObjectSelection.allCases, id: \.self) { selection in
                        Text(selection.name).tag(selection)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .help("What a drag on the photo selects with: a box around the object, or a stroke over it")
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

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            Text("Size")
            Slider(value: $model.edgeBrushSize, in: 1 ... 100)
                .controlSize(.mini)
            ProgressView()
                .controlSize(.mini)
                .opacity(model.isSolvingEdges ? 1 : 0)
        }
    }
}

/// Every mask type, like Lightroom's Create New Mask menu. Types from later phases are
/// visible but disabled, with their phase in the tooltip.
struct CreateMaskGrid: View {
    let title: String
    /// Landscape classes: the Landscape tile opens a menu of them.
    var onLandscapeClass: ((LandscapeClass) -> Void)?
    let onCreate: (MaskKind) -> Void
    @Environment(EditorModel.self) private var model

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(Theme.sectionFont)
                .tracking(0.6)
                .foregroundStyle(Theme.secondaryLabel)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(MaskKind.creatable, id: \.self) { kind in
                    Group {
                        if kind == .landscape, let onLandscapeClass {
                            Menu {
                                ForEach(LandscapeClass.allCases, id: \.self) { cls in
                                    Button(cls.name) { onLandscapeClass(cls) }
                                }
                            } label: {
                                tile(kind)
                            }
                            .menuStyle(.button)
                            .menuIndicator(.hidden)
                        } else {
                            Button {
                                onCreate(kind)
                            } label: {
                                tile(kind)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canCreateMask(kind) || model.aiMaskProgress != nil)
                    .help(kind.plannedPhase.map { "\(kind.name) arrives in \($0)" }
                        ?? (model.canCreateMask(kind) ? kind.name : "\(kind.name) isn't available for this photo"))
                }
            }
        }
    }

    private func tile(_ kind: MaskKind) -> some View {
        VStack(spacing: 5) {
            if model.aiMaskProgress == kind {
                ProgressView().controlSize(.small).frame(height: 16)
            } else {
                Image(systemName: kind.symbol).font(.system(size: 16))
            }
            Text(kind.name)
                .font(.system(size: 9.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .foregroundStyle(model.canCreateMask(kind) ? Theme.value : Theme.tertiaryLabel)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
        .contentShape(Rectangle())
    }
}

struct CreateMaskMenu: View {
    let title: String
    let systemImage: String
    /// Other masks that can be reused as a component.
    var others: [MaskOutline] = []
    var onReuse: (UUID) -> Void = { _ in }
    /// People parts; the plain People item selects entire people.
    var onPersonPart: ((PersonPart) -> Void)?
    /// Landscape classes.
    var onLandscapeClass: ((LandscapeClass) -> Void)?
    let onCreate: (MaskKind) -> Void
    @Environment(EditorModel.self) private var model

    var body: some View {
        Menu {
            if !others.isEmpty {
                Menu("Existing Mask") {
                    ForEach(others) { other in
                        Button(other.name) { onReuse(other.id) }
                    }
                }
                Divider()
            }
            ForEach(MaskKind.creatable, id: \.self) { kind in
                if kind == .people, let onPersonPart, model.canCreateMask(.people) {
                    Menu {
                        ForEach(model.availablePersonParts, id: \.self) { part in
                            Button(part.name) { onPersonPart(part) }
                        }
                    } label: {
                        Label(kind.name, systemImage: kind.symbol)
                    }
                } else if kind == .landscape, let onLandscapeClass, model.canCreateMask(.landscape) {
                    Menu {
                        ForEach(LandscapeClass.allCases, id: \.self) { cls in
                            Button(cls.name) { onLandscapeClass(cls) }
                        }
                    } label: {
                        Label(kind.name, systemImage: kind.symbol)
                    }
                } else {
                    Button {
                        onCreate(kind)
                    } label: {
                        Label(
                            kind.plannedPhase.map { "\(kind.name) (\($0))" } ?? kind.name,
                            systemImage: kind.symbol,
                        )
                    }
                    .disabled(!model.canCreateMask(kind))
                }
            }
        } label: {
            Label(title, systemImage: systemImage).font(Theme.labelFont)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }
}

struct MaskList: View {
    @Environment(EditorModel.self) private var model
    @State private var renaming: UUID?
    @State private var draftName = ""

    var body: some View {
        VStack(spacing: 2) {
            ForEach(model.maskOutlines.reversed()) { mask in
                let selected = mask.id == model.selectedMaskID
                HStack(spacing: 8) {
                    Image(systemName: mask.components.first?.kind?.symbol ?? "circle.dashed")
                        .font(.system(size: 12))
                        .frame(width: 18)
                        .foregroundStyle(selected ? Theme.value : Theme.secondaryLabel)
                    if renaming == mask.id {
                        TextField("Name", text: $draftName)
                            .textFieldStyle(.plain)
                            .font(Theme.labelFont)
                            .onSubmit {
                                model.renameMask(mask.id, to: draftName)
                                renaming = nil
                            }
                    } else {
                        Text(mask.name)
                            .font(Theme.labelFont)
                            .foregroundStyle(mask.isVisible ? Theme.value : Theme.tertiaryLabel)
                    }
                    Spacer()
                    Button {
                        model.toggleMaskVisibility(mask.id)
                    } label: {
                        Image(systemName: mask.isVisible ? "eye" : "eye.slash")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                    .buttonStyle(.plain)
                    .help(mask.isVisible ? "Hide mask" : "Show mask")
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.selection : .clear))
                .contentShape(Rectangle())
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
                    Button("Rename…") {
                        draftName = mask.name
                        renaming = mask.id
                    }
                    Button("Duplicate") { model.duplicateMask(mask.id) }
                    Button("Duplicate and Invert") { model.duplicateMask(mask.id, inverted: true) }
                    Button("Reset Adjustments") { model.resetMaskAdjustments(mask.id) }
                    Button("Save as Mask Preset") { model.saveMaskPreset(from: mask.id, name: mask.name) }
                    Divider()
                    Button("Delete \(mask.name)", role: .destructive) { model.deleteMask(mask.id) }
                }
            }
        }
        // The list outlives photos and selections, so an unfinished rename mustn't.
        .onChange(of: model.selectedMaskID) { cancelRename() }
        .onChange(of: model.selection) { cancelRename() }
    }

    private func cancelRename() {
        renaming = nil
        draftName = ""
    }
}

private struct SelectedMaskEditor: View {
    let mask: MaskOutline
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SubsectionHeader(title: "Components", parameters: [])
            ForEach(mask.components) { component in
                ComponentRow(mask: mask, component: component)
            }
            ComponentOperationMenus(mask: mask)
                .padding(.top, 4)

            switch MaskingPanel.componentTools(model) {
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
            default:
                EmptyView()
            }

            SubsectionHeader(title: mask.name, parameters: []) {
                ResetMaskButton(mask: mask)
            }
            ParameterSlider(parameter: .maskAmount)
            ParameterSlider(parameter: .maskDetail)
            Spacer().frame(height: 4)
            ForEach(ParameterID.localParameters, id: \.self) { parameter in
                ParameterSlider(parameter: parameter)
                if MaskingPanel.gapAfter.contains(parameter) {
                    Spacer().frame(height: 4)
                }
            }
        }
        .padding(.horizontal, Theme.panelPadding)
        .padding(.bottom, 14)
    }
}

extension MaskingPanel {
    /// Local adjustments come in groups, like the Basic panel's.
    static let gapAfter: Set<ParameterID> = [.localTint, .localBlacks, .localDehaze, .localDefringe]

    /// Which component settings to show: the brush while brushing, otherwise the selected
    /// component's own.
    @MainActor static func componentTools(_ model: EditorModel) -> MaskKind? {
        if model.isBrushing {
            return .brush
        }
        let kind = model.selectedComponentOutline?.kind
        return [.radial, .brush, .colorRange, .luminanceRange, .depthRange].contains(kind) ? kind : nil
    }
}

/// Lightroom's A, B and Erase brushes.
struct BrushChoicePicker: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("Brush", selection: $model.activeBrush) {
            ForEach(BrushChoice.allCases, id: \.self) { choice in
                Text(choice.rawValue).tag(choice)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
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
        .help("Keeps the brush to colors like the one under its center")
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
            }
        }
    }
}

/// Luminance Range: a lightness bar with four handles, and the luminance map.
struct LuminanceRangeEditor: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            RangeBar(
                title: "Luminance Range", colors: [.black, .white],
                range: model.selectedLuminanceRange ?? LuminanceRangeMask(),
                onChange: { model.setLuminanceRange($0) }, historyName: "Luminance Range", kind: .luminanceRange,
            )
            Toggle("Show Luminance Map", isOn: $model.showLuminanceMap)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(Theme.labelFont)
        }
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

    var body: some View {
        let stops = [range.lower - range.lowerFeather, range.lower, range.upper, range.upper + range.upperFeather]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.label)
                Spacer()
                Text("\(Int(range.lower.rounded())) – \(Int(range.upper.rounded()))")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.secondaryLabel)
            }
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

    private func handleDrag(_ index: Int, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                var range = range
                if dragging == nil {
                    dragging = index
                    model.beginEdit()
                }
                let value = min(max(gesture.location.x / max(width, 1) * 100, 0), 100)
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
                onChange(range)
            }
            .onEnded { _ in
                dragging = nil
                model.endEdit(.mask(kind), historyName)
            }
    }
}

/// Add, Subtract and Intersect: draw another component into the mask.
struct ComponentOperationMenus: View {
    let mask: MaskOutline
    @Environment(EditorModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            ForEach([MaskOperation.add, .subtract, .intersect], id: \.self) { operation in
                CreateMaskMenu(
                    title: operation.name, systemImage: operation.symbol,
                    others: model.maskOutlines.filter { $0.id != mask.id },
                    onReuse: { model.addMaskReference($0, to: mask.id, operation: operation) },
                    onPersonPart: { part in
                        Task { await model.createAIMask(.people, part: part, operation: operation, addingTo: mask.id) }
                    },
                    onLandscapeClass: { cls in
                        Task {
                            await model.createAIMask(
                                .landscape,
                                landscape: cls,
                                operation: operation,
                                addingTo: mask.id,
                            )
                        }
                    },
                ) { kind in
                    model.startDrawing(kind, operation: operation, addingTo: mask.id)
                }
            }
        }
    }
}

struct ResetMaskButton: View {
    let mask: MaskOutline
    @Environment(EditorModel.self) private var model

    var body: some View {
        Button("Reset") { model.resetMaskAdjustments(mask.id) }
            .controlSize(.mini)
    }
}

struct ComponentRow: View {
    let mask: MaskOutline
    let component: MaskOutline.Component
    @Environment(EditorModel.self) private var model

    var body: some View {
        let selected = component.id == model.selectedComponentOutline?.id
        let index = (mask.components.firstIndex(of: component) ?? 0) + 1
        HStack(spacing: 8) {
            Image(systemName: component.operation.symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 14)
                .foregroundStyle(Theme.secondaryLabel)
                .help(component.operation.name)
            Image(systemName: component.kind?.symbol ?? "questionmark.square.dashed")
                .font(.system(size: 11))
            Text("\(component.kind?.name ?? "Newer Component") \(index)")
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
            }
            Toggle("Invert", isOn: Binding(
                get: { component.inverted },
                set: { model.setComponentInverted(component.id, in: mask.id, $0) },
            ))
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .font(Theme.captionFont)
            Button {
                model.deleteComponent(component.id, in: mask.id)
            } label: {
                Image(systemName: "trash").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryLabel)
            .help("Delete component")
        }
        .foregroundStyle(selected ? Theme.value : Theme.label)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.selection : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedComponentID = component.id }
        .modifier(Reorderable(payload: "redlamp.component:\(component.id.uuidString)", isEnabled: true) {
            guard let dragged = Reorderable.id(in: $0, kind: "component") else { return false }
            model.moveComponent(dragged, in: mask.id, onto: component.id)
            return true
        })
        .contextMenu {
            ForEach(MaskOperation.allCases, id: \.self) { operation in
                Button("Set to \(operation.name)") { model.setComponentOperation(component.id, in: mask.id, operation) }
            }
            if let kind = component.kind, kind.isAI, kind != .depthRange {
                Divider()
                Button("Refine Edges") { Task { await model.refineEdges(component.id, in: mask.id) } }
                Button("Refine Edge Brush") { model.startRefiningEdges(component.id, in: mask.id) }
            }
        }
    }
}
