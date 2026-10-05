import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.automation.name,
    targets: [
        .frameworkTarget(module: .automation),
        .frameworkTestTarget(module: .automation),
    ],
)
