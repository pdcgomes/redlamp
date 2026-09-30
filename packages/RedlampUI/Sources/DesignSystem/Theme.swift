import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The design tokens as SwiftUI values. The tokens themselves live in `RedlampDesign`,
/// shared with the AppKit panels, so both render identically. The colors are read on
/// every use, so they follow `Palette.current`.
enum Theme {
    static var label: Color {
        Palette.label.color
    }

    static var labelHover: Color {
        Palette.labelHover.color
    }

    static var secondaryLabel: Color {
        Palette.secondaryLabel.color
    }

    static var tertiaryLabel: Color {
        Palette.tertiaryLabel.color
    }

    static var value: Color {
        Palette.value.color
    }

    static var divider: Color {
        Palette.divider.color
    }

    static var track: Color {
        Palette.track.color
    }

    static var well: Color {
        Palette.well.color
    }

    static var selection: Color {
        Palette.selection.color
    }

    static var panelBackground: Color {
        Palette.panelBackground.color
    }

    static var trackFill: Color {
        Palette.trackFill.color
    }

    static var thumb: Color {
        Palette.thumb.color
    }

    static var thumbStroke: Color {
        Palette.thumbStroke.color
    }

    static var thumbShadow: Color {
        Palette.thumbShadow.color
    }

    static var editedDot: Color {
        Palette.editedDot.color
    }

    static var accent: Color {
        Palette.current.accent?.color ?? .accentColor
    }

    /// For `.tint(_:)` on native controls; `nil` keeps the system accent.
    static var nativeTint: Color? {
        Palette.current.nativeTint?.color
    }

    static let labelFont = Typography.label.font
    static let valueFont = Typography.value.font
    static let panelTitleFont = Typography.panelTitle.font
    static let sectionFont = Typography.section.font
    static let captionFont = Typography.caption.font

    static let labelWidth = Metrics.labelWidth
    static let valueWidth = Metrics.valueWidth
    static let rowHeight = Metrics.rowHeight
    static let panelPadding = Metrics.panelPadding
    static let thumbSize = Metrics.thumbSize
}

extension ColorBand {
    var color: Color {
        displayColor.color
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
        RGBA.wheelHue(degrees, saturation: saturation, brightness: brightness).color
    }
}
