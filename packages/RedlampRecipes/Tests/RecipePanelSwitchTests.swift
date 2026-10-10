import Foundation
import RedlampEngineAPI
import RedlampRecipes
import Testing

/// Recipes and panel switches (UX-30): a recipe looks the same on every photo, whichever of its
/// source's or target's panels are off.
struct RecipePanelSwitchTests {
    @Test func `a recipe captures a switched-off panel's settings as they render`() {
        var edit = EditRecipe()
        edit[.sharpenAmount] = 90
        edit[.grainAmount] = 40
        edit.panelsOff = [.detail, .effects]
        let recipe = Recipe.capture(edit, name: "Off", includes: [.detail, .effects])
        #expect(recipe.settings[.sharpenAmount] == 0)
        #expect(recipe.settings[.noiseColor] == 0)
        #expect(recipe.settings[.grainAmount] == 0)
        #expect(recipe.edit().parametersChanged(from: edit.rendered).isEmpty, "it renders as the edit did")
    }

    @Test func `applying a recipe turns on a panel whose settings it gives an effect`() {
        let recipe = Recipe(
            id: "local/grain", name: "Grain", group: "Tests", includes: [.effects, .detail],
            settings: RecipeSettings(values: [.grainAmount: 30, .sharpenAmount: 0, .noiseColor: 0]),
        )
        var edit = EditRecipe()
        edit[.grainAmount] = 30
        edit[.sharpenAmount] = 0
        edit[.noiseColor] = 0
        edit.panelsOff = [.effects, .detail, .colorGrading]
        let applied = recipe.apply(to: edit)
        #expect(applied.isOn(.effects), "the recipe's grain must show, though the value didn't change")
        #expect(!applied.isOn(.detail), "Detail at rest looks the same off, and the recipe changed none of it")
        #expect(!applied.isOn(.colorGrading), "the recipe doesn't control Color Grading")
        #expect(applied.rendered[.grainAmount] == 30)
    }

    @Test func `applying a recipe with a point curve turns the Tone Curve on`() {
        let curve = [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 1, y: 1)]
        let recipe = Recipe(
            id: "local/curve", name: "Curve", group: "Tests", includes: [.toneCurve],
            settings: RecipeSettings(pointCurve: curve),
        )
        var edit = EditRecipe()
        edit.pointCurve = curve
        edit.panelsOff = [.toneCurve]
        #expect(recipe.apply(to: edit).isOn(.toneCurve))
    }
}
