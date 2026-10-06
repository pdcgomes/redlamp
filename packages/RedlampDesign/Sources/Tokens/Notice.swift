/// How much a notice asks of the person reading it.
public enum NoticeTone: String, Sendable, Hashable, CaseIterable {
    /// To weigh before going on: a download's size and terms, what a model makes.
    case caution
    /// To know: what a choice does, or why something isn't offered.
    case info

    /// The glyph a notice in this tone shows unless it brings its own.
    public var symbol: String {
        switch self {
        case .caution: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }
}

/// A notice's colors: the card it sits on, the card's edge, and its glyph. Besides the accent,
/// a notice is the only color on the editing surface, so its card stays faint.
public struct NoticeColors: Sendable, Hashable {
    public var fill: RGBA
    public var border: RGBA
    public var glyph: RGBA

    public init(fill: RGBA, border: RGBA, glyph: RGBA) {
        self.fill = fill
        self.border = border
        self.glyph = glyph
    }

    /// Amber, whatever the theme: caution shouldn't take a theme's hue.
    public static func caution(dark: Bool) -> NoticeColors {
        dark
            ? NoticeColors(
                fill: RGBA(red: 1, green: 0.74, blue: 0.3, alpha: 0.1),
                border: RGBA(red: 1, green: 0.74, blue: 0.3, alpha: 0.3),
                glyph: RGBA(red: 1, green: 0.78, blue: 0.38),
            )
            : NoticeColors(
                fill: RGBA(red: 0.96, green: 0.64, blue: 0.12, alpha: 0.14),
                border: RGBA(red: 0.86, green: 0.55, blue: 0.05, alpha: 0.45),
                glyph: RGBA(red: 0.74, green: 0.45, blue: 0),
            )
    }

    /// The theme's own foreground, faintly.
    public static func info(foreground: RGBA, dark: Bool) -> NoticeColors {
        NoticeColors(
            fill: foreground.opacity(dark ? 0.05 : 0.04),
            border: foreground.opacity(dark ? 0.14 : 0.16),
            glyph: foreground.opacity(0.6),
        )
    }
}
