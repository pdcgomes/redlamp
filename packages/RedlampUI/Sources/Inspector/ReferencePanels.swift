import RedlampEngineAPI
import SwiftUI

// Detail, Lens Corrections, Transform, Effects and Calibration. Their sliders come straight from
// the parameter schema, so any the engine doesn't render yet (Calibration's) show dimmed with
// their phase.

@_spi(Harness) public struct DetailPanel: View {
    public init() {}

    public var body: some View {
        PanelSection(panel: .detail) {
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

    static let defringe: [ParameterID] = [
        .defringePurpleAmount, .defringePurpleHueLow, .defringePurpleHueHigh, .defringeGreenAmount,
        .defringeGreenHueLow, .defringeGreenHueHigh,
    ]

    public var body: some View {
        PanelSection(panel: .lens) {
            ParameterToggle(
                parameter: .lensRemoveChromaticAberration,
                help: "Realign red and blue fringes at edges, from the lens profile or measured from the photo",
            )
            ProfileCorrectionsToggle()
            SubsectionHeader(title: "Profile", parameters: [.lensProfileDistortion, .lensProfileVignetting])
            ParameterSlider(parameter: .lensProfileDistortion)
            ParameterSlider(parameter: .lensProfileVignetting)
            SubsectionHeader(title: "Defringe", parameters: Self.defringe)
            ForEach(Self.defringe, id: \.self) { ParameterSlider(parameter: $0) }
            SubsectionHeader(title: "Manual", parameters: [.lensDistortion, .lensVignetting, .lensVignettingMidpoint])
            ParameterSlider(parameter: .lensDistortion)
            ParameterSlider(parameter: .lensVignetting)
            ParameterSlider(parameter: .lensVignettingMidpoint)
        }
    }
}

// The reference panels' native controls, shared with the AppKit panels.

/// A checkbox for an on/off parameter (0 or 1).
struct ParameterToggle: View {
    @Environment(EditorModel.self) private var model
    let parameter: ParameterID
    let help: String

    var body: some View {
        Toggle(parameter.spec.label, isOn: Binding(
            get: { model.recipe[parameter] > 0.5 },
            set: { model.setValue(parameter, $0 ? 1 : 0) },
        ))
        .disabled(model.info == nil)
        .help(help)
        .font(Theme.labelFont)
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }
}

/// Enable Profile Corrections: the lens correction the photo carries (DNG opcodes, Sony's tags),
/// on by default from process 5. lensfun profiles wait on DEC-04.
struct ProfileCorrectionsToggle: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        let lens = model.info?.lensCorrection
        let applies = lens != nil && model.recipe.processVersion >= 5
        Toggle("Enable Profile Corrections", isOn: Binding(
            get: { applies && model.recipe[.lensProfile] > 0.5 },
            set: { model.setValue(.lensProfile, $0 ? 1 : 0) },
        ))
        .disabled(!applies)
        .help(help(lens, applies: applies))
        .font(Theme.labelFont)
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }

    private func help(_ lens: LensCorrection?, applies: Bool) -> String {
        guard let lens else { return "This photo carries no lens correction" }
        guard applies else { return "Edits made before process 5 render without the lens correction" }
        return "Distortion and vignetting corrections from the \(lens.source.name) file itself"
            + (lens.correctsColorFringes ? ", with its colour fringe correction" : "")
    }
}

/// Upright: Off, the automatic modes from the photo's own edges, and Guided.
struct UprightButtons: View {
    @Environment(EditorModel.self) private var model

    /// Two rows of three equal buttons, in Lightroom's order: six don't fit beside the label at
    /// the inspector's width without truncating.
    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                button("Off", "Remove Upright's perspective and rotation") { model.clearUpright() }
                mode(.auto, "Level, verticals and perspective, balanced so the result still looks natural")
                button("Guided", "Draw up to four guides along edges that should be vertical or horizontal") {
                    model.isPlacingGuides.toggle()
                }
                .tint(model.isPlacingGuides ? Color.accentColor : nil)
            }
            GridRow {
                mode(.level, "Level the photo by its horizontal and vertical edges")
                mode(.vertical, "Level the photo and make converging verticals parallel")
                mode(.full, "Level the photo, make verticals parallel and horizontals level")
            }
        }
    }

    private func mode(_ mode: UprightMode, _ help: String) -> some View {
        button(mode.name, help) { model.applyUpright(mode) }
            .disabled(model.info == nil)
    }

    private func button(_ title: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .help(help)
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

/// The Frame border (`ParameterID.frameStyle`), as a menu of its styles.
struct FrameStylePicker: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        Picker("Style", selection: Binding(
            get: { Int(model.recipe[.frameStyle].rounded()) },
            set: { model.setValue(.frameStyle, Double($0)) },
        )) {
            ForEach(FrameStyle.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
        }
        .labelsHidden()
        .controlSize(.small)
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
        PanelSection(panel: .transform) {
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
            SubsectionHeader(title: "Grain", parameters: [.grainAmount, .grainSize, .grainRoughness, .grainColor])
            ParameterSlider(parameter: .grainAmount)
            ParameterSlider(parameter: .grainSize)
            ParameterSlider(parameter: .grainRoughness)
            ParameterSlider(parameter: .grainColor)
            SubsectionHeader(title: "Halation", parameters: [.halationAmount, .halationSize])
            ParameterSlider(parameter: .halationAmount)
            ParameterSlider(parameter: .halationSize)
            SubsectionHeader(title: "Bloom", parameters: [.bloomAmount, .bloomSize])
            ParameterSlider(parameter: .bloomAmount)
            ParameterSlider(parameter: .bloomSize)
            SubsectionHeader(title: "Light Leak", parameters: [.leakAmount, .leakWarmth, .leakVariation])
            ParameterSlider(parameter: .leakAmount)
            ParameterSlider(parameter: .leakWarmth)
            ParameterSlider(parameter: .leakVariation)
            SubsectionHeader(title: "Dust & Scratches", parameters: [.dustAmount, .scratchAmount])
            ParameterSlider(parameter: .dustAmount)
            ParameterSlider(parameter: .scratchAmount)
            SubsectionHeader(title: "Frame", parameters: [.frameStyle, .frameSize])
            ControlRow(label: "Style") { FrameStylePicker() }
            ParameterSlider(parameter: .frameSize)
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
                } else if model.activeTool == .crop {
                    CropToolPanel()
                    ParameterSlider(parameter: .cropAngle)
                        .padding(.horizontal, Theme.panelPadding)
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
