import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.color.name,
    targets: [
        .frameworkTarget(module: .color),
        .frameworkTestTarget(module: .color),
    ],
)
