import Foundation
import RedlampEngineAPI

/// The bundled starter pack: 39 recipes in eight groups, with original names only.
///
/// Published recipes never change. To improve one, add a new version (same id, `version`
/// + 1) and record its golden render; edits made with the old version keep their values.
enum StarterPack {
    typealias B = BuiltInRecipes

    static var recipes: [Recipe] {
        essentials + portrait + landscape + street + film + camera + blackAndWhite + night
    }

    private static func look(_ slot: FilmSlot) -> BaseLookReference {
        slot.baseLook
    }

    private static func fade(_ black: Double, white: Double = 1, mid: Double = 0.5) -> [CurvePoint] {
        [CurvePoint(x: 0, y: black), CurvePoint(x: 0.5, y: mid), CurvePoint(x: 1, y: white)]
    }

    // MARK: - Essentials

    static let essentials: [Recipe] = [
        B.make(
            "essentials/punchy",
            "Punchy",
            group: "Essentials",
            summary: "More contrast and color, highlights held.",
            values: [
                .contrast: 25, .highlights: -20, .shadows: 15, .whites: 10, .blacks: -10, .vibrance: 25,
            ],
            baseLook: BuiltInBaseLook.vivid.reference,
        ),
        B.make("essentials/clean", "Clean & Bright", group: "Essentials", summary: "Bright, airy and clean.", values: [
            .exposure: 0.3, .contrast: 5, .highlights: -35, .shadows: 30, .whites: 15, .vibrance: 12,
        ]),
        B.make(
            "essentials/soft-matte",
            "Soft Matte",
            group: "Essentials",
            summary: "Lifted blacks and softened contrast.",
            values: [
                .contrast: -20, .highlights: -25, .shadows: 20, .saturation: -12,
            ],
            pointCurve: [CurvePoint(x: 0, y: 0.08), CurvePoint(x: 0.5, y: 0.52), CurvePoint(x: 1, y: 0.95)],
        ),
        B.make("essentials/moody", "Moody", group: "Essentials", summary: "Darker, cooler and quieter.", values: [
            .exposure: -0.3, .contrast: 20, .highlights: -40, .shadows: -10, .vibrance: -10,
            .gradeShadowsHue: 210, .gradeShadowsSaturation: 18, .vignetteAmount: -25,
        ]),
        B.make(
            "essentials/golden-hour",
            "Golden Hour",
            group: "Essentials",
            summary: "Warm light and glowing highlights.",
            values: [
                .temperature: 6800, .tint: 8, .vibrance: 20, .gradeHighlightsHue: 45,
                .gradeHighlightsSaturation: 25, .gradeShadowsHue: 25, .gradeShadowsSaturation: 10,
            ],
            whiteBalanceMode: .custom,
            lintWaivers: ["skin-hue"],
        ),
        B.make(
            "essentials/natural-pop",
            "Natural Pop",
            group: "Essentials",
            summary: "A gentle lift in color and depth that suits almost anything.",
            values: [
                .contrast: 10, .highlights: -15, .shadows: 10, .vibrance: 18, .saturation: 3,
            ],
        ),
        B.make(
            "essentials/crisp",
            "Crisp Contrast",
            group: "Essentials",
            summary: "Deep blacks and bright whites with highlights protected.",
            values: [
                .contrast: 30, .whites: 12, .blacks: -15, .highlights: -10, .vibrance: 8, .dynamicRange: 200,
            ],
        ),
    ]
}

extension StarterPack {
    // MARK: - Portrait

    static let portrait: [Recipe] = [
        B.make(
            "portrait/soft-skin",
            "Soft Skin",
            group: "Portrait",
            summary: "Gentle contrast and even, luminous skin.",
            tags: ["skin"],
            values: [
                .contrast: -10, .highlights: -20, .shadows: 15, .saturationOrange: -8, .luminanceOrange: 10,
                .vibrance: 8,
            ],
            baseLook: BuiltInBaseLook.portrait.reference,
        ),
        B.make(
            "portrait/warm",
            "Warm Portrait",
            group: "Portrait",
            summary: "Portrait negative warmth with golden highlights.",
            tags: ["skin", "warm"],
            values: [
                .wbShiftRed: 15, .gradeHighlightsHue: 40, .gradeHighlightsSaturation: 12, .luminanceOrange: 8,
                .highlights: -15,
            ],
            baseLook: look(.negativeHigh),
        ),
        B.make(
            "portrait/studio",
            "Studio Clean",
            group: "Portrait",
            summary: "Crisp, neutral studio color with soft skin.",
            tags: ["skin", "studio"],
            values: [
                .contrast: 8, .highlights: -15, .whites: 8, .saturationOrange: -5,
            ],
            baseLook: look(.softSlide),
        ),
        B.make(
            "portrait/film",
            "Film Portrait",
            group: "Portrait",
            summary: "Soft negative film with a touch of grain and fade.",
            tags: ["skin", "film"],
            values: [
                .highlights: -20, .shadows: 10, .gradeShadowsHue: 200, .gradeShadowsSaturation: 8, .grainAmount: 15,
                .grainSize: 20,
            ],
            baseLook: look(.negativeStandard),
            pointCurve: fade(0.04, white: 0.97, mid: 0.51),
        ),
    ]

