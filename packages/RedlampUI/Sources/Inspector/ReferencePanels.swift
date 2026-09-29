import RedlampEngineAPI
import SwiftUI

// Panels whose controls are laid out for fidelity but mostly render in later phases.
// Their sliders come straight from the parameter schema, so they light up automatically
// when the engine marks a parameter live.

struct DetailPanel: View {
    var body: some View {
        PanelSection(panel: .detail, badge: "Phase 2") {
            SubsectionHeader(
                title: "Sharpening",
                parameters: [.sharpenAmount, .sharpenRadius, .sharpenDetail, .sharpenMasking],
            )
            ParameterSlider(parameter: .sharpenAmount)
            ParameterSlider(parameter: .sharpenRadius)
            ParameterSlider(parameter: .sharpenDetail)
            ParameterSlider(parameter: .sharpenMasking)
            SubsectionHeader(
                title: "Noise Reduction",
                parameters: [.noiseLuminance, .noiseLuminanceDetail, .noiseLuminanceContrast],
            )
            ParameterSlider(parameter: .noiseLuminance)
            ParameterSlider(parameter: .noiseLuminanceDetail)
            ParameterSlider(parameter: .noiseLuminanceContrast)
            Spacer().frame(height: 4)
            ParameterSlider(parameter: .noiseColor)
            ParameterSlider(parameter: .noiseColorDetail)
            ParameterSlider(parameter: .noiseColorSmoothness)
        }
    }
}

struct LensPanel: View {
    var body: some View {
        PanelSection(panel: .lens, badge: "Phase 2") {
            Toggle("Remove Chromatic Aberration", isOn: .constant(false))
                .disabled(true)
            Toggle("Enable Profile Corrections", isOn: .constant(false))
                .disabled(true)
                .help("lensfun and LCP lens profiles arrive in Phase 2")
            SubsectionHeader(title: "Manual", parameters: [.lensDistortion, .lensVignetting, .lensVignettingMidpoint])
            ParameterSlider(parameter: .lensDistortion)
            ParameterSlider(parameter: .lensVignetting)
            ParameterSlider(parameter: .lensVignettingMidpoint)
        }
        .font(Theme.labelFont)
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }
}

struct TransformPanel: View {
    var body: some View {
        PanelSection(panel: .transform, badge: "Phase 2") {
            ControlRow(label: "Upright") {
                HStack(spacing: 4) {
                    ForEach(["Off", "Auto", "Guided", "Level", "Vertical", "Full"], id: \.self) { mode in
                        Button(mode) {}
                            .controlSize(.mini)
                            .disabled(true)
                    }
                }
            }
            SubsectionHeader(title: "Manual", parameters: PanelID.transform.parameters)
            ForEach(PanelID.transform.parameters, id: \.self) { ParameterSlider(parameter: $0) }
        }
    }
}

struct EffectsPanel: View {
    var body: some View {
        PanelSection(panel: .effects) {
            SubsectionHeader(title: "Post-Crop Vignetting", parameters: [
                .vignetteAmount, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather, .vignetteHighlights,
            ])
            ControlRow(label: "Style") {
                Picker("Style", selection: .constant(0)) {
                    Text("Highlight Priority").tag(0)
                }
                .labelsHidden()
                .controlSize(.small)
                .disabled(true)
            }
            ParameterSlider(parameter: .vignetteAmount)
            ParameterSlider(parameter: .vignetteMidpoint)
            ParameterSlider(parameter: .vignetteRoundness)
            ParameterSlider(parameter: .vignetteFeather)
            ParameterSlider(parameter: .vignetteHighlights)
            SubsectionHeader(title: "Grain", parameters: [.grainAmount, .grainSize, .grainRoughness])
            ParameterSlider(parameter: .grainAmount)
            ParameterSlider(parameter: .grainSize)
            ParameterSlider(parameter: .grainRoughness)
        }
    }
}

struct CalibrationPanel: View {
    var body: some View {
        PanelSection(panel: .calibration, badge: "Phase 2") {
            ControlRow(label: "Process") {
                Text("Redlamp v1").font(Theme.labelFont).foregroundStyle(Theme.value)
            }
            SubsectionHeader(title: "Shadows", parameters: [.calibrationShadowsTint])
            ParameterSlider(parameter: .calibrationShadowsTint)
            SubsectionHeader(title: "Red Primary", parameters: [.calibrationRedHue, .calibrationRedSaturation])
            ParameterSlider(parameter: .calibrationRedHue)
            ParameterSlider(parameter: .calibrationRedSaturation)
            SubsectionHeader(title: "Green Primary", parameters: [.calibrationGreenHue, .calibrationGreenSaturation])
            ParameterSlider(parameter: .calibrationGreenHue)
            ParameterSlider(parameter: .calibrationGreenSaturation)
            SubsectionHeader(title: "Blue Primary", parameters: [.calibrationBlueHue, .calibrationBlueSaturation])
            ParameterSlider(parameter: .calibrationBlueHue)
            ParameterSlider(parameter: .calibrationBlueSaturation)
        }
    }
}

/// The right-hand column: histogram, tool strip and the Develop panels.
struct InspectorView: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HistogramView()
                ToolStrip()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)

            Rectangle().fill(Theme.divider).frame(height: 1)

            ScrollView {
                if model.activeTool == .edit {
                    LazyVStack(spacing: 0) {
                        BasicPanel()
                        ToneCurvePanel()
                        ColorMixerPanel()
                        ColorGradingPanel()
                        DetailPanel()
                        LensPanel()
                        TransformPanel()
                        EffectsPanel()
                        CalibrationPanel()
                    }
                } else {
                    PlannedToolCard(tool: model.activeTool)
                }
            }
            .scrollIndicators(.automatic)

            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack {
                Button("Previous") {}
                    .disabled(true)
                    .help("Apply the previous photo's settings (Phase 2)")
                Spacer()
                Button("Reset") { model.resetAll() }
                    .disabled(model.info == nil)
                    .help("Reset all settings (⇧⌘R)")
            }
            .controlSize(.small)
            .padding(10)
        }
    }
}
