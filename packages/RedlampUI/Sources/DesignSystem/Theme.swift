import RedlampEngineAPI
import SwiftUI

/// Redlamp's design tokens. Editing surfaces stay neutral grey so nothing tints the
/// user's judgment of color; the brand red never appears here.
enum Theme {
    static let label = Color.white.opacity(0.72)
    static let labelHover = Color.white.opacity(0.95)
    static let secondaryLabel = Color.white.opacity(0.45)
    static let tertiaryLabel = Color.white.opacity(0.28)
    static let value = Color.white.opacity(0.9)
    static let divider = Color.white.opacity(0.07)
    static let track = Color.white.opacity(0.16)
    static let well = Color.black.opacity(0.28)
    static let selection = Color.white.opacity(0.1)

    static let labelFont = Font.system(size: 11)
    static let valueFont = Font.system(size: 11).monospacedDigit()
    static let panelTitleFont = Font.system(size: 11.5, weight: .semibold)
    static let sectionFont = Font.system(size: 10, weight: .semibold)
    static let captionFont = Font.system(size: 10)

    static let labelWidth: CGFloat = 76
    static let valueWidth: CGFloat = 44
    static let rowHeight: CGFloat = 20
    static let panelPadding: CGFloat = 14
    static let thumbSize: CGFloat = 11
}

/// HSV hues for drawing the color bands (the engine works in OKLCh; these are the
/// on-screen equivalents).
extension ColorBand {
    var displayHue: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 55
        case .green: 115
        case .aqua: 180
        case .blue: 220
        case .purple: 275
        case .magenta: 315
        }
    }

    var color: Color {
        Color(hue: displayHue / 360, saturation: 0.85, brightness: 0.9)
    }
}

extension View {
    /// Wraps the view in a container, so overlays attach to the container rather than
    /// to a hosted AppKit view (such as the Metal canvas), which would draw over them.
    func containerized() -> some View {
        ZStack { self }
    }
}

extension Color {
    static func wheelHue(_ degrees: Double, saturation: Double = 0.85, brightness: Double = 0.95) -> Color {
        let wrapped = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return Color(hue: wrapped / 360, saturation: saturation, brightness: brightness)
    }
}

extension TrackStyle {
    /// The gradient painted under the slider, or `nil` for a plain grey track.
    var gradient: Gradient? {
        switch self {
        case .plain:
            nil
        case .monochrome:
            Gradient(colors: [Color(white: 0.12), Color(white: 0.85)])
        case .temperature:
            Gradient(colors: [
                Color(red: 0.25, green: 0.45, blue: 0.95),
                Color(white: 0.85),
                Color(red: 0.95, green: 0.8, blue: 0.2),
            ])
        case .tint:
            Gradient(colors: [
                Color(red: 0.25, green: 0.8, blue: 0.3),
                Color(white: 0.85),
                Color(red: 0.85, green: 0.3, blue: 0.85),
            ])
        case let .hue(band):
            Gradient(colors: [
                .wheelHue(band.displayHue - 35),
                .wheelHue(band.displayHue),
                .wheelHue(band.displayHue + 35),
            ])
        case let .saturation(band):
            Gradient(colors: [
                Color(white: 0.55),
                .wheelHue(band.displayHue, saturation: 1, brightness: 0.95),
            ])
        case let .luminance(band):
            Gradient(colors: [
                .wheelHue(band.displayHue, saturation: 0.9, brightness: 0.25),
                .wheelHue(band.displayHue, saturation: 0.35, brightness: 1),
            ])
        case .gradingHue:
            Gradient(colors: stride(from: 0.0, through: 360, by: 30).map { .wheelHue($0) })
        }
    }
}
