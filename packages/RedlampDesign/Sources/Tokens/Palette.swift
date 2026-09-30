import AppKit
import SwiftUI

/// Redlamp's colors. Editing surfaces stay neutral grey so nothing tints the user's
/// judgment of color; the brand red never appears here.
public enum Palette {
    public static let label = RGBA(white: 1, alpha: 0.72)
    public static let labelHover = RGBA(white: 1, alpha: 0.95)
    public static let secondaryLabel = RGBA(white: 1, alpha: 0.45)
    public static let tertiaryLabel = RGBA(white: 1, alpha: 0.28)
    public static let value = RGBA(white: 1, alpha: 0.9)
    public static let divider = RGBA(white: 1, alpha: 0.07)
    public static let track = RGBA(white: 1, alpha: 0.16)
    public static let well = RGBA(white: 0, alpha: 0.28)
    public static let selection = RGBA(white: 1, alpha: 0.1)
    public static let panelBackground = RGBA(white: 0.115)

    /// The filled part of a plain slider track, from the origin to the thumb.
    public static let trackFill = RGBA(white: 1, alpha: 0.55)
    public static let thumb = RGBA(white: 0.92)
    public static let thumbStroke = RGBA(white: 0, alpha: 0.35)
    public static let thumbShadow = RGBA(white: 0, alpha: 0.4)
    /// The dot on a panel header whose panel has edits.
    public static let editedDot = RGBA(white: 1, alpha: 0.55)

    /// The system accent (focus, selection, "Reset" affordances), as SwiftUI's
    /// `Color.accentColor` resolves it.
    public static var accent: NSColor {
        .controlAccentColor
    }
}