    // MARK: - Landscape

    static let landscape: [Recipe] = [
        B.make(
            "landscape/vivid",
            "Vivid Landscape",
            group: "Landscape",
            summary: "Saturated slide color with the highlights held.",
            tags: ["nature"],
            values: [
                .dynamicRange: 200, .highlights: -30, .shadows: 20, .vibrance: 10,
            ],
            baseLook: look(.vividSlide),
            // Version 2: on the measured Vivid Slide look.
            version: 2,
        ),
        B.make(
            "landscape/deep-sky",
            "Deep Blue Sky",
            group: "Landscape",
            summary: "Darker, richer blue skies and clean greens.",
            tags: ["sky"],
            values: [
                .saturationBlue: 20, .luminanceBlue: -20, .hueAqua: -5, .highlights: -25, .contrast: 8,
            ],
            baseLook: BuiltInBaseLook.landscape.reference,
        ),
        B.make(
            "landscape/autumn",
            "Autumn Glow",
            group: "Landscape",
            summary: "Warm oranges and golden yellows for fall color.",
            tags: ["nature", "warm"],
            values: [
                .saturationOrange: 20, .saturationYellow: 15, .hueYellow: -8, .gradeHighlightsHue: 40,
                .gradeHighlightsSaturation: 15, .wbShiftRed: 12, .contrast: 10,
            ],
            lintWaivers: ["skin-hue"],
        ),
        B.make(
            "landscape/misty",
            "Misty Morning",
            group: "Landscape",
            summary: "Soft, cool and airy, for fog and haze.",
            tags: ["soft", "cool"],
            values: [
                .contrast: -25, .highlights: -20, .saturation: -20, .gradeShadowsHue: 210, .gradeShadowsSaturation: 10,
            ],
            baseLook: look(.softSlide),
            pointCurve: fade(0.07, white: 0.97, mid: 0.52),
        ),
    ]
}

extension StarterPack {
    // MARK: - Street

    static let street: [Recipe] = [
        B.make(
            "street/gritty",
            "Gritty Street",
            group: "Street",
            summary: "Hard, muted chrome color with grain and weight.",
            tags: ["grain"],
            values: [
                .contrast: 20, .colorChrome: 60, .grainAmount: 25, .grainSize: 30, .vignetteAmount: -15,
            ],
            baseLook: look(.chrome),
            // Version 2: on the measured Chrome look.
            version: 2,
        ),
        B.make(
            "street/urban-teal",
            "Urban Teal",
            group: "Street",
            summary: "Teal shadows and warm light, a cinematic city.",
            tags: ["cinematic"],
            values: [
                .gradeShadowsHue: 190, .gradeShadowsSaturation: 20, .gradeHighlightsHue: 40,
                .gradeHighlightsSaturation: 18,
                .contrast: 15,
            ],
            baseLook: look(.cinema),
        ),
        B.make(
            "street/documentary",
            "Documentary",
            group: "Street",
            summary: "Honest snapshot negative, a little desaturated.",
            tags: ["film"],
            values: [
                .contrast: 10, .saturation: -10, .grainAmount: 18, .grainSize: 25,
            ],
            baseLook: look(.negativeClassic),
        ),
        B.make(
            "street/hard-light",
            "Hard Light",
            group: "Street",
            summary: "Silvery, contrasty midday light with highlight headroom.",
            tags: ["contrast"],
            values: [
                .contrast: 20, .dynamicRange: 400, .highlights: -20, .blacks: -10,
            ],
            baseLook: look(.bleach),
        ),
    ]

    // MARK: - Film-inspired

