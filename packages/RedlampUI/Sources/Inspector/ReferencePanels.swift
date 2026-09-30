import RedlampEngineAPI
import SwiftUI

// Panels whose controls are laid out for fidelity but mostly render in later phases.
// Their sliders come straight from the parameter schema, so they light up automatically
// when the engine marks a parameter live.

@_spi(Harness) public struct DetailPanel: View {
    public init() {}

    public var body: some View {
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

@_spi(Harness) public struct LensPanel: View {
    public init() {}

    public var body: some View {
        PanelSection(panel: .lens, badge: "Phase 2") {
            LensToggle(title: "Remove Chromatic Aberration", help: nil)
            LensToggle(title: "Enable Profile Corrections", help: "lensfun and LCP lens profiles arrive in Phase 2")
            SubsectionHeader(title: "Manual", parameters: [.lensDistortion, .lensVignetting, .lensVignettingMidpoint])
            ParameterSlider(parameter: .lensDistortion)
            ParameterSlider(parameter: .lensVignetting)
            ParameterSlider(parameter: .lensVignettingMidpoint)
        }
    }
}

// The reference panels' native controls, shared with the AppKit panels.

struct LensToggle: View {
    let title: String
    let help: String?

    var body: some View {
        Toggle(title, isOn: .constant(false))
            .disabled(true)
            .help(help ?? "")
            .font(Theme.labelFont)
            .toggleStyle(.checkbox)
            .controlSize(.small)
    }
}

struct UprightButtons: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(["Off", "Auto", "Guided", "Level", "Vertical", "Full"], id: \.self) { mode in
                Button(mode) {}
                    .controlSize(.mini)
                    .disabled(true)
            }
        }
    }
}

struct VignetteStylePicker: View {
    var body: some View {
        Picker("Style", selection: .constant(0)) {
            Text("Highlight Priority").tag(0)
        }
        .labelsHidden()
        .controlSize(.small)
        .disabled(true)
    }
}

struct ProcessVersion: View {
    var body: some View {
        Text("Redlamp v1").font(Theme.labelFont).foregroundStyle(Theme.value)
    }
}

@_spi(Harness) public struct TransformPanel: View {
    public init() {}

    public var body: some View {
        PanelSection(panel: .transform, badge: "Phase 2") {
            ControlRow(label: "Upright") { UprightButtons() }
            SubsectionHeader(title: "Manual", parameters: PanelID.transform.parameters)
            ForEach(PanelID.transform.parameters, id: \.self) { ParameterSlider(parameter: $0) }
        }
    }
}

@_spi(Harness) public struct EffectsPanel: View {
    public init() {}

    public var body: some View {
        PanelSection(panel: .effects) {
            SubsectionHeader(title: "Post-Crop Vignetting", parameters: [
                .vignetteAmount, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather, .vignetteHighlights,
            ])
            ControlRow(label: "Style") { VignetteStylePicker() }
            ParameterSlider(parameter: .vignetteAmount)
            ParameterSlider(parameter: .vignetteMidpoint)
            ParameterSlider(parameter: .vignetteRoundness)
            ParameterSlider(parameter: .vignetteFeather)
            ParameterSlider(parameter: .vignetteHighlights)
            SubsectionHeader(title: "Grain", parameters: [.grainAmount, .grainSize, .grainRoughness])
            ParameterSlider(parameter: .grainAmount)
            ParameterSlider(parameter: .grainSize)
            ParameterSlider(parameter: .grainRoughness)
            SubsectionHeader(title: "Camera Recipe", parameters: PanelID.cameraRecipeParameters)
            ForEach(PanelID.cameraRecipeParameters, id: \.self) { ParameterSlider(parameter: $0) }
        }
    }
}

@_spi(Harness) public struct CalibrationPanel: View {
    public init() {}

    public var body: some View {
        PanelSection(panel: .calibration, badge: "Phase 2") {
            ControlRow(label: "Process") { ProcessVersion() }
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

@_spi(Harness) public enum DevelopPanels {
    /// Shows the SwiftUI panels instead of the AppKit ones, for side-by-side measurements.
    /// Set before the window appears.
    @MainActor public static var usesSwiftUI = false
}

/// The Develop panels as SwiftUI views: the reference the AppKit panels are matched
/// against, pixel for pixel, in the harness.
@_spi(Harness) public struct SwiftUIDevelopPanels: View {
    public init() {}

    public var body: some View {
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
    }
}

/// The right-hand column in SwiftUI: the reference the AppKit column (`InspectorColumnView`)
/// is checked against.
@_spi(Harness) public struct InspectorView: View {
    @Environment(EditorModel.self) private var model

    public init() {}

    public var body: some View {
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
                    SwiftUIDevelopPanels()
                } else if model.activeTool == .masking {
                    MaskingPanel()
                } else {
                    PlannedToolCard(tool: model.activeTool)
                }
            }
            .scrollIndicators(.automatic)

            Rectangle().fill(Theme.divider).frame(height: 1)
            InspectorFooter()
        }
    }
}

/// Previous and Reset, under the panels.
struct InspectorFooter: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        HStack {
            Button("Previous") { model.pasteFromPrevious() }
                .disabled(model.previousSelection == nil || model.info == nil)
                .help("Apply the previously viewed photo's settings (⌥⌘V)")
            Spacer()
            Button("Reset") { model.resetAll() }
                .disabled(model.info == nil)
                .help("Reset all settings (⇧⌘R)")
        }
        .controlSize(.small)
        .padding(10)
    }
}
