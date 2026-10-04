import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.generative.name,
    targets: [
        .frameworkTarget(
            module: .generative,
            extraDependencies: [.external(name: "MLX")],
        ),
        .frameworkTestTarget(module: .generative, dependencies: [.external(name: "MLX")]),
    ],
)
