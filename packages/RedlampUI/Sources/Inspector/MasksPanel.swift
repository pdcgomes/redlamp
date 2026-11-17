import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The Masking tool's panels, as redesigned (`docs/plans/2026-10-07-masks-panel-design.md`), and
/// the reference their AppKit port in the editor (`MasksPanelView`) is checked against. From UX-20:
/// one picker starts every mask, the list's actions sit in the header, and messages and the
/// armed tool show at the top of the list. From UX-22: every
/// action is on screen, not only in context menus. From UX-23: each row shows its mask's
/// coverage, the canvas previews the mask or component under the pointer, and pins sit where
/// each mask covers most. From UX-21: People opens a picker of who is in the photo and which of
/// their parts to mask. From UX-26: Landscape opens a picker of the regions found in it. From
/// UX-17: three cards, as the Develop panels are: Masks, the selected mask with its components,
/// and its Adjustments.
@_spi(Harness) public struct MasksPanel: View {
    @Environment(EditorModel.self) private var model

    public init() {}

    public var body: some View {
        let picking = model.peoplePicker != nil || model.landscapePicker != nil
        VStack(spacing: Theme.panelCardGap) {
            // The list reaches the card's sides; the rest of the panel's rows pad themselves.
            MaskPanelSection(panel: .masks, sidePadding: 0, bottomPadding: 2) {
                MasksHeaderControls()
            } content: {
                Group {
                    if model.drawingKind != nil || model.isRefiningEdges {
                        DrawingHint()
                    }
                    MaskMessages()
                }
                .padding(.horizontal, Theme.panelCardPadding)
                if model.peoplePicker != nil {
                    OpenPeoplePicker()
                        .padding(.horizontal, Theme.panelCardPadding)
                } else if model.landscapePicker != nil {
                    OpenLandscapePicker()
                        .padding(.horizontal, Theme.panelCardPadding)
                } else if model.maskOutlines.isEmpty {
                    MaskPicker(mode: .new, inline: true)
                        .padding(.horizontal, Theme.panelCardPadding)
                        .padding(.bottom, 8)
                } else {
                    MaskList()
                        .padding(.bottom, 8)
                        .background(MaskThumbnailRefresher())
                    if model.selectedOutline == nil {
                        NoMaskSelected()
                            .padding(.horizontal, Theme.panelCardPadding)
                    }
                }
                NewMaskRow()
                    .padding(.horizontal, Theme.panelCardPadding)
            }
            if !picking, let mask = model.selectedOutline {
                MaskPanelSection(
                    panel: .mask, title: mask.name,
                    parameters: [.maskAmount, .maskDetail] + Self.toolParameters(Self.componentTools(model)),
                ) {
                    MaskHeaderControls(mask: mask)
                } content: {
                    MaskSettings(mask: mask)
                }
                MaskPanelSection(
                    panel: .adjustments, parameters: ParameterID.localParameters + ParameterID.pointColorParameters,
                    reset: { model.resetMaskAdjustments(mask.id) },
                ) {
                    MaskEditedChip(mask: mask.id)
                } content: {
                    MaskAdjustments(mask: mask)
                }
                .onHover { model.pointerOverMaskAdjustments = $0 }
                .onDisappear { model.pointerOverMaskAdjustments = false }
            }
        }
        .task(id: model.maskOutlines) { await model.findPeopleForNames() }
    }
}

