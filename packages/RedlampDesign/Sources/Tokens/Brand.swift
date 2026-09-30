/// Redlamp's brand colors, for the places the brand lives: the About window, onboarding,
/// empty states and anything drawn around the app icon. They never appear on editing
/// surfaces, which stay neutral grey (`Palette`) so nothing tints the user's judgment of
/// color. See docs/brand/README.md.
public enum Brand {
    /// The lit ruby glass of the lamp, and the logo mark's lens on dark backgrounds.
    public static let safelight = RGBA(red: 224 / 255, green: 64 / 255, blue: 46 / 255)
    /// The lens on light backgrounds, a touch deeper so it holds its contrast on paper.
    public static let safelightOnLight = RGBA(red: 216 / 255, green: 53 / 255, blue: 42 / 255)
    /// The hot centre of the light. Only ever part of a glow, never a flat fill.
    public static let filament = RGBA(red: 255 / 255, green: 176 / 255, blue: 138 / 255)
    /// Warm near-black: the room the light falls into.
    public static let wall = RGBA(red: 10 / 255, green: 7 / 255, blue: 7 / 255)
    /// Raised dark surfaces, such as the About window.
    public static let bakelite = RGBA(red: 34 / 255, green: 28 / 255, blue: 26 / 255)
    /// Machined edges and highlights on dark.
    public static let steel = RGBA(red: 87 / 255, green: 80 / 255, blue: 78 / 255)
    /// The logo mark's ring on dark backgrounds.
    public static let ring = RGBA(red: 217 / 255, green: 208 / 255, blue: 203 / 255)
    /// Text on dark and light backgrounds for the brand.
    public static let paper = RGBA(red: 243 / 255, green: 238 / 255, blue: 232 / 255)
    /// Text and the logo mark's ring on light backgrounds.
    public static let ink = RGBA(red: 26 / 255, green: 20 / 255, blue: 20 / 255)
}
