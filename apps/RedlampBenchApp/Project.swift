import ProjectDescription
import ProjectDescriptionHelpers

/// Redlamp Bench (ARC-12): an iPhone app for the owner's hand-off tasks and look references,
/// installed from Xcode (DEC-53). It pulls tasks from the Recipe Lab's hub, and a share
/// extension files what other apps export back into them.
let appGroup = "group.\(redlampBundlePrefix).bench"
let entitlements: Entitlements = .dictionary(["com.apple.security.application-groups": .array([.string(appGroup)])])
let signing: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Apple Development",
    "TARGETED_DEVICE_FAMILY": "1",
]

let project = Project(
    name: "RedlampBenchApp",
    settings: .settings(
        base: redlampBaseSettings,
        configurations: [
            .debug(name: .debug, xcconfig: .relativeToRoot("Version.xcconfig")),
            .release(name: .release, xcconfig: .relativeToRoot("Version.xcconfig")),
        ],
    ),
    targets: [
        .target(
            name: "RedlampBenchApp",
            destinations: [.iPhone],
            product: .app,
            bundleId: "\(redlampBundlePrefix).bench",
            deploymentTargets: .iOS(redlampIOSVersion),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Redlamp Bench",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "UILaunchScreen": [:],
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
                "NSLocalNetworkUsageDescription": "Redlamp Bench fetches tasks from the Recipe Lab on your Mac and sends them back.",
                "NSBonjourServices": ["_redlamp-bench._tcp"],
                "NSPhotoLibraryAddUsageDescription": "Saves a task's photos to your library, for apps that only open photos from it.",
                // The hub is plain HTTP on the local network.
                "NSAppTransportSecurity": ["NSAllowsLocalNetworking": true],
                "BenchAppGroup": .string(appGroup),
                "UTExportedTypeDeclarations": [
                    [
                        "UTTypeIdentifier": "app.redlamp.bench-task",
                        "UTTypeDescription": "Redlamp Bench Task",
                        "UTTypeConformsTo": ["public.data"],
                        "UTTypeTagSpecification": ["public.filename-extension": ["redtask"]],
                    ],
                ],
            ]),
            sources: ["Sources/**", "Shared/**"],
            resources: [.glob(pattern: .relativeToRoot("apps/RedlampMac/Resources/AppIcon.icon"))],
            entitlements: entitlements,
            dependencies: [
                Module.bench.dependency,
                .target(name: "RedlampBenchShare"),
            ],
            settings: .settings(base: signing.merging([
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                // Controls follow the system accent; the app ships no accent color.
                "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
            ]) { $1 }),
        ),
        .target(
            name: "RedlampBenchShare",
            destinations: [.iPhone],
            product: .appExtension,
            bundleId: "\(redlampBundlePrefix).bench.share",
            deploymentTargets: .iOS(redlampIOSVersion),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Redlamp Bench",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "NSAppTransportSecurity": ["NSAllowsLocalNetworking": true],
                "BenchAppGroup": .string(appGroup),
                "NSExtension": [
                    "NSExtensionPointIdentifier": "com.apple.share-services",
                    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).ShareViewController",
                    "NSExtensionAttributes": [
                        "NSExtensionActivationRule": [
                            "NSExtensionActivationSupportsImageWithMaxCount": 20,
                            "NSExtensionActivationSupportsFileWithMaxCount": 20,
                        ],
                    ],
                ],
            ]),
            sources: ["ShareExtension/**", "Shared/**"],
            entitlements: entitlements,
            dependencies: [Module.bench.dependency],
            settings: .settings(base: signing),
        ),
    ],
)
