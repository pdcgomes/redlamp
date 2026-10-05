import Observation
import RedlampEngineAPI
import SwiftUI

@_spi(Harness) public struct ColorMixerPanel: View {
    public enum Mixer: String, CaseIterable {
        case hsl = "HSL"
        case color = "Color"
        case pointColor = "Point Color"
    }

    enum Attribute: String, CaseIterable {
        case hue = "Hue"
        case saturation = "Saturation"
        case luminance = "Luminance"
        case all = "All"

        func parameter(for band: ColorBand) -> ParameterID {
            switch self {
            case .hue, .all: band.hueParameter
            case .saturation: band.saturationParameter
            case .luminance: band.luminanceParameter
            }
        }
    }

    @Environment(EditorModel.self) private var model
    @State private var state: ColorMixerState

    public init(mixer: Mixer = .hsl) {
        _state = State(initialValue: ColorMixerState(mixer: mixer))
    }

    public var body: some View {
        PanelSection(panel: .colorMixer) {
            ControlRow(label: "Mixer") { MixerPicker(state: state) }
                .padding(.bottom, 4)

            switch state.mixer {
            case .hsl:
                AttributePicker(state: state)
                    .padding(.bottom, 4)

                if state.attribute == .all {
                    ForEach([Attribute.hue, .saturation, .luminance], id: \.self) { group in
                        SubsectionHeader(
                            title: group.rawValue,
                            parameters: ColorBand.allCases.map { group.parameter(for: $0) },
                        )
                        ForEach(ColorBand.allCases, id: \.self) { band in
                            ParameterSlider(parameter: group.parameter(for: band))
                        }
                    }
                } else {
                    ForEach(ColorBand.allCases, id: \.self) { band in
                        ParameterSlider(parameter: state.attribute.parameter(for: band))
                    }
                }

            case .color:
                BandSwatches(state: state)
                    .padding(.bottom, 6)
                ParameterSlider(parameter: state.band.hueParameter, label: "Hue")
                ParameterSlider(parameter: state.band.saturationParameter, label: "Saturation")
                ParameterSlider(parameter: state.band.luminanceParameter, label: "Luminance")

            case .pointColor:
                let picked = model.selectedPointColorSwatch != nil
                PointColorSwatches()
                    .padding(.bottom, 2)
                ForEach(PointColorGroup.all) { group in
                    SubsectionHeader(title: group.title, parameters: group.parameters)
                    ForEach(group.parameters, id: \.self) { parameter in
                        ParameterSlider(parameter: parameter, label: PointColorGroup.label(parameter), enabled: picked)
                    }
                }
                PointColorVisualizeToggle()
                    .padding(.top, 4)
            }
        }
        .onChange(of: state.mixer) { _, mixer in
            if mixer != .pointColor {
                model.leavePointColor()
            }
        }
    }
}

/// The Color Mixer's own view state (which mixer, attribute and band are showing), shared
/// by the SwiftUI panel and its AppKit port.
@MainActor @Observable
final class ColorMixerState {
    var mixer = ColorMixerPanel.Mixer.hsl {
        didSet {
            if mixer != oldValue {
                onChange()
            }
        }
    }

    var attribute = ColorMixerPanel.Attribute.hue {
        didSet {
            if attribute != oldValue {
                onChange()
            }
        }
    }

    var band = ColorBand.orange {
        didSet {
            if band != oldValue {
                onChange()
            }
        }
    }

    @ObservationIgnored var onChange: () -> Void = {}

    init(mixer: ColorMixerPanel.Mixer = .hsl) {
        self.mixer = mixer
    }
}

struct MixerPicker: View {
    @Bindable var state: ColorMixerState

    var body: some View {
        Picker("Mixer", selection: $state.mixer) {
            ForEach(ColorMixerPanel.Mixer.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }
}

struct AttributePicker: View {
    @Bindable var state: ColorMixerState

    var body: some View {
        Picker("Adjust", selection: $state.attribute) {
            ForEach(ColorMixerPanel.Attribute.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }
}

/// The eight color swatches of the per-color mixer.
struct BandSwatches: View {
    @Bindable var state: ColorMixerState

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ColorBand.allCases, id: \.self) { candidate in
                Button {
                    state.band = candidate
                } label: {
                    Circle()
                        .fill(candidate.color)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white, lineWidth: state.band == candidate ? 2 : 0)
                                .padding(-3),
                        )
                        .frame(maxWidth: .infinity, minHeight: 26)
                }
                .buttonStyle(.plain)
                .help(candidate.name)
            }
        }
    }
}

@_spi(Harness) public struct ColorGradingPanel: View {
    enum View3: String, CaseIterable {
        case threeWay = "3-Way"
        case shadows = "Shadows"
        case midtones = "Midtones"
        case highlights = "Highlights"
        case global = "Global"

        var range: GradingRange? {
            switch self {
            case .threeWay: nil
            case .shadows: .shadows
            case .midtones: .midtones
            case .highlights: .highlights
            case .global: .global
            }
        }

        var symbol: String {
            switch self {
            case .threeWay: "circle.grid.cross"
            case .shadows: "circle.fill"
            case .midtones: "circle.lefthalf.filled"
            case .highlights: "circle"
            case .global: "globe"
            }
        }
    }

    @State private var state = ColorGradingState()

    public init() {}

