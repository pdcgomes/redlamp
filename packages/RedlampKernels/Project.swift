import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.kernels.name,
    targets: [
        .frameworkTarget(module: .kernels),
    ],
)
