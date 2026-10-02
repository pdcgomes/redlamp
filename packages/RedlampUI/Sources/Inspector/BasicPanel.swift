import RedlampDesign
import RedlampEngineAPI
import SwiftUI

@_spi(Harness) public struct BasicPanel: View {
    @Environment(EditorModel.self) private var model

    public init() {}

    public var body: some View {
        let supported = model.info?.supportsWhiteBalance ?? false
        PanelSection(panel: .basic) {
            ControlRow(label: "Treatment") { TreatmentPicker() }
            ControlRow(label: "Base Look") { BaseLookMenu() }
            BaseLookAmountRow()
            ControlRow(label: "White Balance") { WhiteBalanceControls() }
            ParameterSlider(parameter: .temperature, enabled: supported)
            ParameterSlider(parameter: .tint, enabled: supported)

            SubsectionHeader(
                title: "Tone",
                parameters: [.exposure, .contrast, .highlights, .shadows, .whites, .blacks],
            ) {
                AutoToneButton()
            }
            ParameterSlider(parameter: .exposure)
            ParameterSlider(parameter: .contrast)
            Spacer().frame(height: 4)
            ParameterSlider(parameter: .highlights)
            ParameterSlider(parameter: .shadows)
            ParameterSlider(parameter: .whites)
            ParameterSlider(parameter: .blacks)

            SubsectionHeader(title: "Presence", parameters: [.texture, .clarity, .dehaze, .vibrance, .saturation])
            ParameterSlider(parameter: .texture)
            ParameterSlider(parameter: .clarity)
            ParameterSlider(parameter: .dehaze)
            Spacer().frame(height: 4)
            ParameterSlider(parameter: .vibrance)
            ParameterSlider(parameter: .saturation)
        }
    }
}

// The Basic panel's native controls, shared by the SwiftUI panel and the AppKit port
// (which hosts each one on its own), so both show exactly the same controls.

struct TreatmentPicker: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        Picker("Treatment", selection: Binding(
            get: { model.treatment },
            set: { model.setTreatment($0) },
        )) {
            ForEach(Treatment.allCases, id: \.self) { Text($0.name).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }
}

/// The Base Look popup (Lightroom's Profile): built-in looks, the film-style looks, and
/// installed ones, plus the browser.
struct BaseLookMenu: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var browsing = false

    var body: some View {
        let current = model.baseLook
        let groups = BaseLookGroups(model.recipes.currentBaseLooks)
        Menu {
            if let embedded = model.info?.embeddedBaseLook,
               model.recipe.processVersion >= model.info?.embeddedBaseLookProcess ?? 0 {
                Section("In This Photo") {
                    Button {
                        model.setBaseLook(embedded)
                    } label: {
                        if embedded.isSameLook(as: current) {
                            Label(embedded.name, systemImage: "checkmark")
                        } else {
                            Text(embedded.name)
                        }
                    }
                    .help("The look of the camera profile embedded in this file")
                }
            }
            ForEach(groups.sections, id: \.name) { section in
                Section(section.name) {
                    ForEach(section.looks, id: \.self) { look in
                        Button {
                            model.setBaseLook(look.reference)
                        } label: {
                            if look.matches(current) {
                                Label(look.name, systemImage: "checkmark")
                            } else if let icon = FilmIconImage.image(for: look.id, points: 18) {
                                Label { Text(look.name) } icon: { Image(nsImage: icon) }
                            } else {
                                Text(look.name)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Browse Base Looks…") { browsing = true }
            Button("Film Looks…") { openWindow(id: FilmCatalogView.windowID) }
        } label: {
            Text(current.name).font(Theme.labelFont)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .help("The look under every slider (Lightroom: Profile). LUT looks can be imported from the Recipes panel.")
        .popover(isPresented: $browsing, arrowEdge: .leading) {
            BaseLookBrowser()
                .environment(model)
        }
    }
}

/// The Base Look's strength, as Lightroom's profile Amount.
struct BaseLookAmountRow: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        let amount = model.baseLook.amount
        HStack(spacing: 8) {
            Text("Amount").font(Theme.labelFont).foregroundStyle(Theme.secondaryLabel)
                .frame(width: Metrics.labelWidth, alignment: .leading)
            Slider(
                value: Binding(get: { amount }, set: { model.setBaseLookAmount($0) }),
                in: BaseLookReference.amountRange,
            ) { editing in
                if editing {
                    model.beginEdit()
                } else {
                    model.endEdit(.baseLook, "Base Look Amount", value: EditorModel.baseLookAmountText)
                }
            }
            .controlSize(.mini)
            Text("\(Int(amount.rounded()))").font(Theme.valueFont).monospacedDigit().frame(
                width: 30,
                alignment: .trailing,
            )
        }
        .onTapGesture(count: 2) { model.setBaseLookAmount(100) }
        .help("Base Look Amount: 0 turns the look off, 200 doubles it. Double-click to reset.")
    }
}

/// The eyedropper and the white balance preset menu.
struct WhiteBalanceControls: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        let supported = model.info?.supportsWhiteBalance ?? false
        @Bindable var model = model
        HStack(spacing: 6) {
            Button {
                model.eyedropperActive.toggle()
            } label: {
                Image(systemName: "eyedropper")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 20)
                    .foregroundStyle(model.eyedropperActive ? Theme.accent : Theme.label)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(model.eyedropperActive ? Theme.selection : .clear))
            }
            .buttonStyle(.plain)
            .disabled(!supported)
            .help("White Balance Selector (W): click a neutral area of the photo")

            Picker("White Balance", selection: Binding(
                get: { model.whiteBalanceMode },
                set: { model.setWhiteBalanceMode($0) },
            )) {
                ForEach(WhiteBalanceMode.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .disabled(!supported)
        }
    }
}

struct AutoToneButton: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        Button("Auto") { model.autoTone() }
            .controlSize(.mini)
            .disabled(model.info == nil)
            .help("Auto tone (⌘U)")
    }
}
