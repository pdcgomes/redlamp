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

    static var well: Color {
        Palette.well.color
    }

    static var selection: Color {
        Palette.selection.color
    }

    static var editedDot: Color {
        Palette.editedDot.color
    }

    static var track: Color {
        Palette.track.color
    }

    static var trackFill: Color {
        Palette.trackFill.color
    }

    static var panelEditedDot: Color {
        Color(nsColor: Palette.panelEditedDot)
    }

    static var card: Color {
        Palette.card.color
    }

    static var cardHover: Color {
        Palette.cardHover.color
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
    static let panelSymbolSlot = Metrics.panelSymbolSlot
    static let panelEyeTarget = Metrics.panelEyeTarget
    static let panelEyePointSize = Metrics.panelEyePointSize
    static let editedDotSize = Metrics.editedDotSize
    static let panelCardMargin = Metrics.panelCardMargin
    static let panelCardGap = Metrics.panelCardGap
    static let panelCardRadius = Metrics.panelCardRadius
    static let panelCardPadding = Metrics.panelCardPadding
    static let switchedOffOpacity = Metrics.switchedOffOpacity
    static let thumbSize = Metrics.thumbSize
}

/// The theme's colors from a given set of tokens: `Palette.current`, unless a subtree has
/// its own (`\.themeTokens`, the command palette's theme).
struct ThemeColors {
    let tokens: PaletteTokens

    init(_ override: PaletteTokens?) {
        tokens = override ?? Palette.current
    }

    var label: Color {
        tokens.label.color
    }

    var secondaryLabel: Color {
        tokens.secondaryLabel.color
    }

    var tertiaryLabel: Color {
        tokens.tertiaryLabel.color
    }

    var value: Color {
        tokens.value.color
    }

    var divider: Color {
        tokens.divider.color
    }

    var track: Color {
        tokens.track.color
    }

    var trackFill: Color {
        tokens.trackFill.color
    }

    var selection: Color {
        tokens.selection.color
    }

    var panelBackground: Color {
        tokens.panelBackground.color
    }

    var thumb: Color {
        tokens.thumb.color
    }

    var thumbStroke: Color {
        tokens.thumbStroke.color
    }

    var thumbShadow: Color {
        tokens.thumbShadow.color
    }

    var editedDot: Color {
        tokens.editedDot.color
    }

    var accent: Color {
        tokens.accent?.color ?? .accentColor
    }
}

extension EnvironmentValues {
    /// Tokens a subtree draws in instead of the app's theme; `nil` follows it.
    @Entry var themeTokens: PaletteTokens?
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
