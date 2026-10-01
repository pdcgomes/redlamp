import Foundation
import RedlampEngineAPI

/// A film look: a stock, how it's rendered (printed, scanned or projected) and the effects that
/// come from the film itself rather than its colour: grain, halation and bloom.
public struct FilmLookDefinition: Sendable, Hashable {
    public var id: String
    public var name: String
    public var summary: String
    /// Whose datasheet the look is built from, and what kind of film it is.
    public var maker: String
    public var format: String
    public var icon: FilmIcon
    public var isMonochrome: Bool
    public var film: String
    /// One of the film's datasheet variants, such as a development time.
    public var filmVariant: [String: String]?
    /// The print stock; nil scans a negative or projects a slide.
    public var print: String?
    /// One of the print's datasheet variants, such as a paper grade.
    public var printVariant: [String: String]?
    public var process: FilmProcess
    /// Published looks never change: a new design is a new version.
    public var version: Int
    /// Lint checks the look fails by design, such as a cross-processed look's skin.
    public var lintWaivers: Set<String> = []
    /// The bundled table's size: 33 (0.5 EV a step across the scene range), more for a steep
    /// look, whose curve would otherwise show the steps.
    public var tableSize = 33
    public var parameters: FilmLookParameters
    /// Grain, halation and bloom, as Effects panel values.
    public var effects: [ParameterID: Double]

    /// The bundled Base Look's ID; the bundled recipe uses the same without `/look`.
    public var baseLookID: String {
        "\(recipeID)/look"
    }

    public var recipeID: String {
        "\(RecipeNamespace.bundled)/stock/\(id)"
    }
}

