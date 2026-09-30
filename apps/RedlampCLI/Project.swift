import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: "RedlampCLI",
    targets: [
        .target(
            name: "redlamp",
            destinations: [.mac],
            product: .commandLineTool,
            bundleId: "\(redlampBundlePrefix).cli",
            deploymentTargets: .macOS(redlampMacOSVersion),
            sources: ["Sources/**"],
            dependencies: [
                Module.engineAPI.dependency,
                Module.engine.dependency,
                Module.recipes.dependency,
            ],
            settings: .settings(base: redlampBaseSettings.merging([
                // Frameworks sit next to the tool in the build products directory.
                "LD_RUNPATH_SEARCH_PATHS": ["@executable_path", "@executable_path/../Frameworks"],
            ]) { $1 }),
        ),
    ],
)
