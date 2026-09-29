import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.document.name,
    targets: [
        .frameworkTarget(module: .document),
        .frameworkTestTarget(module: .document),
    ],
)
