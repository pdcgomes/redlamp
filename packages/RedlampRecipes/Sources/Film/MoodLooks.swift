import Foundation
import RedlampEngineAPI

/// One-tap mood looks in the spirit of Prequel's filters: a film look, its grain, halation and
/// bloom, plus light leaks, dust and scratches, frames and a few adjustments.
public enum MoodLooks {
    struct Mood {
        var slug: String
        var name: String
        var summary: String
        /// The film look it starts from (`FilmLookCatalog`).
        var film: String
        /// Settings over the film's own effects.
        var values: [ParameterID: Double]
        /// Published recipes never change: a new film look underneath is a new version.
        var version = 1
    }

    static let moods: [Mood] = [
        Mood(
            slug: "golden-leak", name: "Golden Leak",
            summary: "Overexposed Portra with a warm light leak and soft glow",
            film: "portra-400-overexposed",
            values: [.leakAmount: 45, .leakWarmth: 85, .leakVariation: 12, .bloomAmount: 18, .bloomSize: 60],
        ),
        Mood(
            slug: "lost-roll", name: "Lost Roll",
            summary: "A forgotten roll of Gold: leaks, dust, scratches and the film's rebate",
            film: "gold-200",
            values: [
                .leakAmount: 55, .leakWarmth: 70, .leakVariation: 37, .dustAmount: 40, .scratchAmount: 18,
                .frameStyle: Double(FrameStyle.filmRebate.rawValue), .vignetteAmount: -18,
            ],
        ),
        Mood(
            slug: "summer-98", name: "Summer '98", summary: "Warm consumer film, a light leak and a white print border",
            film: "ultramax-400",
            values: [
                .leakAmount: 32, .leakWarmth: 95, .leakVariation: 64,
                .frameStyle: Double(FrameStyle.printBorder.rawValue),
                .vibrance: 10,
            ],
        ),
        Mood(
            slug: "night-glow", name: "Night Glow",
            summary: "CineStill at night: strong halation, bloom and a little dust",
            film: "cinestill-800t",
            values: [.halationAmount: 85, .bloomAmount: 25, .bloomSize: 55, .dustAmount: 12],
        ),
        Mood(
            slug: "blue-hour", name: "Blue Hour", summary: "Pastel Pro 400H with a cool leak and a soft mist",
            film: "pro-400h",
            values: [.leakAmount: 38, .leakWarmth: -70, .leakVariation: 55, .bloomAmount: 22, .exposure: 0.25],
        ),
        Mood(
            slug: "mist", name: "Mist",
            summary: "Portra 160 through a diffusion filter: glowing highlights, gentle contrast",
            film: "portra-160",
            values: [.bloomAmount: 60, .bloomSize: 65, .contrast: -12],
        ),
        Mood(
            slug: "home-movie", name: "Home Movie",
            summary: "Daylight cinema film with projector scratches, dust and a dark edge",
            film: "vision3-50d-2383",
            values: [
                .scratchAmount: 45, .dustAmount: 30, .vignetteAmount: -30, .grainAmount: 22, .grainSize: 40,
                .frameStyle: Double(FrameStyle.keyline.rawValue),
            ],
        ),
        Mood(
            slug: "slide-show", name: "Slide Show", summary: "Kodachrome in a slide mount, with a few specks of dust",
            film: "kodachrome-64",
            values: [.dustAmount: 18, .frameStyle: Double(FrameStyle.slideMount.rawValue)],
            // 2: Kodachrome 64's look moved to version 2.
            version: 2,
        ),
        Mood(
            slug: "contact-sheet", name: "Contact Sheet",
            summary: "A hard Tri-X print with the film's rebate and darkroom dust",
            film: "tri-x-multigrade-hard",
            values: [.dustAmount: 30, .frameStyle: Double(FrameStyle.filmRebate.rawValue)],
        ),
        Mood(
            slug: "neon-rain", name: "Neon Rain",
            summary: "Cross-processed Provia with halation and a cool leak, for neon nights",
            film: "provia-100f-cross",
            values: [.halationAmount: 40, .leakAmount: 30, .leakWarmth: -40, .leakVariation: 80, .bloomAmount: 15],
        ),
        // Fitted to 20 photographs shot on each film (research/film-references) with
        // `redlamp recipe film --fit-moods`, on the film's own look: bright, open scans, as
        // photographers share their film. Per-band hue and saturation were left out, since they
        // follow the photographs' subjects more than the film.
        Mood(
            slug: "portra-days", name: "Portra Days",
            summary: "Bright, airy Portra, as photographers share their scans",
            film: "portra-400",
            values: [
                .blacks: 20,
                .contrast: -18,
                .highlights: 40,
                .saturation: -3,
                .shadows: 24,
                .vibrance: -12,
                .whites: 40,
                .gradeHighlightsHue: 56,
                .gradeHighlightsSaturation: 18,
                .gradeShadowsHue: 270,
                .gradeShadowsSaturation: 18,
                .wbShiftBlue: -6,
                .wbShiftRed: 6,
            ],
        ),
        Mood(
            slug: "ektar-colour", name: "Ektar Colour", summary: "Warm, vivid Ektar with open shadows",
            film: "ektar-100",
            values: [
                .blacks: 33,
                .contrast: -12,
                .highlights: 40,
                .saturation: -6,
                .shadows: 30,
                .vibrance: -6,
                .whites: 40,
                .grainAmount: 3,
                .gradeHighlightsHue: 108,
                .gradeHighlightsSaturation: 16,
                .gradeShadowsHue: 240,
                .gradeShadowsSaturation: 28,
                .wbShiftBlue: 6,
                .wbShiftRed: 42,
            ],
        ),
        Mood(
            slug: "gold-summer", name: "Gold Summer", summary: "Sunny Gold 200 with soft contrast and more grain",
            film: "gold-200",
            values: [
                .blacks: 15,
                .contrast: -18,
                .highlights: 40,
                .saturation: -21,
                .shadows: 24,
                .whites: 40,
                .grainAmount: 20,
                .gradeHighlightsHue: 72,
                .gradeHighlightsSaturation: 16,
                .gradeShadowsHue: 243,
                .gradeShadowsSaturation: 13,
                .wbShiftBlue: 12,
                .wbShiftRed: 45,
            ],
        ),
        Mood(
            slug: "superia-snapshots", name: "Superia Snapshots",
            summary: "Everyday Superia: bright, cool-leaning and grainy",
            film: "superia-400",
            values: [
                .blacks: 23,
                .contrast: -3,
                .highlights: 40,
                .saturation: -6,
                .shadows: 24,
                .vibrance: 12,
                .whites: 40,
                .grainAmount: 13,
                .gradeHighlightsHue: 45,
                .gradeHighlightsSaturation: 4,
                .gradeShadowsHue: 180,
                .gradeShadowsSaturation: 10,
                .wbShiftBlue: -24,
                .wbShiftRed: 18,
            ],
        ),
        Mood(
            slug: "wedding-day", name: "Wedding Day", summary: "Pastel, soft Pro 400H, the classic film wedding look",
            film: "pro-400h",
            values: [
                .blacks: 5,
                .contrast: -36,
                .highlights: 40,
                .saturation: -30,
                .shadows: 15,
                .vibrance: -6,
                .whites: 40,
                .gradeHighlightsHue: 45,
                .gradeHighlightsSaturation: 14,
                .gradeShadowsHue: 193,
                .gradeShadowsSaturation: 18,
                .wbShiftRed: 12,
            ],
        ),
        Mood(
            slug: "cinestill-nights", name: "CineStill Nights",
            summary: "CineStill after dark: deep shadows and a cool split tone",
            film: "cinestill-800t",
            values: [
                .blacks: -40,
                .contrast: 12,
                .highlights: 40,
                .saturation: -12,
                .shadows: -24,
                .vibrance: -12,
                .whites: 25,
                .grainAmount: 8,
                .gradeHighlightsHue: 135,
                .gradeHighlightsSaturation: 11,
                .gradeShadowsHue: 261,
                .gradeShadowsSaturation: 12,
                .wbShiftBlue: 3,
            ],
        ),
        Mood(
            slug: "velvia-landscapes", name: "Velvia Landscapes",
            summary: "Velvia as landscape photographers scan it: open shadows, rich colour",
            film: "velvia-50",
            values: [
                .blacks: 40,
                .contrast: -36,
                .highlights: 3,
                .saturation: 3,
                .whites: 20,
                .grainAmount: 5,
                .gradeHighlightsHue: 41,
                .gradeHighlightsSaturation: 27,
                .gradeShadowsHue: 236,
                .gradeShadowsSaturation: 14,
                .wbShiftBlue: 27,
                .wbShiftRed: 6,
            ],
        ),
        Mood(
            slug: "kodachrome-memories", name: "Kodachrome Memories",
            summary: "Bright Kodachrome with cool shadows, like old family slides",
            film: "kodachrome-64",
            values: [
                .blacks: -8,
                .contrast: -3,
                .highlights: 40,
                .saturation: -3,
                .shadows: 12,
                .vibrance: -12,
                .whites: 40,
                .gradeHighlightsHue: 56,
                .gradeHighlightsSaturation: 9,
                .gradeShadowsHue: 222,
                .gradeShadowsSaturation: 24,
                .wbShiftBlue: 36,
                .wbShiftRed: 3,
            ],
        ),
        Mood(
            slug: "tri-x-street", name: "Tri-X Street", summary: "Open, bright Tri-X, as street photographers print it",
            film: "tri-x-400",
            values: [
                .blacks: 10,
                .contrast: -18,
                .highlights: 40,
                .shadows: -18,
                .whites: 40,
                .grainAmount: 3,
                .gradeShadowsSaturation: 2,
                .wbShiftBlue: 60,
                .wbShiftRed: 60,
            ],
        ),
        Mood(
            slug: "hp5-documentary", name: "HP5 Documentary",
            summary: "Bright HP5 with deep blacks, for documentary work",
            film: "hp5-plus",
            values: [
                .blacks: -30,
                .contrast: 6,
                .highlights: 40,
                .shadows: 21,
                .whites: 40,
                .gradeShadowsHue: 270,
                .gradeShadowsSaturation: 4,
                .wbShiftBlue: 60,
                .wbShiftRed: 60,
            ],
        ),
    ]

    /// The bundled mood recipes. A mood whose film look isn't bundled is left out.
    public static var recipes: [Recipe] {
        moods.compactMap { mood in
            guard let look = FilmLookCatalog.look(mood.film),
                  let package = BuiltInBaseLooks.package(id: look.baseLookID, version: look.version)
            else { return nil }
            return BuiltInRecipes.make(
                "mood/\(mood.slug)", mood.name, group: "Mood", summary: mood.summary, tags: ["mood", "film"],
                values: look.effects.merging(mood.values) { $1 },
                treatment: look.isMonochrome ? .blackAndWhite : nil, baseLook: package.reference,
                lintWaivers: look.lintWaivers, version: mood.version,
            )
        }
    }
}
