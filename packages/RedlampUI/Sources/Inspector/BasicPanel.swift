import RedlampEngineAPI
import SwiftUI

struct BasicPanel: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        PanelSection(panel: .basic) {
            ControlRow(label: "Treatment") {
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

            ControlRow(label: "Profile") {
                Menu {
                    ForEach(BuiltInProfile.allCases, id: \.self) { profile in
                        Button {
                            model.setProfile(profile)
                        } label: {
                            if model.profile.id == profile.rawValue {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                    Divider()
                    Button("Browse Profiles, DCPs and LUTs…") {}.disabled(true)
                } label: {
                    Text(model.profile.name).font(Theme.labelFont)
                }
                .menuStyle(.button)
                .controlSize(.small)
                .help("Profile Browser with DCP and LUT import arrives in Phase 2")
            }

            whiteBalance

            SubsectionHeader(
                title: "Tone",
                parameters: [.exposure, .contrast, .highlights, .shadows, .whites, .blacks],
            ) {
                Button("Auto") { model.autoTone() }
                    .controlSize(.mini)
                    .disabled(model.info == nil)
                    .help("Auto tone (⌘U)")
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

    @ViewBuilder
    private var whiteBalance: some View {
        let supported = model.info?.supportsWhiteBalance ?? false
        @Bindable var model = model
        ControlRow(label: "White Balance") {
            Button {
                model.eyedropperActive.toggle()
            } label: {
                Image(systemName: "eyedropper")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 20)
                    .foregroundStyle(model.eyedropperActive ? Color.accentColor : Theme.label)
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
        ParameterSlider(parameter: .temperature, enabled: supported)
        ParameterSlider(parameter: .tint, enabled: supported)
    }
}