/// One of the Masking tool's panels, drawn as `PanelSection` draws a Develop panel: a card whose
/// header expands and collapses it (Option-click for Solo Mode), with `accessory` at its trailing
/// edge. A double-click on Adjustments' header resets the mask's adjustments.
struct MaskPanelSection<Accessory: View, Content: View>: View {
    let panel: MaskPanelID
    var title: String?
    /// The sliders the panel can show, whose values share one column.
    var parameters: [ParameterID] = []
    var reset: (() -> Void)?
    var sidePadding = Theme.panelCardPadding
    var bottomPadding: CGFloat = 14
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    @Environment(EditorModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let expanded = model.isExpanded(panel)
        let shape = RoundedRectangle(cornerRadius: Theme.panelCardRadius, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondaryLabel)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Image(systemName: panel.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryLabel)
                    .frame(width: Theme.panelSymbolSlot)
                    .padding(.trailing, -2)
                Text(title ?? panel.title)
                    .font(Theme.panelTitleFont)
                    .foregroundStyle(hovering ? Theme.labelHover : Theme.value)
                    .lineLimit(1)
                Spacer()
                accessory
            }
            .padding(.horizontal, Theme.panelCardPadding)
            .frame(height: 32)
            .background(hovering ? Theme.cardHover : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { reset?() }
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) {
                    model.toggleMaskPanel(panel, solo: NSEvent.modifierFlags.contains(.option))
                }
            }
            .contextMenu {
                if let reset {
                    Button("Reset \(panel.title)", action: reset)
                    Divider()
                }
                Toggle("Solo Mode", isOn: Bindable(model).soloMode)
                Button("Expand All Panels") { model.expandedMaskPanels = Set(MaskPanelID.allCases) }
                Button("Collapse All Panels") { model.expandedMaskPanels = [] }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    content
                }
                .padding(.horizontal, sidePadding)
                .padding(.bottom, bottomPadding)
                .transition(.opacity)
            }
        }
        .environment(\.valueColumnWidth, ValueFieldView.columnTextWidth(for: parameters.map(\.spec)))
        .background(Theme.card, in: shape)
        .overlay(shape.strokeBorder(Theme.divider, lineWidth: 1))
        .clipShape(shape)
    }
}

/// The Adjustments panel's Edited chip: how many kinds of adjustment the mask has changed.
struct MaskEditedChip: View {
    let mask: UUID
    @Environment(EditorModel.self) private var model

    var body: some View {
        let items = model.editedAdjustments(of: mask)
        if !items.isEmpty {
            Text("Edited\u{2009}·\u{2009}\(items.count)")
                .font(Typography.badge.font)
                .foregroundStyle(Theme.editedChipText)
                .padding(.horizontal, Theme.editedChipPadding)
                .frame(height: TextLine.lineHeight(Typography.badge) + 3)
                .background(Capsule().fill(Theme.editedChipFill))
                .help(items.joined(separator: ", "))
        }
    }
}

/// New Mask, as wide as the panel, and Mask Presets, the last row of the Masks panel, under the
/// list where new masks appear. Before there are masks the picker above makes them, so Mask
/// Presets takes the row alone, under a label as the picker's groups have.
struct NewMaskRow: View {
    @Environment(EditorModel.self) private var model
    @State private var picking = false

    var body: some View {
        Group {
            if model.maskOutlines.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("FROM PRESET")
                        .font(Theme.sectionFont)
                        .tracking(0.6)
                        .foregroundStyle(Theme.tertiaryLabel)
                    MaskPresetsMenu(wide: true)
                }
            } else {
                HStack(spacing: 6) {
                    Button {
                        picking = true
                    } label: {
                        Label("New Mask", systemImage: "plus")
                            .font(Theme.labelFont)
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .disabled(model.info == nil)
                    .help("Make a new mask")
                    .automationIdentifier("masks.new")
                    .popover(isPresented: $picking, arrowEdge: .leading) {
                        MaskPicker(mode: .new) { picking = false }
                            .environment(model)
                    }
                    MaskPresetsMenu()
                }
            }
        }
        .padding(.bottom, 10)
    }
}

/// The overlay's switch and its options, Pins, and a menu of commands for every mask, in the Masks
/// panel's header.
struct MasksHeaderControls: View {
    @Environment(EditorModel.self) private var model
    @State private var choosingOverlay = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            headerToggle(
                model.showMaskOverlay ? "circle.lefthalf.filled" : "circle", isOn: $model.showMaskOverlay,
                help: "Show Overlay (O)", identifier: "masks.overlay",
            )
            Button {
                choosingOverlay.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.label)
            .help("Overlay mode, color and opacity")
            .accessibilityLabel("Overlay Options")
            .automationIdentifier("masks.overlayOptions")
            .popover(isPresented: $choosingOverlay, arrowEdge: .leading) {
                MaskOverlayOptions()
                    .environment(model)
            }
            headerToggle(
                model.showMaskPins ? "mappin.circle.fill" : "mappin.circle", isOn: $model.showMaskPins,
                help: "Show Pins (H)", identifier: "masks.pins",
            )
            MaskActionsMenu()
        }
    }

    private func headerToggle(_ symbol: String, isOn: Binding<Bool>, help: String, identifier: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: symbol).font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Theme.label)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
        .automationIdentifier(identifier)
    }
}

