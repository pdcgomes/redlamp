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
                // The commit a release is built from, named in feedback reports; empty in builds
                // from source.
                "RedlampCommit": "$(REDLAMP_COMMIT)",
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
                Module.services.dependency,
                Module.document.dependency,
                Module.library.dependency,
                Module.recipes.dependency,
                Module.canvas.dependency,
                Module.design.dependency,
                Module.ui.dependency,
                Module.automation.dependency,
                Module.generative.dependency,
                // The CLI in Contents/Helpers loads its frameworks from the app's, so the app
                // embeds every framework it links, even those the app itself doesn't call.
                Module.bench.dependency,
                .external(name: "Sparkle"),
                .target(name: "RedlampDecoder"),
            ],
            // Signed with the same team as the frameworks: with the hardened runtime,
            // library validation refuses frameworks from a different team (or ad-hoc).
            settings: .settings(
                base: [
                    "CODE_SIGN_STYLE": "Automatic",
                    "CODE_SIGN_IDENTITY": "Apple Development",
                    "REDLAMP_UPDATE_FEED": "",
                    "REDLAMP_COMMIT": "",
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
        // Decodes photos in a sandboxed process with no file access; the app sends each file's
        // bytes. Embedded in Contents/XPCServices; it loads the two frameworks it uses from the
        // app's. Tuist embeds every framework a target depends on, so they're linked by flag,
        // and the schemes' implicit dependencies build them first.
        .target(
            name: "RedlampDecoder",
            destinations: [.mac],
            product: .xpc,
            bundleId: "\(redlampBundlePrefix).mac.decoder",
            deploymentTargets: .macOS(redlampMacOSVersion),
            infoPlist: .extendingDefault(with: [
                "CFBundleName": "RedlampDecoder",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "XPCService": ["ServiceType": "Application"],
            ]),
            sources: ["DecoderService/**/*.swift"],
            entitlements: .file(path: "DecoderService/RedlampDecoder.entitlements"),
            settings: .settings(
                base: [
                    "CODE_SIGN_STYLE": "Automatic",
                    "CODE_SIGN_IDENTITY": "Apple Development",
                    "OTHER_LDFLAGS": "$(inherited) -framework RedlampEngineAPI -framework RedlampServices",
                    // Redlamp.app/Contents/XPCServices/RedlampDecoder.xpc/Contents/MacOS to the app's
                    // Contents/Frameworks.
                    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../../../../Frameworks",
                ],
                configurations: [
                    .debug(name: .debug, settings: ["ENABLE_HARDENED_RUNTIME": "NO"]),
                    .release(name: .release, settings: ["ENABLE_HARDENED_RUNTIME": "YES"]),
                ],
            ),
        ),
    ],
)