/// Redlamp's film looks, built from the datasheets in `research/film-data/`.
///
/// Grain amounts come from each datasheet's granularity, so the stocks keep their published
/// order: Kodak's Print Grain Index for an 8×10 print from 35 mm (25 is the threshold of
/// visibility, 4 a just-noticeable step) as `(PGI − 25) × 0.6`; diffuse rms granularity for
/// slides as rms; for black and white as rms × 2.2, since silver grain is sharper and shows
/// more. Where a datasheet gives no figure the amount is set beside its nearest published peer.
/// Halation is low for stocks with an anti-halation layer and high for CineStill, which has
/// had it removed.
public enum FilmLookCatalog {
    public static let looks: [FilmLookDefinition] = [
        look(
            "portra-160", "Portra 160", "Portra's finer-grained, gentler sister",
            maker: "Kodak", format: "Colour negative · ISO 160", icon: FilmIcon(
                .canister,
                body: .init(0.96, 0.93, 0.85),
                band: .init(0.95, 0.76, 0.42),
                text: .init(0.28, 0.16, 0.07),
                label: "160",
            ),
            film: "kodak-portra-160", scanner: .frontier,
            grain: (15, 26, 30), halation: (7, 40),
        ),
        look(
            "portra-400", "Portra 400", "Warm, gentle colour negative, as a Frontier scan renders it",
            maker: "Kodak", format: "Colour negative · ISO 400", icon: FilmIcon(
                .canister,
                body: .init(0.96, 0.93, 0.85),
                band: .init(0.93, 0.6, 0.16),
                text: .init(0.28, 0.16, 0.07),
                label: "400",
            ),
            // 2: dyes fitted to the stock's own published neutral rather than borrowed.
            film: "kodak-portra-400", version: 2, scanner: .frontier,
            grain: (20, 30, 35), halation: (8, 40),
        ),
        look(
            "portra-800", "Portra 800", "Fast Portra: warm and rich, with more grain",
            maker: "Kodak", format: "Colour negative · ISO 800", icon: FilmIcon(
                .canister,
                body: .init(0.96, 0.93, 0.85),
                band: .init(0.86, 0.36, 0.15),
                text: .init(1, 0.96, 0.9),
                label: "800",
            ),
            film: "kodak-portra-800", scanner: .frontier,
            grain: (27, 34, 40), halation: (9, 40),
        ),
        look(
            "portra-800-1600", "Portra 800 · Pushed to 1600", "Portra 800 rated at 1600 and pushed a stop: denser shadows, more contrast",
            maker: "Kodak", format: "Colour negative · ISO 800 pushed to 1600", icon: FilmIcon(
                .canister,
                body: .init(0.96, 0.93, 0.85),
                band: .init(0.86, 0.36, 0.15),
                text: .init(1, 0.96, 0.9),
                label: "1600",
            ),
            film: "kodak-portra-800", filmVariant: ["exposureIndex": "1600"], scanner: .frontier, exposure: -1,
            grain: (32, 38, 42), halation: (9, 40),
        ),
        look(
            "ektar-100", "Ektar 100", "Fine-grained, saturated colour negative",
            maker: "Kodak", format: "Colour negative · ISO 100", icon: FilmIcon(
                .canister,
                body: .init(0.84, 0.15, 0.12),
                band: .init(0.98, 0.8, 0.2),
                text: .init(0.22, 0.1, 0.05),
                label: "100",
            ),
            // 2: dyes fitted to the stock's own published neutral rather than borrowed.
            film: "kodak-ektar-100", version: 2, scanner: .frontier,
            grain: (8, 22, 30), halation: (6, 40),
        ),
        look(
            "gold-200", "Gold 200", "Warm consumer colour negative with a little more grain",
            maker: "Kodak", format: "Colour negative · ISO 200", icon: FilmIcon(
                .canister,
                body: .init(0.98, 0.75, 0.12),
                band: .init(0.83, 0.18, 0.12),
                text: .init(1, 0.95, 0.85),
                label: "200",
            ),
            // 2: dyes fitted to the stock's own published neutral rather than borrowed.
            film: "kodak-gold-200", version: 2, scanner: .frontier,
            grain: (23, 30, 40), halation: (9, 40),
        ),
        look(
            "ultramax-400", "UltraMax 400", "Punchy, warm everyday colour negative",
            maker: "Kodak", format: "Colour negative · ISO 400", icon: FilmIcon(
                .canister,
                body: .init(0.18, 0.33, 0.72),
                band: .init(0.98, 0.8, 0.15),
                text: .init(0.12, 0.2, 0.5),
                label: "400",
            ),
            film: "kodak-ultramax-400", scanner: .frontier,
            grain: (25, 32, 42), halation: (9, 40),
        ),
        // Superia's rms granularity is on Fujifilm's negative scale, which doesn't compare with
        // Kodak's index; set beside Gold.
        look(
            "superia-400", "Superia 400", "Cooler consumer colour negative with Fujifilm's greens",
            maker: "Fujifilm", format: "Colour negative · ISO 400", icon: FilmIcon(
                .canister,
                body: .init(0.1, 0.52, 0.3),
                band: .init(0.95, 0.97, 0.95),
                text: .init(0.05, 0.36, 0.2),
                label: "400",
            ),
            // 2: dyes fitted to the stock's own published neutral rather than borrowed.
            film: "fuji-superia-xtra-400", version: 2, scanner: .frontier,
            grain: (24, 32, 45), halation: (8, 40),
        ),
        look(
            "pro-400h", "Pro 400H", "Fujifilm's pastel wedding film: soft contrast and minty greens",
            maker: "Fujifilm", format: "Colour negative · ISO 400 (discontinued)", icon: FilmIcon(
                .canister,
                body: .init(0.96, 0.97, 0.98),
                band: .init(0.36, 0.6, 0.86),
                text: .init(0.08, 0.2, 0.45),
                label: "400H",
            ),
            film: "fuji-pro-400h", scanner: .frontier,
            grain: (24, 32, 40), halation: (8, 40),
        ),
        // Vision3 publishes granularity only as curves; 500T is a fast stock, set a little
        // above Portra. CineStill is the same emulsion without its anti-halation backing.
        look(
            "cinestill-800t", "CineStill 800T",
            "Tungsten cinema negative without anti-halation: red glow around lights",
            maker: "CineStill", format: "Tungsten colour negative · ISO 800", icon: FilmIcon(
                .canister,
                body: .init(0.13, 0.13, 0.14),
                band: .init(0.84, 0.12, 0.15),
                text: .init(1, 1, 1),
                label: "800T",
            ),
            film: "cinestill-800t", scanner: .noritsu,
            grain: (26, 34, 45), halation: (70, 55), bloom: (8, 50),
        ),
        look(
            "cinestill-50d", "CineStill 50D", "Daylight cinema negative without anti-halation: fine grain, glowing highlights",
            maker: "CineStill", format: "Daylight colour negative · ISO 50", icon: FilmIcon(
                .canister,
                body: .init(0.13, 0.13, 0.14),
                band: .init(0.2, 0.55, 0.86),
                text: .init(1, 1, 1),
                label: "50D",
            ),
            film: "cinestill-50d", scanner: .noritsu,
            grain: (12, 22, 35), halation: (60, 50), bloom: (6, 50),
        ),
        look(
            "vision3-500t-2383", "Vision3 500T · 2383", "Cinema negative printed on 2383 print film",
            maker: "Kodak", format: "Cinema negative on print film · ISO 500", icon: FilmIcon(
                .reel,
                body: .init(0.16, 0.2, 0.31),
                band: .init(0.85, 0.63, 0.25),
                text: .init(0.12, 0.1, 0.08),
                label: "500T",
            ),
            // 2: Kodak 2383's sensitivity re-traced.
            film: "kodak-vision3-500t", version: 2, print: "kodak-2383", flare: 0.004,
            grain: (24, 32, 40), halation: (14, 45), bloom: (6, 50),
        ),
        look(
            "vision3-250d-2383", "Vision3 250D · 2383", "Daylight cinema negative printed on 2383",
            maker: "Kodak", format: "Cinema negative on print film · ISO 250", icon: FilmIcon(
                .reel,
                body: .init(0.24, 0.31, 0.44),
                band: .init(0.95, 0.84, 0.4),
                text: .init(0.12, 0.1, 0.08),
                label: "250D",
            ),
            film: "kodak-vision3-250d", print: "kodak-2383", flare: 0.004,
            grain: (20, 30, 40), halation: (12, 45), bloom: (6, 50),
        ),
        look(
            "vision3-50d-2383", "Vision3 50D · 2383", "The finest-grained cinema negative, printed on 2383",
            maker: "Kodak", format: "Cinema negative on print film · ISO 50", icon: FilmIcon(
                .reel,
                body: .init(0.24, 0.31, 0.44),
                band: .init(0.96, 0.92, 0.66),
                text: .init(0.12, 0.1, 0.08),
                label: "50D",
            ),
            film: "kodak-vision3-50d", print: "kodak-2383", flare: 0.004,
            grain: (12, 22, 35), halation: (10, 45), bloom: (5, 50),
        ),
        look(
            "eterna-vivid-250d-2383", "Eterna Vivid 250D · 2383", "Fujifilm's vivid daylight cinema negative, printed on 2383",
            maker: "Fujifilm", format: "Cinema negative on print film · ISO 250 (discontinued)", icon: FilmIcon(
                .reel,
                body: .init(0.1, 0.36, 0.3),
                band: .init(0.92, 0.92, 0.86),
                text: .init(0.08, 0.24, 0.2),
                label: "ETV",
            ),
            film: "fuji-eterna-vivid-250d", print: "kodak-2383", flare: 0.004,
            grain: (21, 30, 40), halation: (12, 45), bloom: (6, 50),
        ),
        // Slides are exposed for their highlights, so mid-grey sits a little lower.
        look(
            "provia-100f", "Provia 100F", "Clean, natural slide film",
            maker: "Fujifilm", format: "Slide film · ISO 100", icon: FilmIcon(
                .slide,
                body: .init(0.95, 0.95, 0.93),
                band: .init(0.12, 0.5, 0.62),
                text: .init(0.08, 0.4, 0.48),
                label: "100F",
            ),
            film: "fuji-provia-100f", displayGrey: 0.24,
            grain: (8, 18, 25), halation: (4, 35),
        ),
        look(
            "velvia-50", "Velvia 50", "Saturated, contrasty slide film",
            maker: "Fujifilm", format: "Slide film · ISO 50", icon: FilmIcon(
                .slide,
                body: .init(0.94, 0.93, 0.96),
                band: .init(0.42, 0.16, 0.58),
                text: .init(0.36, 0.12, 0.5),
                label: "50",
            ),
            film: "fuji-velvia-50", displayGrey: 0.24,
            grain: (9, 16, 25), halation: (4, 35),
        ),
        look(
            "velvia-100", "Velvia 100", "Velvia's faster, slightly gentler sibling",
            maker: "Fujifilm", format: "Slide film · ISO 100", icon: FilmIcon(
                .slide,
                body: .init(0.94, 0.93, 0.96),
                band: .init(0.55, 0.26, 0.66),
                text: .init(0.4, 0.14, 0.52),
                label: "100",
            ),
            film: "fuji-velvia-100", displayGrey: 0.24,
            grain: (8, 18, 25), halation: (4, 35),
        ),
        look(
            "ektachrome-e100", "Ektachrome E100", "Kodak's clean, cool slide film",
            maker: "Kodak", format: "Slide film · ISO 100", icon: FilmIcon(
                .slide,
                body: .init(0.95, 0.95, 0.94),
                band: .init(0.82, 0.24, 0.16),
                text: .init(0.6, 0.12, 0.08),
                label: "E100",
            ),
            film: "kodak-ektachrome-e100", displayGrey: 0.24,
            grain: (8, 18, 25), halation: (4, 35),
        ),
        look(
            "kodachrome-64", "Kodachrome 64", "The legendary K-14 slide: warm reds, deep blues, dense shadows",
            maker: "Kodak", format: "Slide film · ISO 64 (discontinued)", icon: FilmIcon(
                .slide,
                body: .init(0.98, 0.83, 0.18),
                band: .init(0.8, 0.16, 0.12),
                text: .init(0.5, 0.08, 0.05),
                label: "K64",
            ),
            film: "kodak-kodachrome-64", displayGrey: 0.24,
            grain: (10, 20, 25), halation: (4, 35),
        ),
        look(
            "tri-x-400", "Tri-X 400", "Classic black and white, scanned",
            maker: "Kodak", format: "Black and white negative · ISO 400", icon: FilmIcon(
                .canister,
                body: .init(0.98, 0.8, 0.1),
                band: .init(0.08, 0.08, 0.08),
                text: .init(0.98, 0.8, 0.1),
                label: "400",
                leader: .init(0.3, 0.3, 0.3),
            ),
            monochrome: true,
            film: "kodak-tri-x-400", scanContrast: 1.1,
            grain: (37, 38, 0), roughness: 65, halation: (5, 40),
        ),
        look(
            "t-max-100", "T-Max 100", "Kodak's finest-grained black and white: smooth and sharp",
            maker: "Kodak", format: "Black and white negative · ISO 100", icon: FilmIcon(
                .canister,
                body: .init(0.16, 0.26, 0.56),
                band: .init(0.98, 0.8, 0.1),
                text: .init(0.16, 0.26, 0.56),
                label: "100",
                leader: .init(0.3, 0.3, 0.3),
            ),
            monochrome: true,
            film: "kodak-t-max-100", grain: (18, 24, 0), roughness: 45, halation: (4, 40),
        ),
        look(
            "t-max-400", "T-Max 400", "Modern fast black and white: tight grain, long tonal range",
            maker: "Kodak", format: "Black and white negative · ISO 400", icon: FilmIcon(
                .canister,
                body: .init(0.16, 0.26, 0.56),
                band: .init(0.92, 0.92, 0.92),
                text: .init(0.16, 0.26, 0.56),
                label: "400",
                leader: .init(0.3, 0.3, 0.3),
            ),
            monochrome: true,
            film: "kodak-t-max-400", grain: (22, 30, 0), roughness: 50, halation: (5, 40),
        ),
        // HP5 Plus publishes no granularity; it is generally a touch coarser than Tri-X.
        look(
            "hp5-plus", "HP5 Plus", "Softer, grainier black and white, scanned",
            maker: "Ilford", format: "Black and white negative · ISO 400", icon: FilmIcon(
                .canister,
                body: .init(0.09, 0.09, 0.09),
                band: .init(0.96, 0.96, 0.96),
                text: .init(0.09, 0.09, 0.09),
                label: "HP5",
                leader: .init(0.3, 0.3, 0.3),
            ),
            monochrome: true,
            film: "ilford-hp5-plus",
            grain: (40, 42, 0), roughness: 60, halation: (5, 40),
        ),
        look(
            "delta-100", "Delta 100", "Ilford's fine-grained modern black and white",
            maker: "Ilford", format: "Black and white negative · ISO 100", icon: FilmIcon(
                .canister,
                body: .init(0.09, 0.09, 0.09),
                band: .init(0.86, 0.2, 0.2),
                text: .init(1, 1, 1),
                label: "D100",
                leader: .init(0.3, 0.3, 0.3),
            ),
            monochrome: true,
            film: "ilford-delta-100", grain: (16, 24, 0), roughness: 45, halation: (4, 40),
        ),
        look(
            "delta-3200", "Delta 3200", "Ilford's fastest film: big, gritty grain for low light",
            maker: "Ilford", format: "Black and white negative · ISO 3200", icon: FilmIcon(
                .canister,
                body: .init(0.09, 0.09, 0.09),
                band: .init(0.96, 0.56, 0.1),
                text: .init(0.09, 0.09, 0.09),
                label: "3200",
                leader: .init(0.3, 0.3, 0.3),
            ),
            monochrome: true,
            film: "ilford-delta-3200", scanContrast: 1.05,
            grain: (52, 50, 0), roughness: 70, halation: (6, 40),
        ),
        look(
            "fp4-plus", "FP4 Plus", "Classic medium-speed black and white with a gentle shoulder",
            maker: "Ilford", format: "Black and white negative · ISO 125", icon: FilmIcon(
                .canister,
                body: .init(0.09, 0.09, 0.09),
                band: .init(0.2, 0.6, 0.32),
                text: .init(1, 1, 1),
                label: "FP4",
                leader: .init(0.3, 0.3, 0.3),
            ),
            monochrome: true,
            film: "ilford-fp4-plus", grain: (24, 30, 0), roughness: 55, halation: (5, 40),
        ),
        look(
            "pan-f-plus", "Pan F Plus", "Slow, ultra-fine black and white with rich contrast",
            maker: "Ilford", format: "Black and white negative · ISO 50", icon: FilmIcon(
                .canister,
                body: .init(0.09, 0.09, 0.09),
                band: .init(0.26, 0.46, 0.86),
                text: .init(1, 1, 1),
                label: "PAN F",
                leader: .init(0.3, 0.3, 0.3),
            ),
            monochrome: true,
            film: "ilford-pan-f-plus", grain: (12, 18, 0), roughness: 40, halation: (4, 40),
        ),
        look(
            "tri-x-multigrade", "Tri-X · Darkroom Print", "Tri-X printed on Multigrade paper, grade 2",
            maker: "Kodak · Ilford", format: "Black and white print · grade 2", icon: FilmIcon(
                .paper,
                body: .init(0.97, 0.96, 0.93),
                band: .init(0.5, 0.5, 0.5),
                text: .init(0.15, 0.15, 0.15),
                label: "TRI-X",
            ),
            monochrome: true,
            film: "kodak-tri-x-400", print: "ilford-multigrade-rc", flare: 0.004,
            grain: (34, 36, 0), roughness: 65, halation: (5, 40),
        ),
        // Variants and processes, from the same datasheets.
        look(
            "portra-400-overexposed", "Portra 400 · +2", "Portra overexposed two stops: airy, pastel and soft",
            maker: "Kodak", format: "Colour negative · ISO 400 rated 100", icon: FilmIcon(
                .canister,
                body: .init(0.96, 0.93, 0.85),
                band: .init(0.93, 0.6, 0.16),
                text: .init(0.28, 0.16, 0.07),
                label: "+2",
            ),
            film: "kodak-portra-400", scanner: .frontier, exposure: 2,
            grain: (16, 28, 35), halation: (8, 40),
        ),
        // Push processing: rated two stops fast and developed longer (the datasheet's longest
        // D-76 time), so shadows thin out and contrast and grain rise.
        look(
            "tri-x-1600", "Tri-X 400 · Pushed to 1600", "Tri-X rated at 1600 and push-processed: gritty and hard",
            maker: "Kodak", format: "Black and white negative · ISO 400 pushed to 1600", icon: FilmIcon(
                .canister,
                body: .init(0.98, 0.8, 0.1),
                band: .init(0.08, 0.08, 0.08),
                text: .init(0.98, 0.8, 0.1),
                label: "1600",
                leader: .init(0.3, 0.3, 0.3),
            ),
            monochrome: true,
            film: "kodak-tri-x-400", filmVariant: ["format": "135", "developer": "D-76", "timeMin": "12"],
            scanContrast: 1.1, exposure: -2,
            grain: (46, 44, 0), roughness: 70, halation: (6, 40),
        ),
        look(
            "tri-x-multigrade-soft", "Tri-X · Soft Print", "Tri-X printed on Multigrade paper at grade 1: gentle and open",
            maker: "Kodak · Ilford", format: "Black and white print · grade 1", icon: FilmIcon(
                .paper,
                body: .init(0.97, 0.96, 0.93),
                band: .init(0.5, 0.5, 0.5),
                text: .init(0.15, 0.15, 0.15),
                label: "G1",
            ),
            monochrome: true,
            film: "kodak-tri-x-400", print: "ilford-multigrade-rc", printVariant: ["filter": "1"], flare: 0.004,
            grain: (34, 36, 0), roughness: 65, halation: (5, 40),
        ),
        look(
            "tri-x-multigrade-hard", "Tri-X · Hard Print", "Tri-X printed on Multigrade paper at grade 4: deep blacks, bright whites",
            maker: "Kodak · Ilford", format: "Black and white print · grade 4", icon: FilmIcon(
                .paper,
                body: .init(0.97, 0.96, 0.93),
                band: .init(0.5, 0.5, 0.5),
                text: .init(0.15, 0.15, 0.15),
                label: "G4",
            ),
            monochrome: true,
            // 2: a 49-sample table, since grade 4's steep curve showed a 33-sample table's steps.
            film: "kodak-tri-x-400", version: 2, print: "ilford-multigrade-rc", printVariant: ["filter": "4"],
            flare: 0.004,
            grain: (34, 36, 0), roughness: 65, halation: (5, 40),
            tableSize: 49,
        ),
        look(
            "vision3-2383-bleach-bypass", "Vision3 500T · 2383 Bleach Bypass",
            "Cinema print with its silver left in: desaturated, dense and hard",
            maker: "Kodak", format: "Cinema negative on print film, bleach bypass · ISO 500", icon: FilmIcon(
                .reel,
                body: .init(0.2, 0.21, 0.24),
                band: .init(0.7, 0.71, 0.72),
                text: .init(0.1, 0.1, 0.1),
                label: "BB",
            ),
            // 2: Kodak 2383's sensitivity re-traced.
            film: "kodak-vision3-500t", version: 2, print: "kodak-2383", process: .bleachBypass, flare: 0.004,
            grain: (26, 32, 30), halation: (12, 45), bloom: (6, 50),
        ),
        // Cross-processing keeps most of the stock's crossovers: the scanner can't neutralise a
        // slide emulsion developed as a negative.
        look(
            "velvia-50-cross", "Velvia 50 · Cross-Processed", "Velvia developed as a negative: punchy, with wild colour shifts",
            maker: "Fujifilm", format: "Slide film in C-41 · ISO 50", icon: FilmIcon(
                .slide,
                body: .init(0.94, 0.93, 0.96),
                band: .init(0.55, 0.75, 0.2),
                text: .init(0.36, 0.12, 0.5),
                label: "XPRO",
            ),
            film: "fuji-velvia-50", process: .crossProcessed, scanNeutral: 0.75,
            grain: (12, 20, 35), halation: (5, 35),
        ),
        look(
            "provia-100f-cross", "Provia 100F · Cross-Processed", "Provia developed as a negative: contrasty, with cool shadows",
            maker: "Fujifilm", format: "Slide film in C-41 · ISO 100", icon: FilmIcon(
                .slide,
                body: .init(0.95, 0.95, 0.93),
                band: .init(0.2, 0.62, 0.55),
                text: .init(0.08, 0.4, 0.48),
                label: "XPRO",
            ),
            film: "fuji-provia-100f", process: .crossProcessed, scanNeutral: 0.55,
            grain: (11, 20, 35), halation: (5, 35),
        ),
    ]

