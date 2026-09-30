import Foundation
import RedlampEngineAPI

/// A camera-style recipe card: the settings Fujifilm-style "film recipes" are shared as.
///
/// The card is stored in the recipe next to the values it resolves to, so it can be shown
/// and edited in its own terms. Film simulations are Redlamp's own slot names, each filled
/// by a bundled Base Look; a recipe keeps working when better looks fill a slot later,
/// because the resolved Base Look is pinned by version and hash.
public struct CameraRecipeCard: Codable, Sendable, Hashable {
    public static let dialect = "fujifilm-card"
    /// Bumped whenever `resolve` maps a card differently. Recipes record the mapping they
    /// were resolved with and are only re-resolved when the user edits the card.
    public static let mappingVersion = 1

    public enum Strength: String, Codable, Sendable, Hashable, CaseIterable {
        case off, weak, strong
    }

    public enum GrainSize: String, Codable, Sendable, Hashable, CaseIterable {
        case small, large
    }

    public enum DynamicRange: String, Codable, Sendable, Hashable, CaseIterable {
        case dr100, dr200, dr400, auto

        public var percent: Double {
            switch self {
            case .dr100: 100
            case .dr200, .auto: 200
            case .dr400: 400
            }
        }
    }

    public struct WhiteBalance: Codable, Sendable, Hashable {
        /// `auto`, a preset such as `daylight`, or `kelvin`.
        public var mode: String
        public var kelvin: Double?
        /// Camera fine-tuning steps, -9...9.
        public var shiftRed: Int
        public var shiftBlue: Int

        public init(mode: String = "auto", kelvin: Double? = nil, shiftRed: Int = 0, shiftBlue: Int = 0) {
            self.mode = mode
            self.kelvin = kelvin
            self.shiftRed = shiftRed
            self.shiftBlue = shiftBlue
        }
    }

    public struct Grain: Codable, Sendable, Hashable {
        public var strength: Strength
        public var size: GrainSize

        public init(strength: Strength = .off, size: GrainSize = .small) {
            self.strength = strength
            self.size = size
        }
    }

    /// A `FilmSlot` raw value.
    public var filmSimulation: String
    public var dynamicRange: DynamicRange
    /// -2...+4 in half steps.
    public var highlight: Double
    /// -2...+4 in half steps.
    public var shadow: Double
    /// -4...+4.
    public var color: Int
    public var colorChrome: Strength
    public var chromeFxBlue: Strength
    public var whiteBalance: WhiteBalance
    public var grain: Grain
    /// -5...+5.
    public var clarity: Int
    /// -4...+4.
    public var sharpness: Int
    /// -4...+4.
    public var noiseReduction: Int
    /// Exposure compensation the recipe suggests, in EV.
    public var exposure: Double
    /// Monochrome toning, -9...9: warm/cool and magenta/green.
    public var monochromeWarmCool: Int
    public var monochromeMagentaGreen: Int

    public init(
        filmSimulation: FilmSlot = .standard,
        dynamicRange: DynamicRange = .dr100,
        highlight: Double = 0,
        shadow: Double = 0,
        color: Int = 0,
        colorChrome: Strength = .off,
        chromeFxBlue: Strength = .off,
        whiteBalance: WhiteBalance = WhiteBalance(),
        grain: Grain = Grain(),
        clarity: Int = 0,
        sharpness: Int = 0,
        noiseReduction: Int = 0,
        exposure: Double = 0,
        monochromeWarmCool: Int = 0,
        monochromeMagentaGreen: Int = 0,
    ) {
        self.filmSimulation = filmSimulation.rawValue
        self.dynamicRange = dynamicRange
        self.highlight = highlight
        self.shadow = shadow
        self.color = color
        self.colorChrome = colorChrome
        self.chromeFxBlue = chromeFxBlue
        self.whiteBalance = whiteBalance
        self.grain = grain
        self.clarity = clarity
        self.sharpness = sharpness
        self.noiseReduction = noiseReduction
        self.exposure = exposure
        self.monochromeWarmCool = monochromeWarmCool
        self.monochromeMagentaGreen = monochromeMagentaGreen
    }

