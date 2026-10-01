import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.masking.name,
    targets: [
        .frameworkTarget(module: .masking, resources: ["Resources/**"]),
        .frameworkTestTarget(module: .masking),
    ],
)
