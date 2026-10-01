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
    }

    static let moods: [Mood] = [
        Mood(
            slug: "golden-leak", name: "Golden Leak", summary: "Overexposed Portra with a warm light leak and soft glow",
            film: "portra-400-overexposed",
            values: [.leakAmount: 45, .leakWarmth: 85, .leakVariation: 12, .bloomAmount: 18, .bloomSize: 60],
        ),
        Mood(
            slug: "lost-roll", name: "Lost Roll", summary: "A forgotten roll of Gold: leaks, dust, scratches and the film's rebate",
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
                .leakAmount: 32, .leakWarmth: 95, .leakVariation: 64, .frameStyle: Double(FrameStyle.printBorder.rawValue),
                .vibrance: 10,
            ],
        ),
        Mood(
            slug: "night-glow", name: "Night Glow", summary: "CineStill at night: strong halation, bloom and a little dust",
            film: "cinestill-800t",
            values: [.halationAmount: 85, .bloomAmount: 25, .bloomSize: 55, .dustAmount: 12],
        ),
        Mood(
            slug: "blue-hour", name: "Blue Hour", summary: "Pastel Pro 400H with a cool leak and a soft mist",
            film: "pro-400h",
            values: [.leakAmount: 38, .leakWarmth: -70, .leakVariation: 55, .bloomAmount: 22, .exposure: 0.25],
        ),
        Mood(
            slug: "mist", name: "Mist", summary: "Portra 160 through a diffusion filter: glowing highlights, gentle contrast",
            film: "portra-160",
            values: [.bloomAmount: 60, .bloomSize: 65, .contrast: -12],
        ),
        Mood(
            slug: "home-movie", name: "Home Movie", summary: "Daylight cinema film with projector scratches, dust and a dark edge",
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
        ),
        Mood(
            slug: "contact-sheet", name: "Contact Sheet", summary: "A hard Tri-X print with the film's rebate and darkroom dust",
            film: "tri-x-multigrade-hard",
            values: [.dustAmount: 30, .frameStyle: Double(FrameStyle.filmRebate.rawValue)],
        ),
        Mood(
            slug: "neon-rain", name: "Neon Rain", summary: "Cross-processed Provia with halation and a cool leak, for neon nights",
            film: "provia-100f-cross",
            values: [.halationAmount: 40, .leakAmount: 30, .leakWarmth: -40, .leakVariation: 80, .bloomAmount: 15],
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
                lintWaivers: look.lintWaivers,
            )
        }
    }
}
