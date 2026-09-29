import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: "RedlampMac",
    settings: .settings(
        base: redlampBaseSettings,
        configurations: [
            .debug(name: .debug, xcconfig: .relativeToRoot("Version.xcconfig")),
            .release(name: .release, xcconfig: .relativeToRoot("Version.xcconfig")),
        ],
    ),
    targets: [
        .target(
            name: "Redlamp",
            destinations: [.mac],
            product: .app,
            bundleId: "\(redlampBundlePrefix).mac",
            deploymentTargets: .macOS(redlampMacOSVersion),
            infoPlist: .extendingDefault(with: [
                "CFBundleName": "Redlamp",
                "CFBundleDisplayName": "Redlamp",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "LSApplicationCategoryType": "public.app-category.photography",
                "NSHumanReadableCopyright": "Redlamp contributors. MPL-2.0.",
            ]),
            sources: ["Sources/**"],
            dependencies: [
                Module.engineAPI.dependency,
                Module.engine.dependency,
                Module.document.dependency,
                Module.canvas.dependency,
                Module.ui.dependency,
            ],
            settings: .settings(base: [
                "CODE_SIGN_IDENTITY": "-",
                "CODE_SIGN_STYLE": "Manual",
                "ENABLE_HARDENED_RUNTIME": "YES",
            ]),
        ),
    ],
)
