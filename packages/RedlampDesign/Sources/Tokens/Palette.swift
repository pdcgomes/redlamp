import AppKit
import SwiftUI
import Synchronization

/// Redlamp's colors. Editing surfaces stay neutral grey so nothing tints the user's
/// judgment of color; the brand red never appears here.
///
/// The values come from `Palette.current`, which the default `standard` set fills with
/// those greys. Themes swap in another set; views that already drew keep the old colors
/// until they redraw.
public enum Palette {
    private static let store = Mutex(PaletteTokens.standard)

    public static var current: PaletteTokens {
        get { store.withLock { $0 } }
        set { store.withLock { $0 = newValue } }
    }

    public static var label: RGBA {
        current.label
    }

    public static var labelHover: RGBA {
        current.labelHover
    }

    public static var secondaryLabel: RGBA {
        current.secondaryLabel
    }

    public static var tertiaryLabel: RGBA {
        current.tertiaryLabel
    }

    public static var value: RGBA {
        current.value
    }

    public static var divider: RGBA {
        current.divider
    }

    public static var track: RGBA {
        current.track
    }

    public static var well: RGBA {
        current.well
    }

    public static var selection: RGBA {
        current.selection
    }

    public static var panelBackground: RGBA {
        current.panelBackground
    }

    /// The filled part of a plain slider track, from the origin to the thumb.
    public static var trackFill: RGBA {
        current.trackFill
    }

    public static var thumb: RGBA {
        current.thumb
    }

    public static var thumbStroke: RGBA {
        current.thumbStroke
    }

    public static var thumbShadow: RGBA {
        current.thumbShadow
    }

    /// The dot on a panel header whose panel has edits.
    public static var editedDot: RGBA {
        current.editedDot
    }

    /// The dot on a Develop panel's header whose panel has edits: a tint of the theme's accent.
    public static var panelEditedDot: NSColor {
        accent.withAlphaComponent(0.8)
    }

    /// A Develop panel's card, a step above the panel background (`PanelSectionView.Style.card`).
    public static var card: RGBA {
        current.card
    }

    /// A card's header under the pointer.
    public static var cardHover: RGBA {
        current.cardHover
    }

    /// Focus, selection and "Reset" affordances. The system accent, as SwiftUI's
    /// `Color.accentColor` resolves it, unless the theme sets its own.
    public static var accent: NSColor {
        current.accent?.nsColor ?? .controlAccentColor
    }

    public static func notice(_ tone: NoticeTone) -> NoticeColors {
        current.notice(tone)
    }
}

/// One complete set of the colors `Palette` hands out.
public struct PaletteTokens: Sendable, Hashable {
    public var label: RGBA
    public var labelHover: RGBA
    public var secondaryLabel: RGBA
    public var tertiaryLabel: RGBA
    public var value: RGBA
    public var divider: RGBA
    public var track: RGBA
    public var well: RGBA
    public var selection: RGBA
    public var panelBackground: RGBA
    public var trackFill: RGBA
    public var thumb: RGBA
    public var thumbStroke: RGBA
    public var thumbShadow: RGBA
    public var editedDot: RGBA
    /// `nil` follows the system accent.
    public var accent: RGBA?
    /// The tint for native macOS controls (checkboxes, segmented pickers, prominent
    /// buttons). `nil` leaves them on the system accent the user chose.
    public var nativeTint: RGBA?
    /// Notices: a download's terms, a warning (`NoticeTone`).
    public var caution: NoticeColors
    public var info: NoticeColors

    public init(
        label: RGBA, labelHover: RGBA, secondaryLabel: RGBA, tertiaryLabel: RGBA, value: RGBA,
        divider: RGBA, track: RGBA, well: RGBA, selection: RGBA, panelBackground: RGBA,
        trackFill: RGBA, thumb: RGBA, thumbStroke: RGBA, thumbShadow: RGBA, editedDot: RGBA,
        accent: RGBA?, nativeTint: RGBA? = nil, caution: NoticeColors, info: NoticeColors,
    ) {
        self.label = label
        self.labelHover = labelHover
        self.secondaryLabel = secondaryLabel
        self.tertiaryLabel = tertiaryLabel
        self.value = value
        self.divider = divider
        self.track = track
        self.well = well
        self.selection = selection
        self.panelBackground = panelBackground
        self.trackFill = trackFill
        self.thumb = thumb
        self.thumbStroke = thumbStroke
        self.thumbShadow = thumbShadow
        self.editedDot = editedDot
        self.accent = accent
        self.nativeTint = nativeTint
        self.caution = caution
        self.info = info
    }

    /// Whether the panels are dark: their background's luminance is below half.
    public var isDark: Bool {
        0.2126 * panelBackground.red + 0.7152 * panelBackground.green + 0.0722 * panelBackground.blue < 0.5
    }

    /// A step above the panel background: lighter on dark, whiter on light.
    public var card: RGBA {
        isDark ? RGBA(red: value.red, green: value.green, blue: value.blue, alpha: 0.05) : RGBA(white: 1, alpha: 0.55)
    }

    public var cardHover: RGBA {
        RGBA(red: value.red, green: value.green, blue: value.blue, alpha: isDark ? 0.035 : 0.03)
    }

    public func notice(_ tone: NoticeTone) -> NoticeColors {
        switch tone {
        case .caution: caution
        case .info: info
        }
    }

    /// Redlamp's neutral greys on dark, the colors the editor ships with.
    public static let standard = PaletteTokens(
        label: RGBA(white: 1, alpha: 0.72),
        labelHover: RGBA(white: 1, alpha: 0.95),
        secondaryLabel: RGBA(white: 1, alpha: 0.45),
        tertiaryLabel: RGBA(white: 1, alpha: 0.28),
        value: RGBA(white: 1, alpha: 0.9),
        divider: RGBA(white: 1, alpha: 0.07),
        track: RGBA(white: 1, alpha: 0.16),
        well: RGBA(white: 0, alpha: 0.28),
        selection: RGBA(white: 1, alpha: 0.1),
        panelBackground: RGBA(white: 0.115),
        trackFill: RGBA(white: 1, alpha: 0.55),
        thumb: RGBA(white: 0.92),
        thumbStroke: RGBA(white: 0, alpha: 0.35),
        thumbShadow: RGBA(white: 0, alpha: 0.4),
        editedDot: RGBA(white: 1, alpha: 0.55),
        accent: nil,
        caution: .caution(dark: true),
        info: .info(foreground: RGBA(white: 1), dark: true),
    )

    /// The same neutral greys on light.
    public static let standardLight = PaletteTokens(
        label: RGBA(white: 0, alpha: 0.75),
        labelHover: RGBA(white: 0, alpha: 0.95),
        secondaryLabel: RGBA(white: 0, alpha: 0.5),
        tertiaryLabel: RGBA(white: 0, alpha: 0.3),
        value: RGBA(white: 0, alpha: 0.88),
        divider: RGBA(white: 0, alpha: 0.09),
        track: RGBA(white: 0, alpha: 0.14),
        well: RGBA(white: 0, alpha: 0.06),
        selection: RGBA(white: 0, alpha: 0.08),
        panelBackground: RGBA(white: 0.925),
        trackFill: RGBA(white: 0, alpha: 0.5),
        thumb: RGBA(white: 1),
        thumbStroke: RGBA(white: 0, alpha: 0.25),
        thumbShadow: RGBA(white: 0, alpha: 0.2),
        editedDot: RGBA(white: 0, alpha: 0.5),
        accent: nil,
        caution: .caution(dark: false),
        info: .info(foreground: RGBA(white: 0), dark: false),
    )
}
