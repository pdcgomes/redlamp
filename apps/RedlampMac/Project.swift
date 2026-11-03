import ProjectDescription
import ProjectDescriptionHelpers

/// What both builds' Info.plists hold. A dictionary, not Tuist's default extended, whose
/// `NSMainStoryboardFile` names a storyboard the bundle doesn't have.
let appInfoPlist: [String: Plist.Value] = [
    "CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)",
    "CFBundleExecutable": "$(EXECUTABLE_NAME)",
    "CFBundleIconFile": "",
    "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundlePackageType": "APPL",
    "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
    "NSPrincipalClass": "NSApplication",
    "CFBundleName": "Redlamp",
    "CFBundleDisplayName": "Redlamp",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "LSApplicationCategoryType": "public.app-category.photography",
    "NSHumanReadableCopyright": "Redlamp contributors. MPL-2.0.",
    // The commit a release is built from, named in feedback reports; empty in builds
    // from source.
    "RedlampCommit": "$(REDLAMP_COMMIT)",
    // Which build this is (`AppDistribution`): `developer-id` in the direct download as
    // `mise run release` builds it, `app-store` in the App Store's, empty in builds from source.
    "RedlampDistribution": "$(REDLAMP_DISTRIBUTION)",
    // Add Albums from Apple Photos (LIB-54, LIB-62) reads Photos, and only reads it (DEC-106).
    "NSPhotoLibraryUsageDescription":
        "Redlamp shows or copies the photos in the albums you choose. It never changes your Photos library.",
    // Sidecars are packages (edit.json plus mask bitmaps), shown as one file.
    "UTExportedTypeDeclarations": [
        [
            "UTTypeIdentifier": "app.redlamp.edit",
            "UTTypeDescription": "Redlamp Edit",
            "UTTypeConformsTo": ["com.apple.package"],
            "UTTypeTagSpecification": ["public.filename-extension": ["redlamp"]],
        ],
    ],
]

/// The direct download's own keys.
let directInfoPlist: [String: Plist.Value] = [
    // Sparkle. Only `mise run release` sets the feed, and the app starts no updater
    // without one, so a build from source never offers to replace itself with an
    // older release. The key's private half is in the release Mac's keychain
    // (`generate_keys --account redlamp`).
    "SUFeedURL": "$(REDLAMP_UPDATE_FEED)",
    "SUPublicEDKey": "YeTg38oxVFZ0jsLrc0HxH5x7BaPT/IQuS+AsLq/s8Ig=",
    // The firmware model's hosted file and its outer key (TON-50), from
    // Version.xcconfig: empty in builds from source, set in releases from the kept
    // Firmware.local.xcconfig. Not in the target's settings, which would hide it.
    "RedlampFirmwareTablesURL": "$(REDLAMP_FIRMWARE_TABLES_URL)",
    "RedlampFirmwareKeyURL": "$(REDLAMP_FIRMWARE_KEY_URL)",
]

/// The App Store build's own keys. It has no updater and no firmware model (DEC-89), and uses only
/// the encryption macOS provides (HTTPS, CryptoKit's hashes), which is exempt.
let appStoreInfoPlist: [String: Plist.Value] = [
    "ITSAppUsesNonExemptEncryption": false,
]

/// App Store Connect takes a version of three integers (DEC-92): in the AppStore configuration the
/// bundle's `CFBundleShortVersionString` is `MARKETING_VERSION` without its stage, `0.3.1-alpha` as
/// `0.3.1`. After the Info.plist is written and before the bundle is signed.
let numericVersion: TargetScript = .post(
    script: """
    [ "$CONFIGURATION" = AppStore ] || exit 0
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${MARKETING_VERSION%%-*}" \
        "$TARGET_BUILD_DIR/$INFOPLIST_PATH"
    """,
    name: "Numeric version",
    inputPaths: ["$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"],
    basedOnDependencyAnalysis: false,
)

/// The frameworks both builds link.
let appDependencies: [TargetDependency] = [
    Module.engineAPI.dependency,
    Module.engine.dependency,
    Module.services.dependency,
    Module.document.dependency,
    Module.library.dependency,
    Module.recipes.dependency,
    Module.canvas.dependency,
    Module.design.dependency,
    Module.ui.dependency,
    Module.generative.dependency,
    .target(name: "RedlampDecoder"),
]