/// Where a picker's mask goes: a new mask, or a component of `target` with `operation`.
@_spi(Harness) public enum MaskPickerMode: Equatable {
    case new
    case component(MaskOperation, target: UUID)

    var operation: MaskOperation {
        if case let .component(operation, _) = self {
            return operation
        }
        return .add
    }

    var target: UUID? {
        if case let .component(_, target) = self {
            return target
        }
        return nil
    }

    /// "New Mask", "Add to Sky", "Subtract from Sky", "Intersect with Sky".
    func title(targetName: String?) -> String {
        guard case let .component(operation, _) = self, let name = targetName else { return "New Mask" }
        return switch operation {
        case .add: "Add to \(name)"
        case .subtract: "Subtract from \(name)"
        case .intersect: "Intersect with \(name)"
        }
    }
}

/// The picker's groups of mask kinds, laid out as the tile grid was.
enum MaskKindGroup: String, CaseIterable, Identifiable {
    case ai = "AI"
    case drawn = "Drawn"
    case range = "Range"

    var id: String {
        rawValue
    }

    var kinds: [MaskKind] {
        switch self {
        case .ai: [.subject, .sky, .background, .people, .objects, .landscape]
        case .drawn: [.brush, .linear, .radial]
        case .range: [.colorRange, .luminanceRange, .depthRange]
        }
    }
}

/// One picker for every mask: New Mask, and Add, Subtract and Intersect on a mask's components.
/// A tile whose model isn't on this Mac asks here before anything downloads; the rest close the
/// picker and start their mask.
@_spi(Harness) public struct MaskPicker: View {
    let mode: MaskPickerMode
    /// In the panel itself (no masks yet) rather than in a popover.
    var inline = false
    var dismiss: () -> Void = {}
    @Environment(EditorModel.self) private var model

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    public init(mode: MaskPickerMode, inline: Bool = false, dismiss: @escaping () -> Void = {}) {
        self.mode = mode
        self.inline = inline
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(mode.title(targetName: targetName))
                .font(inline ? Theme.sectionFont : Theme.labelFont.weight(.semibold))
                .foregroundStyle(inline ? Theme.secondaryLabel : Theme.value)
            ForEach(MaskKindGroup.allCases) { group in
                VStack(alignment: .leading, spacing: 5) {
                    Text(group.rawValue.uppercased())
                        .font(Theme.sectionFont)
                        .tracking(0.6)
                        .foregroundStyle(Theme.tertiaryLabel)
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(group.kinds, id: \.self) { kind in
                            tile(kind)
                        }
                    }
                }
            }
            if let target = mode.target {
                let others = model.maskOutlines.filter { $0.id != target }
                if !others.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("EXISTING MASK")
                            .font(Theme.sectionFont)
                            .tracking(0.6)
                            .foregroundStyle(Theme.tertiaryLabel)
                        ForEach(others) { other in
                            Button {
                                model.addMaskReference(other.id, to: target, operation: mode.operation)
                                dismiss()
                            } label: {
                                Label(other.name, systemImage: other.components.first?.kind?.symbol ?? "circle.dashed")
                                    .font(Theme.labelFont)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .automationIdentifier("masks.picker.existing.\(other.id.uuidString)")
                        }
                    }
                }
            }
            // Inline, the picker sits under the panel's messages, which ask already.
            if !inline, model.pendingModel != nil || model.offeredModels != nil {
                ModelDownloadNotice(onProceed: dismiss)
            }
        }
        .padding(inline ? 0 : 12)
        .frame(width: inline ? nil : 300)
    }

    private var targetName: String? {
        mode.target.flatMap { target in model.maskOutlines.first { $0.id == target }?.name }
    }

    private func tile(_ kind: MaskKind) -> some View {
        Group {
            if kind == .people {
                Button {
                    model.openPeoplePicker(mode)
                    dismiss()
                } label: {
                    face(kind)
                }
            } else if kind == .landscape {
                Button {
                    chooseLandscape()
                } label: {
                    face(kind)
                }
            } else {
                Button {
                    choose(kind)
                } label: {
                    face(kind)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!model.canCreateMask(kind) || model.aiMaskProgress != nil)
        .help(model.canCreateMask(kind) ? kind.name : "\(kind.name) isn't available for this photo")
        .automationIdentifier("masks.picker.\(kind.rawValue)")
    }

    private func face(_ kind: MaskKind) -> some View {
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

    private func choose(_ kind: MaskKind) {
        let (operation, target) = (mode.operation, mode.target)
        Task {
            if kind.isAI, await model.asksBeforeMaking(kind) {
                // Records the question, which this picker shows; the mask follows the answer.
                await model.startAIMask(kind, operation: operation, addingTo: target)
                return
            }
            dismiss()
            model.startDrawing(kind, operation: operation, addingTo: target)
        }
    }

    /// Landscape asks here for SAM 3 when it isn't downloaded, and opens its own picker, now or
    /// after a yes.
    private func chooseLandscape() {
        let mode = mode
        Task {
            if await model.engine.modelNeeded(for: .landscape) != nil {
                await model.startAIMask(.landscape, operation: mode.operation, addingTo: mode.target)
                return
            }
            dismiss()
            model.openLandscapePicker(mode)
        }
    }
}

/// Progress, a download's question and failures, at the top of the Masks panel, rather than in a
/// status line under it.
struct MaskMessages: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        Group {
            if model.pendingModel != nil || model.offeredModels != nil {
                ModelDownloadNotice()
            } else if let progress = model.modelDownloadProgress {
                row {
                    ProgressView(value: progress).controlSize(.small).frame(width: 60)
                    Text("Downloading model… \(Int(progress * 100))%")
                }
            } else if let kind = model.aiMaskProgress {
                row {
                    ProgressView().controlSize(.small)
                    Text(kind == .subject && model.aiMaskCount > 0
                        ? "Updating AI masks…" : "Finding \(kind.name.lowercased())…")
                }
            } else if let message = model.maskMessage {
                NoticeCard(message, tone: .caution, dismiss: { model.maskMessage = nil }) {
                    Button("Report…") {
                        model.sendFeedback(FeedbackPrefill(
                            featureID: FeedbackContext.suggestion(model),
                            message: message,
                        ))
                    }
                    .buttonStyle(.link)
                    .font(Theme.labelFont)
                    .help("Report a Bug about this message")
                }
            }
        }
        .padding(.bottom, 8)
    }

    /// A row in the list's place, as the mask being made will have.
    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) {
            content()
            Spacer()
        }
        .font(Theme.labelFont)
        .foregroundStyle(Theme.label)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.well))
    }
}

