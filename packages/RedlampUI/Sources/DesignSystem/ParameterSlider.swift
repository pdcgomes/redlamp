import AppKit
import RedlampEngineAPI
import SwiftUI

/// A Lightroom-style parameter row: label, precision slider, editable value.
///
/// - Drag the thumb for relative changes, or click the track to jump.
/// - Shift-drag for fine control.
/// - Double-click the label or thumb to reset.
/// - Option-drag on tone sliders previews clipping.
/// - Click the value to type; arrow keys step (Shift for ×10).
@_spi(Harness) public struct ParameterSlider: View {
    let parameter: ParameterID
    var label: String?
    var enabled = true

    @Environment(EditorModel.self) private var model
    @State private var isHovering = false

    public init(parameter: ParameterID, label: String? = nil, enabled: Bool = true) {
        self.parameter = parameter
        self.label = label
        self.enabled = enabled
    }

    private static let clippingParameters: Set<ParameterID> = [
        .exposure, .highlights, .shadows, .whites, .blacks,
        .localExposure, .localHighlights, .localShadows, .localWhites, .localBlacks,
    ]

    public var body: some View {
        let spec = parameter.spec
        let live = spec.availability.isLive && enabled
        let focused = model.focusedParameter == parameter
        HStack(spacing: 6) {
            Text(label ?? spec.label)
                .font(focused ? Theme.labelFont.weight(.semibold) : Theme.labelFont)
                .foregroundStyle(focused ? Theme.accent : (isHovering && live ? Theme.labelHover : Theme.label))
                .lineLimit(1)
                .frame(width: Theme.labelWidth, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.resetSlider(parameter) }
                .onTapGesture { model.focusedParameter = parameter }

            SliderTrack(
                spec: spec,
                value: model.sliderValue(parameter),
                onBegin: {
                    model.focusedParameter = parameter
                    model.beginEdit(parameter)
                    if Self.clippingParameters.contains(parameter), NSEvent.modifierFlags.contains(.option) {
                        model.setTemporaryClipping(true)
                    }
                },
                onChange: { model.setSliderValue(parameter, $0) },
                onEnd: {
                    model.setTemporaryClipping(false)
                    model.endEdit()
                },
                onReset: { model.resetSlider(parameter) },
            )

            ValueField(spec: spec, value: model.sliderValue(parameter)) { model.setSliderValue(parameter, $0) }
                .frame(width: Theme.valueWidth)
        }
        .frame(height: Theme.rowHeight)
        .background(alignment: .leading) {
            if focused {
                // Lightroom-style marker for the slider `,` `.` select and `-` `=` nudge.
                Capsule().fill(Theme.accent).frame(width: 2, height: 12).offset(x: -8)
            }
        }
        .opacity(live ? 1 : 0.35)
        .disabled(!live)
        .onHover { isHovering = $0 }
        .help(helpText(spec))
    }

    private func helpText(_ spec: ParameterSpec) -> String {
        if case let .planned(phase) = spec.availability {
            return "\(spec.label) is laid out for reference and renders in \(phase)."
        }
        return "Double-click to reset. Shift-drag for fine control."
    }
}

struct SliderTrack: View {
    let spec: ParameterSpec
    let value: Double
    var onBegin: () -> Void = {}
    var onChange: (Double) -> Void
    var onEnd: () -> Void = {}
    var onReset: () -> Void = {}

    @State private var dragStartPosition: Double?

