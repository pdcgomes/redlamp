import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.bench.name,
    targets: [
        .frameworkTarget(module: .bench, resources: ["Resources/**"]),
        .frameworkTestTarget(module: .bench),
    ],
)
