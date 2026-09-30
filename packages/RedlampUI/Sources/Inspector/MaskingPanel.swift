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
                CreateMaskGrid(title: "Create New Mask") { kind in model.startDrawing(kind) }
                    .padding(.horizontal, Theme.panelPadding)
                    .padding(.bottom, 12)
                if model.drawingKind != nil {
                    DrawingHint()
                }
            } else {
                MaskList()
                    .padding(.horizontal, Theme.panelPadding)
                MaskActionsBar()

                if model.drawingKind != nil {
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
        }
        .padding(.horizontal, Theme.panelPadding)
        .padding(.vertical, 10)
    }
}

struct MaskActionsBar: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        HStack {
            CreateMaskMenu(title: "Create New Mask", systemImage: "plus") { kind in
                model.startDrawing(kind)
            }
            Spacer()
            Menu {
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

struct DrawingHint: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.drawingKind?.symbol ?? "hand.draw")
            Text(model.drawingKind == .radial
                ? "Drag on the photo to draw the radial gradient. Shift keeps it circular."
                : "Drag on the photo from full effect to no effect.")
            Spacer()
            Button("Cancel") { model.cancelDrawing() }
                .controlSize(.mini)
        }
        .font(Theme.captionFont)
        .foregroundStyle(Theme.label)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.selection))
        .padding(.horizontal, Theme.panelPadding)
        .padding(.bottom, 10)
    }
}

/// Every mask type, like Lightroom's Create New Mask menu. Types from later phases are
/// visible but disabled, with their phase in the tooltip.
struct CreateMaskGrid: View {
    let title: String
    let onCreate: (MaskKind) -> Void

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(Theme.sectionFont)
                .tracking(0.6)
                .foregroundStyle(Theme.secondaryLabel)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(MaskKind.allCases, id: \.self) { kind in
                    Button {
                        onCreate(kind)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: kind.symbol).font(.system(size: 16))
                            Text(kind.name)
                                .font(.system(size: 9.5))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(kind.isAvailable ? Theme.value : Theme.tertiaryLabel)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!kind.isAvailable)
                    .help(kind.plannedPhase.map { "\(kind.name) arrives in \($0)" } ?? kind.name)
                }
            }
        }
    }
}

struct CreateMaskMenu: View {
    let title: String
    let systemImage: String
    let onCreate: (MaskKind) -> Void

    var body: some View {
        Menu {
            ForEach(MaskKind.allCases, id: \.self) { kind in
                Button {
                    onCreate(kind)
                } label: {
                    Label(
                        kind.plannedPhase.map { "\(kind.name) (\($0))" } ?? kind.name,
                        systemImage: kind.symbol,
                    )
                }
                .disabled(!kind.isAvailable)
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
                    Image(systemName: mask.components.first?.kind.symbol ?? "circle.dashed")
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
                .contextMenu {
                    Button("Rename…") {
                        draftName = mask.name
                        renaming = mask.id
                    }
                    Button("Duplicate") { model.duplicateMask(mask.id) }
                    Button("Duplicate and Invert") { model.duplicateMask(mask.id, inverted: true) }
                    Button("Reset Adjustments") { model.resetMaskAdjustments(mask.id) }
                    Divider()
                    Button("Delete \(mask.name)", role: .destructive) { model.deleteMask(mask.id) }
                }
            }
        }
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

            if model.selectedComponentOutline?.kind == .radial {
                ParameterSlider(parameter: .maskFeather)
                    .padding(.top, 6)
            }

            SubsectionHeader(title: mask.name, parameters: []) {
                ResetMaskButton(mask: mask)
            }
            ParameterSlider(parameter: .maskAmount)
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
    static let gapAfter: Set<ParameterID> = [.localTint, .localBlacks, .localDehaze]
}

/// Add, Subtract and Intersect: draw another component into the mask.
struct ComponentOperationMenus: View {
    let mask: MaskOutline
    @Environment(EditorModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            ForEach([MaskOperation.add, .subtract, .intersect], id: \.self) { operation in
                CreateMaskMenu(title: operation.name, systemImage: operation.symbol) { kind in
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
            Image(systemName: component.kind.symbol)
                .font(.system(size: 11))
            Text("\(component.kind.name) \(index)")
                .font(Theme.labelFont)
            Spacer()
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
        .contextMenu {
            ForEach(MaskOperation.allCases, id: \.self) { operation in
                Button("Set to \(operation.name)") { model.setComponentOperation(component.id, in: mask.id, operation) }
            }
        }
    }
}
