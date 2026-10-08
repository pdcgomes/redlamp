import ProjectDescription
import ProjectDescriptionHelpers

/// A development app for building and reviewing Redlamp's UI components in isolation:
/// every component in every state, pixel-parity checks against the SwiftUI originals, and
/// performance scenes. It hosts the real frameworks, not copies of them.
let project = Project(
    name: "RedlampHarness",
    settings: .settings(
        base: redlampBaseSettings,
        configurations: [
            .debug(name: .debug, xcconfig: .relativeToRoot("Version.xcconfig")),
            .release(name: .release, xcconfig: .relativeToRoot("Version.xcconfig")),
        ],
    ),
    targets: [
        .target(
            name: "RedlampHarness",
            destinations: [.mac],
            product: .app,
            bundleId: "\(redlampBundlePrefix).harness",
            deploymentTargets: .macOS(redlampMacOSVersion),
            infoPlist: .extendingDefault(with: [
                "CFBundleName": "Redlamp Harness",
                "CFBundleDisplayName": "Redlamp Harness",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "LSApplicationCategoryType": "public.app-category.developer-tools",
                // The Recipe Lab's bench hub (ARC-13): the iPhone app finds it over Bonjour.
                "NSLocalNetworkUsageDescription": "Redlamp Bench on your iPhone sends tasks and look references to the Recipe Lab.",
                "NSBonjourServices": ["_redlamp-bench._tcp", "_redlamp-phone._tcp"],
                // A bench task as one file, from the iPhone app by AirDrop when the network can't carry it.
                "UTExportedTypeDeclarations": [
                    [
                        "UTTypeIdentifier": "app.redlamp.bench-task",
                        "UTTypeDescription": "Redlamp Bench Task",
                        "UTTypeConformsTo": ["public.data"],
                        "UTTypeTagSpecification": ["public.filename-extension": ["redtask"]],
                    ],
                ],
                "CFBundleDocumentTypes": [
                    [
                        "CFBundleTypeName": "Redlamp Bench Task",
                        "CFBundleTypeRole": "Viewer",
                        "LSHandlerRank": "Owner",
                        "LSItemContentTypes": ["app.redlamp.bench-task"],
                    ],
                ],
            ]),
            sources: ["Sources/**"],
            resources: [.glob(pattern: .relativeToRoot("apps/RedlampMac/Resources/AppIcon.icon"))],
            dependencies: [
                Module.engineAPI.dependency,
                Module.engine.dependency,
                Module.document.dependency,
                Module.recipes.dependency,
                Module.canvas.dependency,
                Module.design.dependency,
                Module.ui.dependency,
                Module.lab.dependency,
                Module.bench.dependency,
            ],
            settings: .settings(
                base: [
                    "CODE_SIGN_STYLE": "Automatic",
                    "CODE_SIGN_IDENTITY": "Apple Development",
                    "ENABLE_HARDENED_RUNTIME": "NO",
                    // Shares the app's icon; edit apps/RedlampMac/Resources/AppIcon.icon.
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                ],
                // Controls follow the user's system accent; the harness ships no accent color.
                defaultSettings: .recommended(excluding: ["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"]),
            ),
        ),
    ],
)
