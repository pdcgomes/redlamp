import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// A group of Point Color's sliders under its header, as both Color Mixer panels show them.
struct PointColorGroup: Identifiable {
    let title: String
    let parameters: [ParameterID]

    var id: String {
        title
    }

    static let all = [
        PointColorGroup(
            title: "Shift",
            parameters: [.pointColorHueShift, .pointColorSaturationShift, .pointColorLuminanceShift],
        ),
        PointColorGroup(
            title: "Uniformity",
            parameters: [.pointColorHueUniformity, .pointColorSaturationUniformity, .pointColorLuminanceUniformity],
        ),
        PointColorGroup(
            title: "Range",
            parameters: [
                .pointColorHueRange, .pointColorSaturationRange, .pointColorLuminanceRange, .pointColorSmoothness,
            ],
        ),
    ]

    /// A slider's label under its group's header: "Hue" under Shift.
    static func label(_ parameter: ParameterID) -> String {
        switch parameter {
        case .pointColorHueShift, .pointColorHueUniformity, .pointColorHueRange: "Hue"
        case .pointColorSaturationShift, .pointColorSaturationUniformity, .pointColorSaturationRange: "Saturation"
        case .pointColorLuminanceShift, .pointColorLuminanceUniformity, .pointColorLuminanceRange: "Luminance"
        default: parameter.spec.label
        }
    }
}

/// Point Color's eyedropper, its swatches (up to eight, the selected one ringed) and the button
/// that deletes the selected one.
struct PointColorSwatches: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        let selected = model.selectedPointColorSwatch?.id
        let full = model.recipe.pointColor.count >= PointColorSwatch.maximumSwatches
        HStack(spacing: 4) {
            Button {
                model.pointColorEyedropperActive.toggle()
            } label: {
                Image(systemName: "eyedropper")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 20)
                    .foregroundStyle(model.pointColorEyedropperActive ? Theme.accent : Theme.label)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(model.pointColorEyedropperActive ? Theme.selection : .clear))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pointColor.eyedropper")
            .help(full
                ? "Point Color Selector: click the photo to pick the selected swatch's colour again"
                : "Point Color Selector: click a colour on the photo to add a swatch")

            ForEach(model.recipe.pointColor) { swatch in
                Button {
                    model.selectedPointColorSwatchID = swatch.id
                } label: {
                    Circle()
                        .fill(swatch.displayColor)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white, lineWidth: swatch.id == selected ? 2 : 0)
                                .padding(-3),
                        )
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("A Point Color swatch: click to edit it")
            }

            Spacer(minLength: 0)

            Button {
                if let selected {
                    model.deletePointColorSwatch(selected)
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .frame(width: 22, height: 20)
                    .foregroundStyle(Theme.label)
            }
            .buttonStyle(.plain)
            .disabled(selected == nil)
            .accessibilityIdentifier("pointColor.delete")
            .help("Delete the selected swatch")
        }
        .frame(minHeight: 26)
    }
}

/// Visualize Range: what the selected swatch selects shows in colour, and the rest in grey.
struct PointColorVisualizeToggle: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Toggle("Visualize Range", isOn: $model.visualizePointColorRange)
            .toggleStyle(.checkbox)
            .font(Theme.labelFont)
            .disabled(model.selectedPointColorSwatch == nil)
            .help("Show what the selected swatch selects in colour, and the rest of the photo in grey")
    }
}

extension PointColorSwatch {
    /// The swatch's colour on screen; a mask's own colour shows as grey until it's measured.
    var displayColor: SwiftUI.Color {
        if case let .oklch(value) = color {
            return value.displayColor
        }
        return .gray
    }
}

extension OKLCh {
    /// The colour on screen, clipped to sRGB, by Björn Ottosson's inverse of OKLab.
    var displayColor: Color {
        let radians = hue * .pi / 180
        let a = chroma * cos(radians)
        let b = chroma * sin(radians)
        let cube = { (value: Double) in value * value * value }
        let l = cube(lightness + 0.3963377774 * a + 0.2158037573 * b)
        let m = cube(lightness - 0.1055613458 * a - 0.0638541728 * b)
        let s = cube(lightness - 0.0894841775 * a - 1.2914855480 * b)
        let clip = { (value: Double) in min(max(value, 0), 1) }
        return Color(
            .sRGBLinear,
            red: clip(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            green: clip(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            blue: clip(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
        )
    }
}