let appSettings: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Apple Development",
    "REDLAMP_COMMIT": "",
    "REDLAMP_DISTRIBUTION": "",
    // Resources/AppIcon.icon; edit it with Icon Composer.
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    // Controls follow the user's system accent; the app ships no accent color.
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
]

let project = Project(
    name: "RedlampMac",
    settings: .settings(
        base: redlampBaseSettings,
        configurations: redlampConfigurations(xcconfig: .relativeToRoot("Version.xcconfig")),
    ),
    targets: [
        .target(
            name: "Redlamp",
            destinations: [.mac],
            product: .app,
            bundleId: "\(redlampBundlePrefix).mac",
            deploymentTargets: .macOS(redlampMacOSVersion),
            infoPlist: .dictionary(appInfoPlist.merging(directInfoPlist) { $1 }),
            sources: ["Sources/**"],
            resources: ["Resources/**"],
            // With the hardened runtime, reading Photos needs its entitlement (LIB-54).
            entitlements: .file(path: "Redlamp.entitlements"),
            dependencies: appDependencies + [
                Module.automation.dependency,
                .external(name: "Sparkle"),
            ],
            // Signed with the same team as the frameworks: with the hardened runtime,
            // library validation refuses frameworks from a different team (or ad-hoc).
            settings: .settings(
                base: appSettings.merging(["REDLAMP_UPDATE_FEED": ""]) { $1 },
                configurations: [
                    // Debug builds stay attachable by sample/Instruments for profiling.
                    .debug(name: .debug, settings: ["ENABLE_HARDENED_RUNTIME": "NO"]),
                    .release(name: .release, settings: ["ENABLE_HARDENED_RUNTIME": "YES"]),
                    .release(name: .appStore, settings: ["ENABLE_HARDENED_RUNTIME": "YES"]),
                ],
            ),
        ),
        // The Mac App Store build (ARC-22), archived by the Redlamp App Store scheme in the AppStore
        // configuration. Without Sparkle, the regression suite's driver, the bench, the CLI or the
        // firmware model (DEC-89, DEC-90), under the direct download's bundle ID (DEC-91).
        .target(
            name: "RedlampAppStore",
            destinations: [.mac],
            product: .app,
            productName: "Redlamp",
            bundleId: "\(redlampBundlePrefix).mac",
            deploymentTargets: .macOS(redlampMacOSVersion),
            infoPlist: .dictionary(appInfoPlist.merging(appStoreInfoPlist) { $1 }),
            sources: [.glob("Sources/**", excluding: ["Sources/Updates.swift"]), "AppStore/**/*.swift"],
            // Sparkle's licence goes only where Sparkle does, as Help › Acknowledgements lists it.
            resources: [.glob(pattern: "Resources/**", excluding: ["Resources/Acknowledgements/Sparkle-MIT.txt"])],
            entitlements: .file(path: "AppStore/Redlamp.entitlements"),
            scripts: [numericVersion],
            dependencies: appDependencies,
            settings: .settings(
                base: appSettings.merging([
                    "REDLAMP_DISTRIBUTION": "app-store",
                    // The app's own code is the App Store build's in every configuration, since it
                    // never links the regression suite's driver.
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) REDLAMP_APP_STORE",
                ]) { $1 },
                // Debug and Release build it beside the direct download, whose Redlamp.app it
                // would overwrite.
                configurations: [
                    .debug(
                        name: .debug,
                        settings: ["ENABLE_HARDENED_RUNTIME": "NO", "PRODUCT_NAME": "Redlamp App Store"],
                    ),
                    .release(
                        name: .release, settings: [
                            "ENABLE_HARDENED_RUNTIME": "YES",
                            "PRODUCT_NAME": "Redlamp App Store",
                        ],
                    ),
                    .release(name: .appStore, settings: ["ENABLE_HARDENED_RUNTIME": "YES"]),
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
            scripts: [numericVersion],
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
                    .release(name: .appStore, settings: ["ENABLE_HARDENED_RUNTIME": "YES"]),
                ],
            ),
        ),
    ],
    schemes: [
        .scheme(
            name: "Redlamp App Store",
            buildAction: .buildAction(targets: ["RedlampAppStore"]),
            runAction: .runAction(configuration: .appStore, executable: "RedlampAppStore"),
            archiveAction: .archiveAction(configuration: .appStore),
            profileAction: .profileAction(configuration: .appStore, executable: "RedlampAppStore"),
            analyzeAction: .analyzeAction(configuration: .appStore),
        ),
    ],
)
