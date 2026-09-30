import Foundation
import RedlampEngine
import RedlampUI
import SwiftUI

extension HarnessScene {
    static var recipeLab: HarnessScene {
        var scene = HarnessScene(
            id: "recipe-lab",
            title: "Recipe Lab",
            symbol: "wand.and.stars",
            synopsis: "Every recipe, Base Look and LUT on the look-dev set and the lint chart: "
                + "compare, inspect, lint, create, and review agent runs",
            section: .recipes,
        ) {
            RecipeLabView(model: HarnessLab.model)
        }
        scene.fillsStage = true
        return scene
    }
}

/// The Lab renders on its own engine, so its gallery never disturbs the editor's photo; its
/// creator edits through the shared harness editor.
@MainActor
enum HarnessLab {
    static let model: RecipeLabModel = {
        guard let engine = try? RedlampEngine() else {
            fatalError("The harness needs a Metal GPU")
        }
        let model = RecipeLabModel(engine: engine, editor: HarnessEditor.model, root: repositoryRoot)
        // `--lab-select <recipe id>` preselects a recipe, for scripted screenshots.
        if let id = HarnessLaunch.value(after: "--lab-select") {
            model.selectedID = model.allItems.first { $0.recipe.id == id }?.id
        }
        return model
    }()

    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