    public var slot: FilmSlot? {
        FilmSlot(rawValue: filmSimulation)
    }

    /// The card with every field clamped to the camera's range.
    public var clamped: CameraRecipeCard {
        var card = self
        func half(_ x: Double, _ range: ClosedRange<Double>) -> Double {
            (min(max(x, range.lowerBound), range.upperBound) * 2).rounded() / 2
        }
        func steps(_ x: Int, _ range: ClosedRange<Int>) -> Int {
            min(max(x, range.lowerBound), range.upperBound)
        }
        card.highlight = half(highlight, -2 ... 4)
        card.shadow = half(shadow, -2 ... 4)
        card.color = steps(color, -4 ... 4)
        card.whiteBalance.shiftRed = steps(whiteBalance.shiftRed, -9 ... 9)
        card.whiteBalance.shiftBlue = steps(whiteBalance.shiftBlue, -9 ... 9)
        if let kelvin = whiteBalance.kelvin {
            card.whiteBalance.kelvin = min(max(kelvin, 2500), 10000)
        }
        card.clarity = steps(clarity, -5 ... 5)
        card.sharpness = steps(sharpness, -4 ... 4)
        card.noiseReduction = steps(noiseReduction, -4 ... 4)
        card.exposure = min(max(exposure, -3), 3)
        card.monochromeWarmCool = steps(monochromeWarmCool, -9 ... 9)
        card.monochromeMagentaGreen = steps(monochromeMagentaGreen, -9 ... 9)
        return card
    }
}

/// Redlamp's film-simulation slots. Names are our own; each slot is filled by a bundled
/// Base Look with the character described in `summary`.
public enum FilmSlot: String, Codable, Sendable, Hashable, CaseIterable {
    case standard
    case vividSlide = "vivid-slide"
    case softSlide = "soft-slide"
    case chrome
    case negativeHigh = "negative-high"
    case negativeStandard = "negative-standard"
    case negativeClassic = "negative-classic"
    case negativeNostalgic = "negative-nostalgic"
    case cinema
    case bleach
    case monochrome
    case monochromeYellow = "monochrome-yellow"
    case monochromeRed = "monochrome-red"
    case monochromeGreen = "monochrome-green"
    case sepia

    public var name: String {
        switch self {
        case .standard: "Standard"
        case .vividSlide: "Vivid Slide"
        case .softSlide: "Soft Slide"
        case .chrome: "Chrome"
        case .negativeHigh: "Negative High"
        case .negativeStandard: "Negative Standard"
        case .negativeClassic: "Classic Negative"
        case .negativeNostalgic: "Nostalgic Negative"
        case .cinema: "Cinema"
        case .bleach: "Bleach"
        case .monochrome: "Monochrome"
        case .monochromeYellow: "Monochrome + Yellow"
        case .monochromeRed: "Monochrome + Red"
        case .monochromeGreen: "Monochrome + Green"
        case .sepia: "Sepia"
        }
    }

    public var summary: String {
        switch self {
        case .standard: "Balanced slide-film color, the everyday default."
        case .vividSlide: "Saturated, contrasty slide film with deep blues and greens."
        case .softSlide: "Soft slide film: gentle contrast and flattering skin."
        case .chrome: "Muted, dense color with hard tone and cool, deep blues."
        case .negativeHigh: "Portrait negative with a little extra contrast."
        case .negativeStandard: "Soft portrait negative, low contrast and natural skin."
        case .negativeClassic: "Snapshot negative: hard shadows, cyan-green cast, magenta reds."
        case .negativeNostalgic: "Warm, amber-tinted highlights and softly faded color."
        case .cinema: "Motion-picture look: flat, very muted, teal-leaning shadows."
        case .bleach: "Bleach bypass: silvery, desaturated and contrasty."
        case .monochrome: "Fine, neutral black and white."
        case .monochromeYellow: "Black and white through a yellow filter: darker skies."
        case .monochromeRed: "Black and white through a red filter: dramatic skies, pale skin."
        case .monochromeGreen: "Black and white through a green filter: lighter foliage, fuller skin."
        case .sepia: "Warm brown-toned monochrome."
        }
    }

