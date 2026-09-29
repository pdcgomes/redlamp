import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.engineAPI.name,
    targets: [
        .frameworkTarget(module: .engineAPI),
        .frameworkTestTarget(module: .engineAPI),
    ],
)
