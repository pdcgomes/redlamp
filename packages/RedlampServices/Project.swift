import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.services.name,
    targets: [
        .frameworkTarget(module: .services, extraDependencies: libRawDependencies),
        .frameworkTestTarget(module: .services),
    ],
)