    public var isMonochrome: Bool {
        switch self {
        case .monochrome, .monochromeYellow, .monochromeRed, .monochromeGreen, .sepia: true
        default: false
        }
    }

    /// Where a card with this slot finds its look: a bundled LUT look, or a built-in.
    public var baseLook: BaseLookReference {
        if let package = BuiltInBaseLooks.package(slot: rawValue) {
            return package.reference
        }
        switch self {
        case .standard: return BuiltInBaseLook.color.reference
        case .vividSlide: return BuiltInBaseLook.vivid.reference
        case .softSlide, .negativeStandard, .negativeHigh: return BuiltInBaseLook.portrait.reference
        case .cinema, .bleach: return BuiltInBaseLook.neutral.reference
        case .monochrome, .monochromeYellow, .monochromeRed, .monochromeGreen, .sepia:
            return BuiltInBaseLook.monochrome.reference
        default: return BuiltInBaseLook.color.reference
        }
    }
}

// MARK: - Resolving

public extension CameraRecipeCard {
    /// The mapping from card settings to Redlamp values, version 1. Each row is documented
    /// in docs/recipes/camera-card-mapping.md and pinned by tests.
    enum Mapping {
        /// Highlight tone: + brightens and hardens highlights.
        public static let highlightsPerStep = 12.0
        public static let whitesPerStep = 5.0
        /// Shadow tone: + deepens shadows.
        public static let shadowsPerStep = -12.0
        public static let blacksPerStep = -5.0
        public static let saturationPerColorStep = 7.0
        public static let chromeWeak = 45.0
        public static let chromeStrong = 85.0
        public static let shiftPerStep = 11.0
        public static let grainWeak = 22.0
        public static let grainStrong = 40.0
        public static let grainSmall = 20.0
        public static let grainLarge = 55.0
        public static let clarityPerStep = 8.0
        public static let sharpenPerStep = 10.0
        public static let noisePerStep = 3.0
        /// Monochrome toning: saturation of the global grading wheel per step.
        public static let toningPerStep = 3.0
    }

    func strength(_ value: Strength) -> Double {
        switch value {
        case .off: 0
        case .weak: Mapping.chromeWeak
        case .strong: Mapping.chromeStrong
        }
    }