/// Add, Subtract and Intersect, sharing the row's width, each opening the picker for the mask's
/// components.
struct ComponentOperationButtons: View {
    let mask: MaskOutline
    @Environment(EditorModel.self) private var model
    @State private var picking: MaskOperation?

    var body: some View {
        HStack(spacing: 6) {
            ForEach([MaskOperation.add, .subtract, .intersect], id: \.self) { operation in
                Button {
                    picking = operation
                } label: {
                    Label(operation.name, systemImage: operation.symbol)
                        .font(Theme.labelFont)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .automationIdentifier("masks.\(operation.rawValue)")
                .popover(isPresented: Binding(
                    get: { picking == operation }, set: {
                        if !$0 {
                            picking = nil
                        }
                    },
                ), arrowEdge: .leading) {
                    MaskPicker(mode: .component(operation, target: mask.id)) { picking = nil }
                        .environment(model)
                }
            }
        }
        // Small buttons are 20.12 pt tall; a whole height puts them, and the rows under them,
        // on the same pixels in the AppKit panel.
        .frame(height: Metrics.rowHeight)
    }
}

/// A mask's coverage, small, white where it covers (`EditorModel.maskThumbnails`), or its first
/// component's symbol until it's drawn.
struct MaskThumbnail: View {
    let image: CGImage?
    let symbol: String?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: symbol ?? "circle.dashed")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
        .frame(width: 30, height: 20)
        .background(RoundedRectangle(cornerRadius: 3).fill(image == nil ? Color.clear : Color.black))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// Draws the list's thumbnails again a moment after a mask's coverage may have changed, so a
/// slider's drag draws them once, when it stops.
struct MaskThumbnailRefresher: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        Color.clear
            .task(id: model.maskCoverageKeys) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await model.refreshMaskThumbnails()
            }
    }
}
