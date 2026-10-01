import Foundation
import RedlampEngineAPI

/// The recipes that ship with Redlamp.
///
/// Every bundled recipe has golden renders (see the RedlampRecipes tests); changing one's
/// values means publishing it as a new version, never editing a published one.
public enum BuiltInRecipes {
    public static let author = RecipeAuthor(name: "Redlamp")
    public static let license = "CC0-1.0"

    public static var all: [Recipe] {
        StarterPack.recipes + FilmLookCatalog.bundledRecipes
    }

    public static func recipe(id: String) -> Recipe? {
        all.first { $0.id == id }
    }

    /// A bundled recipe from its settings. Groups are inferred from what it sets, plus
    /// `extraIncludes` for groups it deliberately resets.
    static func make(
        _ slug: String,
        _ name: String,
        group: String,
        summary: String,
        tags: [String] = [],
        values: [ParameterID: Double],
        treatment: Treatment? = nil,
        baseLook: BaseLookReference? = nil,
        pointCurve: [CurvePoint]? = nil,
        whiteBalanceMode: WhiteBalanceMode? = nil,
        extraIncludes: Set<RecipeSettingGroup> = [],
        lintWaivers: Set<String> = [],
        version: Int = 1,
    ) -> Recipe {
        let settings = RecipeSettings(
            values: values, treatment: treatment, whiteBalanceMode: whiteBalanceMode, pointCurve: pointCurve,
        )
        var includes = RecipeSettings.inferredIncludes(settings).union(extraIncludes)
        if baseLook != nil {
            includes.insert(.baseLook)
        }
        let monochrome = treatment == .blackAndWhite
        return Recipe(
            id: "\(RecipeNamespace.bundled)/\(slug)",
            version: version,
            name: name,
            group: group,
            summary: summary,
            author: author,
            license: license,
            tags: tags,
            includes: includes,
            settings: settings,
            baseLook: baseLook,
            lintWaivers: lintWaivers.union(monochrome ? ["neutral-axis", "skin-hue"] : []),
        )
    }

    static func card(
        _ slug: String,
        _ name: String,
        summary: String,
        tags: [String] = [],
        version: Int = 1,
        _ card: CameraRecipeCard,
    ) -> Recipe {
        let group = card.slot?.isMonochrome == true ? "Black & White" : "Camera Recipes"
        var recipe = card.recipe(
            id: "\(RecipeNamespace.bundled)/\(slug)",
            name: name,
            group: group,
            summary: summary,
            tags: tags,
        )
        recipe.version = version
        recipe.author = author
        recipe.license = license
        return recipe
    }
}