    public static func look(_ id: String) -> FilmLookDefinition? {
        looks.first { $0.id == id }
    }

    /// The catalogue look a bundled Base Look or recipe belongs to.
    public static func look(forBundledID id: String) -> FilmLookDefinition? {
        looks.first { $0.baseLookID == id || $0.recipeID == id }
    }

    /// The bundled recipes: each look's bundled Base Look with its effects. A look whose
    /// table isn't bundled is left out.
    public static var bundledRecipes: [Recipe] {
        looks.compactMap { look in
            guard let package = BuiltInBaseLooks.package(id: look.baseLookID, version: look.version)
            else { return nil }
            return BuiltInRecipes.make(
                "stock/\(look.id)", look.name, group: "Film Stocks", summary: look.summary, tags: ["film"],
                values: look.effects, treatment: look.isMonochrome ? .blackAndWhite : nil, baseLook: package.reference,
                lintWaivers: look.lintWaivers, version: look.version,
            )
        }
    }


    private static func look(
        _ id: String,
        _ name: String,
        _ summary: String,
        maker: String,
        format: String,
        icon: FilmIcon,
        monochrome: Bool = false,
        film: String,
        version: Int = 1,
        filmVariant: [String: String]? = nil,
        print: String? = nil,
        printVariant: [String: String]? = nil,
        process: FilmProcess = .standard,
        scanner: ScannerProfile = .neutral,
        scanContrast: Double = 1,
        scanNeutral: Double? = nil,
        exposure: Double = 0,
        flare: Double = 0,
        displayGrey: Double? = nil,
        grain: (amount: Double, size: Double, color: Double),
        roughness: Double = 50,
        halation: (amount: Double, size: Double),
        bloom: (amount: Double, size: Double)? = nil,
        lintWaivers: Set<String> = [],
        tableSize: Int = 33,
    ) -> FilmLookDefinition {
        var parameters = FilmLookParameters()
        parameters.scanner = scanner
        parameters.scanContrast = scanContrast
        parameters.scanNeutral = scanNeutral ?? parameters.scanNeutral
        parameters.exposure = exposure
        parameters.flare = flare
        parameters.displayGrey = displayGrey ?? parameters.displayGrey
        var effects: [ParameterID: Double] = [
            .grainAmount: grain.amount, .grainSize: grain.size, .grainColor: grain.color, .grainRoughness: roughness,
            .halationAmount: halation.amount, .halationSize: halation.size,
        ]
        if let bloom {
            effects[.bloomAmount] = bloom.amount
            effects[.bloomSize] = bloom.size
        }
        return FilmLookDefinition(
            id: id, name: name, summary: summary, maker: maker, format: format, icon: icon, isMonochrome: monochrome,
            film: film, filmVariant: filmVariant, print: print, printVariant: printVariant, process: process,
            version: version,
            // Cross-processing shifts skin by design.
            lintWaivers: lintWaivers.union(process == .crossProcessed ? ["skin-hue"] : []),
            tableSize: tableSize, parameters: parameters, effects: effects,
        )
    }
}

