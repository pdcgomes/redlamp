import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.ui.name,
    targets: [
        .frameworkTarget(module: .ui),
        .frameworkTestTarget(module: .ui),
    ],
)
