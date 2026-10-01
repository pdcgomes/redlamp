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
    /// The print stock; nil scans a negative or projects a slide.
    public var print: String?
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
            "portra-400", "Portra 400", "Warm, gentle colour negative, as a Frontier scan renders it",
            maker: "Kodak", format: "Colour negative · ISO 400", icon: FilmIcon(
                .canister,
                body: .init(0.96, 0.93, 0.85),
                band: .init(0.93, 0.6, 0.16),
                text: .init(0.28, 0.16, 0.07),
                label: "400",
            ),
            film: "kodak-portra-400", scanner: .frontier,
            grain: (20, 30, 35), halation: (8, 40),
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
            film: "kodak-ektar-100", scanner: .frontier,
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
            film: "kodak-gold-200", scanner: .frontier,
            grain: (23, 30, 40), halation: (9, 40),
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
            film: "fuji-superia-xtra-400", scanner: .frontier,
            grain: (24, 32, 45), halation: (8, 40),
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
            "vision3-500t-2383", "Vision3 500T · 2383", "Cinema negative printed on 2383 print film",
            maker: "Kodak", format: "Cinema negative on print film · ISO 500", icon: FilmIcon(
                .reel,
                body: .init(0.16, 0.2, 0.31),
                band: .init(0.85, 0.63, 0.25),
                text: .init(0.12, 0.1, 0.08),
                label: "500T",
            ),
            film: "kodak-vision3-500t", print: "kodak-2383", flare: 0.004,
            grain: (24, 32, 40), halation: (14, 45), bloom: (6, 50),
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
            guard let package = BuiltInBaseLooks.package(id: look.baseLookID, version: bundledVersion)
            else { return nil }
            return BuiltInRecipes.make(
                "stock/\(look.id)", look.name, group: "Film Stocks", summary: look.summary, tags: ["film"],
                values: look.effects, treatment: look.isMonochrome ? .blackAndWhite : nil, baseLook: package.reference,
            )
        }
    }

    /// The bundled tables' version. Published looks never change: a new design is a new version.
    public static let bundledVersion = 1

    /// The table size the bundled looks ship at (0.5 EV a step across the scene range).
    public static let bundledTableSize = 33

    private static func look(
        _ id: String,
        _ name: String,
        _ summary: String,
        maker: String,
        format: String,
        icon: FilmIcon,
        monochrome: Bool = false,
        film: String,
        print: String? = nil,
        scanner: ScannerProfile = .neutral,
        scanContrast: Double = 1,
        flare: Double = 0,
        displayGrey: Double? = nil,
        grain: (amount: Double, size: Double, color: Double),
        roughness: Double = 50,
        halation: (amount: Double, size: Double),
        bloom: (amount: Double, size: Double)? = nil,
    ) -> FilmLookDefinition {
        var parameters = FilmLookParameters()
        parameters.scanner = scanner
        parameters.scanContrast = scanContrast
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
            film: film, print: print, parameters: parameters, effects: effects,
        )
    }
}

public extension FilmLooks {
    /// The look's bundled Base Look package, built from the datasheets.
    static func bundledPackage(for look: FilmLookDefinition, data directory: URL?) throws -> BaseLookPackage {
        let table = try table(
            film: look.film, print: look.print, parameters: look.parameters, size: FilmLookCatalog.bundledTableSize,
            data: directory,
        )
        return BaseLookPackage(
            id: look.baseLookID, version: FilmLookCatalog.bundledVersion, name: look.name,
            summary: "\(look.summary). Built from \(look.maker)'s published datasheet.", parameters: .identity,
            table: table,
        )
    }

    /// The recipe for a catalogue look: its Base Look table and its Effects settings.
    static func recipe(
        for look: FilmLookDefinition, size: Int = 33, data directory: URL?,
    ) throws -> Recipe {
        let table = try table(
            film: look.film, print: look.print, parameters: look.parameters, size: size, data: directory,
        )
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
