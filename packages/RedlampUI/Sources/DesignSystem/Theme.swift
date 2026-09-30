import RedlampDesign
import RedlampEngineAPI
import SwiftUI

/// The design tokens as SwiftUI values. The tokens themselves live in `RedlampDesign`,
/// shared with the AppKit panels, so both render identically.
enum Theme {
    static let label = Palette.label.color
    static let labelHover = Palette.labelHover.color
    static let secondaryLabel = Palette.secondaryLabel.color
    static let tertiaryLabel = Palette.tertiaryLabel.color
    static let value = Palette.value.color
    static let divider = Palette.divider.color
    static let track = Palette.track.color
    static let well = Palette.well.color
    static let selection = Palette.selection.color

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
