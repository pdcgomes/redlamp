import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.engine.name,
    targets: [
        .frameworkTarget(module: .engine),
        .frameworkTestTarget(module: .engine),
    ],
)