    static let film: [Recipe] = [
        B.make(
            "film/faded",
            "Faded Film",
            group: "Film-inspired",
            summary: "Washed-out prints with split-toned shadows and highlights.",
            tags: ["fade", "grain"],
            values: [
                .contrast: -15, .saturation: -15, .grainAmount: 25, .grainSize: 30,
                .gradeShadowsHue: 190, .gradeShadowsSaturation: 12, .gradeHighlightsHue: 50,
                .gradeHighlightsSaturation: 12,
            ],
            pointCurve: [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 0.3, y: 0.3), CurvePoint(x: 1, y: 0.92)],
        ),
        B.make(
            "film/warm-negative",
            "Warm Negative",
            group: "Film-inspired",
            summary: "Amber-tinted negative with muted blues.",
            tags: ["warm", "grain"],
            values: [
                .temperature: 6200, .contrast: 10, .saturationBlue: -20, .hueOrange: -8,
                .gradeMidtonesHue: 35, .gradeMidtonesSaturation: 10, .grainAmount: 18,
            ],
            baseLook: look(.negativeNostalgic),
            whiteBalanceMode: .custom,
            lintWaivers: ["skin-hue", "neutral-axis"],
        ),
        B.make(
            "film/cross-process",
            "Cross Process",
            group: "Film-inspired",
            summary: "Slide film in negative chemistry: shifted greens and yellow highlights.",
            tags: ["experimental"],
            values: [
                .contrast: 25, .hueGreen: 25, .gradeShadowsHue: 160, .gradeShadowsSaturation: 30,
                .gradeHighlightsHue: 60, .gradeHighlightsSaturation: 30,
            ],
            lintWaivers: ["neutral-axis", "skin-hue"],
        ),
        B.make(
            "film/saturated-slide",
            "Saturated Slide",
            group: "Film-inspired",
            summary: "Punchy transparency film with fine grain.",
            tags: ["slide"],
            values: [
                .contrast: 10, .grainAmount: 10, .grainSize: 15, .highlights: -10,
            ],
            baseLook: look(.vividSlide),
            // Version 2: on the measured Vivid Slide look.
            version: 2,
        ),
        B.make(
            "film/expired",
            "Expired Stock",
            group: "Film-inspired",
            summary: "Out-of-date film: faded, color-shifted and grainy.",
            tags: ["fade", "grain", "experimental"],
            values: [
                .gradeShadowsHue: 170, .gradeShadowsSaturation: 15, .gradeHighlightsHue: 50,
                .gradeHighlightsSaturation: 20,
                .grainAmount: 30, .grainSize: 40, .vignetteAmount: -20, .wbShiftRed: 10,
            ],
            baseLook: look(.negativeNostalgic),
            pointCurve: fade(0.09, white: 0.93, mid: 0.52),
            lintWaivers: ["neutral-axis", "skin-hue"],
        ),
        B.make(
            "film/silver-screen",
            "Silver Screen",
            group: "Film-inspired",
            summary: "Muted motion-picture color with teal shadows.",
            tags: ["cinematic"],
            values: [
                .contrast: -5, .gradeShadowsHue: 190, .gradeShadowsSaturation: 12, .grainAmount: 12,
                .vignetteAmount: -10,
            ],
            baseLook: look(.cinema),
        ),
    ]
}

extension StarterPack {
    // MARK: - Camera recipes (built from camera cards)

    static let camera: [Recipe] = [
        B.card(
            "camera/chrome-street",
            "Chrome Street",
            summary: "Muted chrome color, hard shadows and deep blues.",
            tags: ["street"],
            // Version 2: on the measured Chrome look.
            version: 2,
            CameraRecipeCard(
                filmSimulation: .chrome, dynamicRange: .dr400, highlight: -1, shadow: 1, color: -2,
                colorChrome: .strong,
                chromeFxBlue: .weak, whiteBalance: .init(mode: "auto", shiftRed: 2, shiftBlue: -4), grain: .init(
                    strength: .weak,
                    size: .small,
                ),
            ),
        ),
        B.card(
            "camera/snapshot-negative",
            "Snapshot Negative",
            summary: "Hard snapshot negative with cyan shadows and punchy grain.",
            tags: ["street", "grain"],
            CameraRecipeCard(
                filmSimulation: .negativeClassic, dynamicRange: .dr400, highlight: -0.5, shadow: 1.5, color: 2,
                colorChrome: .strong,
                chromeFxBlue: .weak, whiteBalance: .init(mode: "auto", shiftRed: 1, shiftBlue: -3), grain: .init(
                    strength: .strong,
                    size: .small,
                ),
            ),
        ),
        B.card(
            "camera/nostalgic-summer",
            "Nostalgic Summer",
            summary: "Warm, soft daylight color like an old print.",
            tags: ["warm"],
            CameraRecipeCard(
                filmSimulation: .negativeNostalgic, dynamicRange: .dr200, shadow: -1, color: 1, colorChrome: .weak,
                whiteBalance: .init(mode: "daylight", shiftRed: 3, shiftBlue: -5), grain: .init(
                    strength: .weak,
                    size: .large,
                ),
            ),
        ),
        B.card(
            "camera/cinema-teal",
            "Cinema Teal",
            summary: "Flat, muted motion-picture color with cool blues.",
            tags: ["cinematic"],
            CameraRecipeCard(
                filmSimulation: .cinema, dynamicRange: .dr400, highlight: -1, shadow: -1, color: -3,
                colorChrome: .strong,
                chromeFxBlue: .strong, whiteBalance: .init(mode: "kelvin", kelvin: 5600, shiftRed: -1, shiftBlue: 1),
            ),
        ),
        B.card(
            "camera/gold-standard",
            "Gold Standard",
            summary: "Warm portrait negative with golden skin and soft highlights.",
            tags: ["portrait", "warm"],
            CameraRecipeCard(
                filmSimulation: .negativeHigh, dynamicRange: .dr200, highlight: -1, shadow: -1, color: 2,
                colorChrome: .weak,
                whiteBalance: .init(mode: "auto", shiftRed: 4, shiftBlue: -6), grain: .init(
                    strength: .weak,
                    size: .small,
                ),
            ),
        ),
        B.card(
            "camera/bright-slide",
            "Bright Slide",
            summary: "Clean, bright slide color for sunny days.",
            tags: ["landscape"],
            // Version 2: on the measured Vivid Slide look.
            version: 2,
            CameraRecipeCard(
                filmSimulation: .vividSlide, dynamicRange: .dr200, shadow: 0.5, color: 1, colorChrome: .weak,
                chromeFxBlue: .weak,
            ),
        ),
    ]