    public var body: some View {
        PanelSection(panel: .colorGrading) {
            GradingViewPicker(state: state)
                .padding(.bottom, 8)

            if let range = state.view.range {
                HStack {
                    Spacer()
                    ColorWheel(range: range, diameter: 170)
                    Spacer()
                }
                ParameterSlider(parameter: range.hueParameter)
                ParameterSlider(parameter: range.saturationParameter)
                ParameterSlider(parameter: range.luminanceParameter)
            } else {
                VStack(spacing: 10) {
                    wheel(.midtones, diameter: 118)
                    HStack(alignment: .top, spacing: 12) {
                        wheel(.shadows, diameter: 104)
                        wheel(.highlights, diameter: 104)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Spacer().frame(height: 6)
            ParameterSlider(parameter: .gradeBlending)
            ParameterSlider(parameter: .gradeBalance)
        }
    }

    private func wheel(_ range: GradingRange, diameter: CGFloat) -> some View {
        VStack(spacing: 4) {
            Text(range.name)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.secondaryLabel)
            ColorWheel(range: range, diameter: diameter)
            CompactLuminanceSlider(parameter: range.luminanceParameter)
                .frame(width: diameter)
        }
    }
}

/// Which grading view shows (3-way or one range), shared by the SwiftUI panel and its
/// AppKit port.
@MainActor @Observable
final class ColorGradingState {
    var view = ColorGradingPanel.View3.threeWay {
        didSet {
            if view != oldValue {
                onChange()
            }
        }
    }

    @ObservationIgnored var onChange: () -> Void = {}
}

struct GradingViewPicker: View {
    @Bindable var state: ColorGradingState

    var body: some View {
        Picker("Grading", selection: $state.view) {
            ForEach(ColorGradingPanel.View3.allCases, id: \.self) { option in
                Image(systemName: option.symbol).help(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }
}

/// A grading wheel: angle is hue, distance from centre is saturation. Color Grading's ranges and a
/// mask's Color swatch use it.
struct ColorWheel: View {
    let hueParameter: ParameterID
    let saturationParameter: ParameterID
    /// What it's called in its help, and the History step a drag makes.
    let label: String
    let stepName: String
    let diameter: CGFloat

    @Environment(EditorModel.self) private var model
    @State private var dragging = false

    init(range: GradingRange, diameter: CGFloat) {
        self.init(
            hue: range.hueParameter, saturation: range.saturationParameter, label: range.name,
            stepName: "\(range.name) Grading", diameter: diameter,
        )
    }

    init(hue: ParameterID, saturation: ParameterID, label: String, stepName: String, diameter: CGFloat) {
        hueParameter = hue
        saturationParameter = saturation
        self.label = label
        self.stepName = stepName
        self.diameter = diameter
    }

    var body: some View {
        let hue = model.sliderValue(hueParameter)
        let saturation = model.sliderValue(saturationParameter)
        let radius = diameter / 2
        let angle = hue * .pi / 180
        let distance = saturation / 100 * radius
        let puck = CGPoint(x: radius + cos(angle) * distance, y: radius - sin(angle) * distance)

        ZStack {
            Circle()
                .fill(AngularGradient(
                    gradient: Gradient(colors: stride(from: 360.0, through: 0, by: -30).map { .wheelHue(
                        $0,
                        saturation: 0.75,
                        brightness: 0.85,
                    ) }),
                    center: .center,
                ))
            Circle()
                .fill(RadialGradient(
                    gradient: Gradient(colors: [Color(white: 0.5), Color(white: 0.5).opacity(0)]),
                    center: .center, startRadius: 0, endRadius: radius,
                ))
            Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
            Path { path in
                path.move(to: CGPoint(x: radius - 4, y: radius))
                path.addLine(to: CGPoint(x: radius + 4, y: radius))
                path.move(to: CGPoint(x: radius, y: radius - 4))
                path.addLine(to: CGPoint(x: radius, y: radius + 4))
            }
            .stroke(Color.black.opacity(0.4), lineWidth: 1)
            Circle()
                .fill(Color.wheelHue(hue, saturation: saturation / 100, brightness: 0.95))
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.5), radius: 2)
                .frame(width: 12, height: 12)
                .position(puck)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if !dragging {
                        dragging = true
                        model.beginEdit()
                    }
                    let dx = gesture.location.x - radius
                    let dy = radius - gesture.location.y
                    var degrees = atan2(dy, dx) * 180 / .pi
                    if degrees < 0 {
                        degrees += 360
                    }
                    let amount = min(hypot(dx, dy) / radius, 1) * 100
                    model.setSliderValue(hueParameter, degrees)
                    model.setSliderValue(saturationParameter, amount)
                }
                .onEnded { _ in
                    dragging = false
                    model.endEdit(hueParameter.isMaskScoped ? .mask(nil) : .adjustment(hueParameter), stepName)
                },
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if hueParameter.isMaskScoped {
                model.beginEdit()
                model.resetSlider(hueParameter)
                model.resetSlider(saturationParameter)
                model.endEdit(.mask(nil), "Reset \(stepName)")
            } else {
                model.resetParameters([hueParameter, saturationParameter], name: "Reset \(stepName)")
            }
        })
        .help("\(label): hue \(Int(hue))°, saturation \(Int(saturation)). Double-click to reset.")
    }
}

/// The luminance slider under each 3-way wheel.
struct CompactLuminanceSlider: View {
    let parameter: ParameterID
    @Environment(EditorModel.self) private var model

    var body: some View {
        SliderTrack(
            spec: parameter.spec,
            value: model.value(parameter),
            onBegin: { model.beginEdit(parameter) },
            onChange: { model.setValue(parameter, $0) },
            onEnd: { model.endEdit() },
            onReset: { model.reset(parameter) },
        )
        .help("Luminance \(parameter.spec.formatted(model.value(parameter)))")
    }
}
