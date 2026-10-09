import Foundation
import RedlampEngineAPI
import RedlampRecipes

public extension EditorModel {
    /// Applies a recipe. Its Amount stays adjustable until the edit changes some other way.
    func applyRecipe(_ recipe: Recipe, amount: Double = 100) {
        previewingRecipe = nil
        recipes.prepare(recipe)
        let base = recipe.id == recipeApplication?.recipe.id && recipeAmount != nil
            ? recipeApplication!.base
            : self.recipe
        recipeApplication = (recipe, base)
        let apply = { [self] in
            commit(
                anchored(recipe.apply(to: base, amount: amount, whiteBalance: resolveWhiteBalance)),
                .recipe,
                "Recipe",
            ) { _ in
                recipe.name
            }
        }
        if needsAutoWhiteBalance(recipe), autoWhiteBalance == nil, let visit = currentVisit {
            Task {
                let wb = await engine.autoWhiteBalance()
                guard currentVisit == visit else { return }
                autoWhiteBalance = wb
                apply()
            }
        } else {
            apply()
        }
    }

    /// Hover preview: renders a recipe without applying it.
    func previewRecipe(_ recipe: Recipe?) {
        guard previewingRecipe != recipe else { return }
        if let recipe {
            recipes.prepare(recipe)
            if needsAutoWhiteBalance(recipe), autoWhiteBalance == nil, let visit = currentVisit {
                Task {
                    let wb = await engine.autoWhiteBalance()
                    guard currentVisit == visit else { return }
                    autoWhiteBalance = wb
                    requestRender()
                }
            }
        }
        previewingRecipe = recipe
        requestRender()
    }

    /// The last applied recipe's Amount, while the edit is still exactly what it produced.
    /// Observes only `recipeApplication`, never the edit, so lists can read it without
    /// reloading on every slider event.
    var recipeAmount: Double? {
        guard let application = recipeApplication, let applied = unobservedRecipe.appliedRecipe,
              applied.id == application.recipe.id,
              anchored(application.recipe.apply(
                  to: application.base,
                  amount: applied.amount,
                  whiteBalance: resolveWhiteBalance,
              ))
              == unobservedRecipe
        else { return nil }
        return applied.amount
    }

    var recipeAmountTitle: String? {
        guard recipeAmount != nil else { return nil }
        return recipeApplication?.recipe.name
    }

    /// Re-applies the last recipe at another strength. During a drag (between `beginEdit`
    /// and `endEdit`) history records one step.
    func setRecipeAmount(_ amount: Double) {
        guard let application = recipeApplication else { return }
        let next = anchored(application.recipe.apply(
            to: application.base, amount: amount.rounded(), whiteBalance: resolveWhiteBalance,
        ))
        guard next != recipe else { return }
        if editStart == nil {
            commit(next, .recipe, "Recipe Amount", value: Self.recipeAmountText)
        } else {
            applyLive(next)
        }
    }

    /// The Base Look's strength, 0...200.
    func setBaseLookAmount(_ amount: Double) {
        var next = recipe
        next.baseLook = recipe.baseLook.withAmount(amount.rounded())
        guard next != recipe else { return }
        if editStart == nil {
            commit(next, .baseLook, "Base Look Amount", value: Self.baseLookAmountText)
        } else {
            applyLive(next)
        }
    }

    /// The Recipe Amount and Base Look Amount as history shows them.
    internal static func recipeAmountText(_ recipe: EditRecipe) -> String {
        recipe.appliedRecipe.map { "\(Int($0.amount.rounded()))" } ?? "–"
    }

    internal static func baseLookAmountText(_ recipe: EditRecipe) -> String {
        "\(Int(recipe.baseLook.amount.rounded()))"
    }

    /// The edit's Base Look isn't installed here, so the photo renders without it.
    var isBaseLookMissing: Bool {
        _ = recipes.revision
        return !recipes.isAvailable(baseLook)
    }

    /// Captures the current edit as a recipe in My Recipes.
    @discardableResult
    func saveRecipe(name: String, group: String = "My Recipes", includes: Set<RecipeSettingGroup>) -> Recipe? {
        let looks = recipes.package(for: recipe.baseLook).map { [$0] } ?? []
        let captured = Recipe.capture(recipe, name: name, group: group, includes: includes, embedding: looks)
        return recipes.save(captured)
    }

    internal func previewEdit(for recipe: Recipe) -> EditRecipe {
        anchored(recipe.apply(to: self.recipe, whiteBalance: resolveWhiteBalance))
    }

    internal func resolveWhiteBalance(_ mode: WhiteBalanceMode) -> WhiteBalanceValue? {
        switch mode {
        case .asShot: info?.asShotWhiteBalance
        case .auto: autoWhiteBalance
        case .custom: nil
        default: mode.presetValue
        }
    }

    private func needsAutoWhiteBalance(_ recipe: Recipe) -> Bool {
        recipe.includes.contains(.whiteBalance) && recipe.settings.whiteBalanceMode == .auto
    }
}
