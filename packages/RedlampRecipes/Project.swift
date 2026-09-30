import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.recipes.name,
    targets: [
        .frameworkTarget(module: .recipes, resources: ["Resources/**"]),
        // Golden renders and chart lint need a real engine; only the tests link it.
        .frameworkTestTarget(module: .recipes, dependencies: [Module.engine.dependency]),
    ],
)
