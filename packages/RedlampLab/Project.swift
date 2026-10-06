import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.lab.name,
    targets: [
        .frameworkTarget(module: .lab),
        .frameworkTestTarget(module: .lab, dependencies: [Module.engine.dependency]),
    ],
)
