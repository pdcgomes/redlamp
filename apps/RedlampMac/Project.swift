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
                // Sparkle. Only `mise run release` sets the feed, and the app starts no updater
                // without one, so a build from source never offers to replace itself with an
                // older release. The key's private half is in the release Mac's keychain
                // (`generate_keys --account redlamp`).
                "SUFeedURL": "$(REDLAMP_UPDATE_FEED)",
                "SUPublicEDKey": "YeTg38oxVFZ0jsLrc0HxH5x7BaPT/IQuS+AsLq/s8Ig=",
                // Sidecars are packages (edit.json plus mask bitmaps), shown as one file.
                "UTExportedTypeDeclarations": [
                    [
                        "UTTypeIdentifier": "app.redlamp.edit",
                        "UTTypeDescription": "Redlamp Edit",
                        "UTTypeConformsTo": ["com.apple.package"],
                        "UTTypeTagSpecification": ["public.filename-extension": ["redlamp"]],
                    ],
                ],
            ]),
            sources: ["Sources/**"],
            resources: ["Resources/**"],
            dependencies: [
                Module.engineAPI.dependency,
                Module.engine.dependency,
                Module.document.dependency,
                Module.recipes.dependency,
                Module.canvas.dependency,
                Module.design.dependency,
                Module.ui.dependency,
                .external(name: "Sparkle"),
            ],
            // Signed with the same team as the frameworks: with the hardened runtime,
            // library validation refuses frameworks from a different team (or ad-hoc).
            settings: .settings(
                base: [
                    "CODE_SIGN_STYLE": "Automatic",
                    "CODE_SIGN_IDENTITY": "Apple Development",
                    "REDLAMP_UPDATE_FEED": "",
                    // Resources/AppIcon.icon; edit it with Icon Composer.
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    // Controls follow the user's system accent; the app ships no accent color.
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
                ],
                configurations: [
                    // Debug builds stay attachable by sample/Instruments for profiling.
                    .debug(name: .debug, settings: ["ENABLE_HARDENED_RUNTIME": "NO"]),
                    .release(name: .release, settings: ["ENABLE_HARDENED_RUNTIME": "YES"]),
                ],
            ),
        ),
    ],
)
