import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.library.name,
    targets: [
        .frameworkTarget(module: .library, extraDependencies: sqliteDependencies),
        .frameworkTestTarget(module: .library),
    ],
)
