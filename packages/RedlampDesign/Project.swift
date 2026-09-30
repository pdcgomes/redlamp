import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.design.name,
    targets: [
        .frameworkTarget(module: .design),
    ],
)
