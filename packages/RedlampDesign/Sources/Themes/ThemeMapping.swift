/// A theme choice: which family, which appearance, and how much of its hue to keep.
public struct ThemeSelection: Sendable, Hashable {
    public var familyID: String
    public var appearance: ThemeAppearance
    /// 0 renders the theme's tones in neutral grey, 1 in its full colors.
    public var tint: Double
    /// Whether native macOS controls take the theme's accent instead of the system one.
    public var tintsNativeControls: Bool

    public init(
        familyID: String = ThemeCatalog.defaultID, appearance: ThemeAppearance = .dark, tint: Double = 1,
        tintsNativeControls: Bool = false,
    ) {
        self.familyID = familyID
        self.appearance = appearance
        self.tint = tint
        self.tintsNativeControls = tintsNativeControls
    }

    public var tokens: PaletteTokens {
        var tokens = ThemeMapping.tokens(for: ThemeCatalog.family(id: familyID), appearance: appearance, tint: tint)
        tokens.nativeTint = tintsNativeControls ? tokens.accent : nil
        return tokens
    }
}

/// Turns a theme's ten palette colors into `Palette`'s tokens. The alphas are the
/// standard tokens' own, so a theme changes hue and tone but not the hierarchy between
/// labels, values and tracks.
public enum ThemeMapping {
    public static func tokens(for family: ThemeFamily, appearance: ThemeAppearance, tint: Double) -> PaletteTokens {
        switch family.source(for: appearance) {
        case let .tokens(tokens): tokens
        case let .palette(palette): tokens(for: palette, appearance: appearance, tint: tint)
        }
    }

    public static func tokens(for source: ThemePalette, appearance: ThemeAppearance, tint: Double) -> PaletteTokens {
        let palette = tinted(source, by: tint)
        let isDark = appearance == .dark
        let foreground = palette.foreground
        let roles = palette.primaryRoles
        func primary(for role: PrimaryRoles) -> RGBA {
            roles.contains(role) ? palette.primary : palette.neutral
        }

        // Dark foregrounds need more opacity than light ones to hold the same contrast.
        return PaletteTokens(
            label: foreground.opacity(isDark ? 0.72 : 0.84),
            labelHover: foreground.opacity(0.95),
            secondaryLabel: palette.muted,
            tertiaryLabel: palette.muted.opacity(0.28 / 0.45),
            value: foreground.opacity(0.9),
            divider: palette.border,
            track: foreground.opacity(0.16),
            well: isDark ? palette.background.mixed(with: RGBA(white: 0), amount: 0.25) : foreground.opacity(0.06),
            selection: primary(for: .selection).opacity(isDark ? 0.2 : 0.16),
            panelBackground: palette.card,
            trackFill: foreground.opacity(0.55),
            thumb: isDark ? foreground : palette.card.mixed(with: RGBA(white: 1), amount: 0.7),
            thumbStroke: RGBA(white: 0, alpha: isDark ? 0.35 : 0.25),
            thumbShadow: RGBA(white: 0, alpha: isDark ? 0.4 : 0.2),
            editedDot: primary(for: .editedDot),
            accent: tint > 0 && roles.contains(.accent) ? palette.primary : nil,
            caution: .caution(dark: isDark),
            info: .info(foreground: foreground, dark: isDark),
            isDark: isDark,
        )
    }

    /// Each color `tint` of the way from its own-lightness grey to itself.
    static func tinted(_ palette: ThemePalette, by tint: Double) -> ThemePalette {
        let amount = 1 - min(max(tint, 0), 1)
        func t(_ color: RGBA) -> RGBA {
            color.desaturated(by: amount)
        }
        return ThemePalette(
            background: t(palette.background), card: t(palette.card), foreground: t(palette.foreground),
            muted: t(palette.muted), primary: t(palette.primary), accent: t(palette.accent),
            border: t(palette.border), success: t(palette.success), destructive: t(palette.destructive),
            neutral: t(palette.neutral), primaryRoles: palette.primaryRoles,
        )
    }
}
