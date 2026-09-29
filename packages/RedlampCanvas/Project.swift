import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: Module.canvas.name,
    targets: [
        .frameworkTarget(module: .canvas),
    ],
)
