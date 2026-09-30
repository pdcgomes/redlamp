import AppKit
import RedlampEngineAPI
import SwiftUI

public extension ColorBand {
    /// HSV hues for drawing the color bands (the engine works in OKLCh; these are the
    /// on-screen equivalents).
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

    var displayColor: RGBA {
        RGBA(hue: displayHue, saturation: 0.85, brightness: 0.9)
    }
}

public extension RGBA {
    static func wheelHue(_ degrees: Double, saturation: Double = 0.85, brightness: Double = 0.95) -> RGBA {
        RGBA(hue: degrees, saturation: saturation, brightness: brightness)
    }
}

public extension TrackStyle {
    /// The colors painted along the slider track, evenly spaced, or `nil` for a plain grey
    /// track.
    var gradientStops: [RGBA]? {
        switch self {
        case .plain:
            nil
        case .monochrome:
            [RGBA(white: 0.12), RGBA(white: 0.85)]
        case .temperature:
            [RGBA(red: 0.25, green: 0.45, blue: 0.95), RGBA(white: 0.85), RGBA(red: 0.95, green: 0.8, blue: 0.2)]
        case .tint:
            [RGBA(red: 0.25, green: 0.8, blue: 0.3), RGBA(white: 0.85), RGBA(red: 0.85, green: 0.3, blue: 0.85)]
        case let .hue(band):
            [.wheelHue(band.displayHue - 35), .wheelHue(band.displayHue), .wheelHue(band.displayHue + 35)]
        case let .saturation(band):
            [RGBA(white: 0.55), .wheelHue(band.displayHue, saturation: 1, brightness: 0.95)]
        case let .luminance(band):
            [
                .wheelHue(band.displayHue, saturation: 0.9, brightness: 0.25),
                .wheelHue(band.displayHue, saturation: 0.35, brightness: 1),
            ]
        case .gradingHue:
            stride(from: 0.0, through: 360, by: 30).map { .wheelHue($0) }
        }
    }

    var gradient: Gradient? {
        gradientStops.map { Gradient(colors: $0.map(\.color)) }
    }

    /// The track gradient for CoreGraphics, interpolated in `space`. SwiftUI interpolates a
    /// `LinearGradient` in the display's color space, so pass the window's.
    func cgGradient(in space: CGColorSpace) -> CGGradient? {
        guard let stops = gradientStops else { return nil }
        let locations = stops.indices.map { CGFloat($0) / CGFloat(max(stops.count - 1, 1)) }
        let colors = stops.compactMap { $0.cgColor.converted(to: space, intent: .defaultIntent, options: nil) }
        return CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
    }
}