    /// The Redlamp values the card stands for.
    func resolvedSettings() -> RecipeSettings {
        let card = clamped
        var values: [ParameterID: Double] = [:]
        func set(_ parameter: ParameterID, _ value: Double) {
            let clamped = parameter.spec.clamp(value)
            if abs(clamped - parameter.spec.defaultValue) > 1e-9 {
                values[parameter] = clamped
            }
        }
        set(.exposure, card.exposure)
        set(.highlights, card.highlight * Mapping.highlightsPerStep)
        set(.whites, card.highlight * Mapping.whitesPerStep)
        set(.shadows, card.shadow * Mapping.shadowsPerStep)
        set(.blacks, card.shadow * Mapping.blacksPerStep)
        set(.dynamicRange, card.dynamicRange.percent)
        set(.saturation, Double(card.color) * Mapping.saturationPerColorStep)
        set(.colorChrome, strength(card.colorChrome))
        set(.colorChromeBlue, strength(card.chromeFxBlue))
        set(.wbShiftRed, Double(card.whiteBalance.shiftRed) * Mapping.shiftPerStep)
        set(.wbShiftBlue, Double(card.whiteBalance.shiftBlue) * Mapping.shiftPerStep)
        switch card.grain.strength {
        case .off: break
        case .weak, .strong:
            set(.grainAmount, card.grain.strength == .weak ? Mapping.grainWeak : Mapping.grainStrong)
            set(.grainSize, card.grain.size == .small ? Mapping.grainSmall : Mapping.grainLarge)
            set(.grainRoughness, card.grain.strength == .strong ? 60 : 50)
        }
        set(.clarity, Double(card.clarity) * Mapping.clarityPerStep)
        set(.sharpenAmount, 40 + Double(card.sharpness) * Mapping.sharpenPerStep)
        set(.noiseLuminance, Double(card.noiseReduction + 4) * Mapping.noisePerStep)

        let slot = card.slot ?? .standard
        if slot.isMonochrome {
            var a = Double(card.monochromeWarmCool)
            var b = Double(card.monochromeMagentaGreen)
            if slot == .sepia {
                a += 6
                b += 1
            }
            if a != 0 || b != 0 {
                // Warm is hue 45 on the grading wheel, magenta 330.
                let x = a * cos(45 * .pi / 180) + b * cos(330 * .pi / 180)
                let y = a * sin(45 * .pi / 180) + b * sin(330 * .pi / 180)
                var hue = atan2(y, x) * 180 / .pi
                if hue < 0 {
                    hue += 360
                }
                set(.gradeGlobalHue, hue.rounded())
                set(.gradeGlobalSaturation, ((x * x + y * y).squareRoot() * Mapping.toningPerStep).rounded())
            }
        }

        var whiteBalanceMode: WhiteBalanceMode = .auto
        switch card.whiteBalance.mode.lowercased() {
        case "kelvin", "custom":
            whiteBalanceMode = .custom
            set(.temperature, card.whiteBalance.kelvin ?? 5500)
        case "asshot", "as-shot": whiteBalanceMode = .asShot
        case "daylight", "fine", "sunny": whiteBalanceMode = .daylight
        case "cloudy", "shade": whiteBalanceMode = card.whiteBalance.mode.lowercased() == "shade" ? .shade : .cloudy
        case "tungsten", "incandescent": whiteBalanceMode = .tungsten
        case "fluorescent": whiteBalanceMode = .fluorescent
        case "flash": whiteBalanceMode = .flash
        default: whiteBalanceMode = .auto
        }
        return RecipeSettings(
            values: values,
            treatment: slot.isMonochrome ? .blackAndWhite : .color,
            whiteBalanceMode: whiteBalanceMode,
        )
    }

    /// Everything a card controls. Its settings replace the photo's in all of these.
    static let includes: Set<RecipeSettingGroup> = [
        .treatment, .baseLook, .whiteBalance, .tone, .presence, .colorChrome, .effects, .detail, .colorGrading,
    ]

    /// A recipe built from the card, keeping the card as its source.
    func recipe(
        id: String,
        name: String,
        group: String = "Camera Recipes",
        summary: String? = nil,
        tags: [String] = [],
    ) -> Recipe {
        let card = clamped
        let slot = card.slot ?? .standard
        return Recipe(
            id: id,
            name: name,
            group: group,
            summary: summary,
            tags: tags + ["camera-card", slot.rawValue],
            includes: Self.includes,
            settings: card.resolvedSettings(),
            baseLook: slot.baseLook,
            source: .cameraCard(card, mappingVersion: Self.mappingVersion),
            lintWaivers: slot.isMonochrome ? ["neutral-axis", "skin-hue"] : [],
        )
    }
}

public extension Recipe {
    /// Re-resolves a recipe from its camera card after the card was edited.
    func updatingCard(_ card: CameraRecipeCard) -> Recipe {
        var updated = card.recipe(
            id: id,
            name: name,
            group: group,
            summary: summary,
            tags: tags.filter { $0 != "camera-card" && FilmSlot(rawValue: $0) == nil },
        )
        updated.version = version
        updated.author = author
        updated.license = license
        updated.created = created
        return updated
    }

    var cameraCard: CameraRecipeCard? {
        if case let .cameraCard(card, _) = source {
            return card
        }
        return nil
    }
}
