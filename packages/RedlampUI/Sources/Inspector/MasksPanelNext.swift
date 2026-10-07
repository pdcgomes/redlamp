import RedlampEngineAPI
import SwiftUI

/// The Masks panel as redesigned (`docs/plans/2026-10-07-masks-panel-design.md`), built in the
/// harness first: it replaces `MaskingPanel` in the editor once every task in the design's
/// checklist works through it. From UX-20: one picker starts every mask, the list's actions sit
/// in the header, and messages and the armed tool show at the top of the list. From UX-22: every
/// action is on screen, not only in context menus. From UX-23: each row shows its mask's
/// coverage, and the canvas previews the mask under the pointer.
@_spi(Harness) public struct MasksPanelNext: View {
    @Environment(EditorModel.self) private var model

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MasksHeaderNext()
            if model.drawingKind != nil || model.isRefiningEdges {
                DrawingHint()
            }
            MaskMessages()
            if model.maskOutlines.isEmpty {
                MaskPicker(mode: .new, inline: true)
                    .padding(.horizontal, Theme.panelPadding)
                    .padding(.bottom, 12)
            } else {
                MaskList(actionsOnScreen: true)
                    .padding(.horizontal, Theme.panelPadding)
                    .padding(.bottom, 8)
                    .background(MaskThumbnailRefresher())
                Rectangle().fill(Theme.divider).frame(height: 1)
                if let mask = model.selectedOutline {
                    SelectedMaskEditor(mask: mask, usesPicker: true)
                } else {
                    NoMaskSelected()
                }
            }
        }
    }
}

/// The panel's title, New Mask, and the controls that act on every mask, so they stay put as
/// the list grows.
struct MasksHeaderNext: View {
    @Environment(EditorModel.self) private var model
    @State private var picking = false
    @State private var choosingOverlay = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            Text("Masks")
                .font(Theme.panelTitleFont)
                .foregroundStyle(Theme.value)
            Spacer()
            Button {
                picking = true
            } label: {
                Label("New Mask", systemImage: "plus").font(Theme.labelFont)
            }
            .controlSize(.small)
            .disabled(model.info == nil)
            .help("Make a new mask")
            .popover(isPresented: $picking, arrowEdge: .leading) {
                MaskPicker(mode: .new) { picking = false }
                    .environment(model)
            }
            MaskPresetsMenu()
            headerToggle(
                model.showMaskOverlay ? "circle.lefthalf.filled" : "circle", isOn: $model.showMaskOverlay,
                help: "Show Overlay (O)",
            )
            Button {
                choosingOverlay.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.label)
            .help("Overlay mode, color and opacity")
            .popover(isPresented: $choosingOverlay, arrowEdge: .leading) {
                MaskOverlayOptions()
                    .environment(model)
            }
            headerToggle(
                model.showMaskPins ? "mappin.circle.fill" : "mappin.circle", isOn: $model.showMaskPins,
                help: "Show Pins (H)",
            )
            MaskActionsMenu()
        }
        .padding(.horizontal, Theme.panelPadding)
        .padding(.vertical, 10)
    }

    private func headerToggle(_ symbol: String, isOn: Binding<Bool>, help: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: symbol).font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Theme.label)
        .help(help)
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
                        }
                    }
                }
            }
            if model.pendingModel != nil {
                ModelDownloadNotice(onDownload: dismiss)
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
                Menu {
                    ForEach(model.availablePersonParts, id: \.self) { part in
                        Button(part.name) { choose(.people, part: part) }
                    }
                } label: {
                    face(kind)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
            } else if kind == .landscape {
                Menu {
                    ForEach(LandscapeClass.allCases, id: \.self) { cls in
                        Button(cls.name) { choose(.landscape, landscape: cls) }
                    }
                } label: {
                    face(kind)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
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

    private func choose(_ kind: MaskKind, part: PersonPart = .entirePerson, landscape: LandscapeClass = .vegetation) {
        let (operation, target) = (mode.operation, mode.target)
        Task {
            if kind.isAI, await model.engine.modelNeeded(for: kind, part: part) != nil {
                // Records the question, which this picker shows; the mask follows a yes.
                await model.startAIMask(kind, part: part, landscape: landscape, operation: operation, addingTo: target)
                return
            }
            dismiss()
            if kind == .people || kind == .landscape {
                await model.startAIMask(kind, part: part, landscape: landscape, operation: operation, addingTo: target)
            } else {
                model.startDrawing(kind, operation: operation, addingTo: target)
            }
        }
    }
}

/// Progress, a download's question and failures, at the top of the list where the mask they
/// concern appears, rather than in a status line under it.
struct MaskMessages: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        Group {
            if model.pendingModel != nil {
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
        .padding(.horizontal, Theme.panelPadding)
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

/// Add, Subtract and Intersect, each opening the picker for the mask's components.
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
                    Label(operation.name, systemImage: operation.symbol).font(Theme.labelFont)
                }
                .controlSize(.small)
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