    // MARK: - Black & White

    static let blackAndWhite: [Recipe] = [
        B.make(
            "bw/high-contrast",
            "High Contrast",
            group: "Black & White",
            summary: "Deep blacks and bright whites.",
            values: [
                .contrast: 40, .highlights: -20, .shadows: -10, .whites: 20, .blacks: -25,
            ],
            treatment: .blackAndWhite,
            baseLook: look(.monochrome),
        ),
        B.make(
            "bw/soft-silver",
            "Soft Silver",
            group: "Black & White",
            summary: "Open shadows and gentle grain.",
            values: [
                .contrast: -10, .shadows: 25, .grainAmount: 20,
            ],
            treatment: .blackAndWhite,
            baseLook: look(.monochrome),
        ),
        B.make(
            "bw/selenium",
            "Selenium",
            group: "Black & White",
            summary: "Cool shadows and warm highlights, like a toned print.",
            values: [
                .contrast: 20, .gradeShadowsHue: 265, .gradeShadowsSaturation: 18,
                .gradeHighlightsHue: 40, .gradeHighlightsSaturation: 10,
            ],
            treatment: .blackAndWhite,
        ),
        B.card(
            "bw/red-filter",
            "Red Filter Drama",
            summary: "Dark skies and bright skin, as through a red filter.",
            tags: ["monochrome", "sky"],
            CameraRecipeCard(
                filmSimulation: .monochromeRed, dynamicRange: .dr200, highlight: 1, shadow: 2, grain: .init(
                    strength: .strong,
                    size: .large,
                ),
            ),
        ),
        B.card(
            "bw/sepia-print",
            "Sepia Print",
            summary: "Warm brown-toned print with soft highlights.",
            tags: ["monochrome", "warm"],
            CameraRecipeCard(
                filmSimulation: .sepia, highlight: -1, grain: .init(strength: .weak, size: .small),
            ),
        ),
    ]
}

extension StarterPack {
    // MARK: - Night

    static let night: [Recipe] = [
        B.make(
            "night/neon",
            "Neon Night",
            group: "Night",
            summary: "Glowing signs and rich color, highlights held.",
            tags: ["city"],
            values: [
                .contrast: 15, .highlights: -30, .shadows: 10, .vibrance: 20, .saturationMagenta: 15,
                .saturationBlue: 10,
                .gradeShadowsHue: 230, .gradeShadowsSaturation: 15, .dynamicRange: 200,
            ],
        ),
        B.make(
            "night/tungsten",
            "Tungsten City",
            group: "Night",
            summary: "Warm street light over teal shadows.",
            tags: ["city", "cinematic"],
            values: [
                .gradeShadowsHue: 200, .gradeShadowsSaturation: 15, .gradeHighlightsHue: 45,
                .gradeHighlightsSaturation: 10,
                .contrast: 10, .grainAmount: 15,
            ],
            baseLook: look(.cinema),
        ),
        B.make(
            "night/blue-hour",
            "Blue Hour",
            group: "Night",
            summary: "Deep blue dusk with the lights kept warm.",
            tags: ["cool", "city"],
            values: [
                .wbShiftBlue: 20, .highlights: -20, .gradeShadowsHue: 225, .gradeShadowsSaturation: 18,
                .saturationBlue: 10,
            ],
            lintWaivers: ["neutral-axis"],
        ),
    ]
}