public extension FilmLooks {
    static func table(for look: FilmLookDefinition, size: Int, data directory: URL?) throws -> LookTable {
        try table(
            film: look.film, filmVariant: look.filmVariant, print: look.print, printVariant: look.printVariant,
            process: look.process, parameters: look.parameters, size: size, data: directory,
        )
    }

    /// The look's bundled Base Look package, built from the datasheets.
    static func bundledPackage(for look: FilmLookDefinition, data directory: URL?) throws -> BaseLookPackage {
        let table = try table(for: look, size: look.tableSize, data: directory)
        return BaseLookPackage(
            id: look.baseLookID, version: look.version, name: look.name,
            summary: "\(look.summary). Built from \(look.maker)'s published datasheet.", parameters: .identity,
            table: table,
        )
    }

    /// The recipe for a catalogue look: its Base Look table and its Effects settings.
    static func recipe(
        for look: FilmLookDefinition, size: Int = 33, data directory: URL?,
    ) throws -> Recipe {
        let table = try table(for: look, size: size, data: directory)
        var recipe = LookTableImport.recipe(for: table, name: look.name, id: "local/film/\(look.id)")
        recipe.group = "Film"
        recipe.summary = look.summary
        recipe.tags = ["film"]
        recipe.includes.insert(.effects)
        recipe.settings.values.merge(look.effects) { $1 }
        if !recipe.embeddedBaseLooks.isEmpty {
            recipe.embeddedBaseLooks[0].summary = look.summary
        }
        if look.isMonochrome {
            recipe.includes.insert(.treatment)
            recipe.settings.treatment = .blackAndWhite
        }
        return recipe
    }
}