    var body: some View {
        GeometryReader { geometry in
            let inset = Theme.thumbSize / 2
            let usable = max(geometry.size.width - Theme.thumbSize, 1)
            let position = spec.position(for: value)
            let thumbX = inset + position * usable
            let midY = geometry.size.height / 2
            let originPosition = spec.isBipolar ? spec.position(for: 0) : 0
            let originX = inset + originPosition * usable

            ZStack {
                trackShape
                    .frame(width: usable, height: spec.track.gradient == nil ? 2 : 3)
                    .position(x: geometry.size.width / 2, y: midY)

                if spec.track.gradient == nil {
                    Capsule()
                        .fill(Theme.trackFill)
                        .frame(width: abs(thumbX - originX), height: 2)
                        .position(x: (thumbX + originX) / 2, y: midY)
                }

                if spec.isBipolar {
                    Rectangle()
                        .fill(Theme.secondaryLabel)
                        .frame(width: 1, height: 7)
                        .position(x: originX, y: midY)
                }

                Circle()
                    .fill(Theme.thumb)
                    .overlay(Circle().strokeBorder(Theme.thumbStroke, lineWidth: 0.5))
                    .shadow(color: Theme.thumbShadow, radius: 1.5, y: 0.5)
                    .frame(width: Theme.thumbSize, height: Theme.thumbSize)
                    .position(x: thumbX, y: midY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragStartPosition == nil {
                            onBegin()
                            if abs(gesture.startLocation.x - thumbX) <= Theme.thumbSize {
                                dragStartPosition = position
                            } else {
                                let jumped = (gesture.startLocation.x - inset) / usable
                                dragStartPosition = jumped
                                onChange(spec.value(atPosition: jumped))
                            }
                        }
                        let fine = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1.0
                        let delta = (gesture.location.x - gesture.startLocation.x) / usable * fine
                        onChange(spec.value(atPosition: (dragStartPosition ?? position) + delta))
                    }
                    .onEnded { _ in
                        dragStartPosition = nil
                        onEnd()
                    },
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { onReset() })
        }
        .frame(height: 16)
    }

    @ViewBuilder
    private var trackShape: some View {
        if let gradient = spec.track.gradient {
            Capsule().fill(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
                .opacity(0.9)
        } else {
            Capsule().fill(Theme.track)
        }
    }
}

/// The numeric readout; click to type a value.
struct ValueField: View {
    let spec: ParameterSpec
    let value: Double
    let onCommit: (Double) -> Void

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.valueFont)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { editing = false }
                .onKeyPress(.upArrow) { stepValue(1); return .handled }
                .onKeyPress(.downArrow) { stepValue(-1); return .handled }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused {
                        commit()
                    }
                }
                .onAppear { focused = true }
        } else {
            Text(spec.formatted(value))
                .font(Theme.valueFont)
                .foregroundStyle(Theme.value)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture {
                    text = spec.formatted(value)
                    editing = true
                }
        }
    }

    private func commit() {
        if let parsed = spec.parse(text, current: value) {
            onCommit(parsed)
        }
        editing = false
    }

    private func stepValue(_ direction: Double) {
        let multiplier = NSEvent.modifierFlags.contains(.shift) ? 10.0 : 1.0
        let next = spec.clamp((spec.parse(text) ?? value) + direction * spec.step * multiplier)
        onCommit(next)
        text = spec.formatted(next)
    }
}

/// A small caps subsection title ("TONE", "PRESENCE") that resets its group on double-click.
@_spi(Harness) public struct SubsectionHeader<Accessory: View>: View {
    let title: String
    let parameters: [ParameterID]
    @ViewBuilder var accessory: Accessory

    public init(title: String, parameters: [ParameterID], @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.parameters = parameters
        self.accessory = accessory()
    }

    @Environment(EditorModel.self) private var model

    public var body: some View {
        // Holding Option turns the title into a one-click "Reset …", as in Lightroom.
        let resetMode = model.optionKeyHeld && !parameters.isEmpty
        HStack {
            Text(resetMode ? "RESET \(title.uppercased())" : title.uppercased())
                .font(Theme.sectionFont)
                .tracking(0.6)
                .foregroundStyle(resetMode ? Theme.accent : Theme.secondaryLabel)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.resetParameters(parameters, name: "Reset \(title)") }
                .onTapGesture {
                    if resetMode {
                        model.resetParameters(parameters, name: "Reset \(title)")
                    }
                }
                .help("Double-click, or Option-click, to reset \(title)")
            Spacer()
            accessory
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

@_spi(Harness) public extension SubsectionHeader where Accessory == EmptyView {
    init(title: String, parameters: [ParameterID]) {
        self.init(title: title, parameters: parameters) { EmptyView() }
    }
}

/// A compact label + control row (Treatment, Profile, WB).
@_spi(Harness) public struct ControlRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    public init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Theme.labelFont)
                .foregroundStyle(Theme.label)
                .frame(width: Theme.labelWidth, alignment: .leading)
            content
        }
        .frame(minHeight: 24)
    }
}
