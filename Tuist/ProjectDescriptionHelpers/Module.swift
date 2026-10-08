import ProjectDescription

/// The layered module graph for Redlamp.
///
/// `upstream` is the single source of truth for the dependency graph: a framework's
/// declared dependencies are derived from it, so a module cannot reach a layer it has
/// not been granted. The engine layers are platform-neutral (no AppKit, UIKit or
/// SwiftUI) — `scripts/check-engine-purity.sh` enforces that in CI.
public enum Module: String, CaseIterable {
    case engineAPI = "RedlampEngineAPI"
    case kernels = "RedlampKernels"
    case color = "RedlampColor"
    case services = "RedlampServices"
    case document = "RedlampDocument"
    case recipes = "RedlampRecipes"
    case masking = "RedlampMasking"
    case generative = "RedlampGenerative"
    /// Bench tasks (ARC-11): the folder format, pairing results with their references, the store,
    /// and the hub the iPhone app talks to. The harness and the iPhone app link it; the app doesn't.
    case bench = "RedlampBench"
    case engine = "RedlampEngine"
    case canvas = "RedlampCanvas"
    case design = "RedlampDesign"
    case ui = "RedlampUI"
    /// The Recipe Lab: a development tool only the harness links, so neither it nor
    /// Charts ships in the app.
    case lab = "RedlampLab"
    /// The regression suite's driver (ARC-07): scenarios that work the app through its own
    /// input paths. Its sources compile only in Debug and profiling builds.
    case automation = "RedlampAutomation"

    public var name: String {
        rawValue
    }

    public var path: Path {
        "packages/\(name)"
    }

    public var dependency: TargetDependency {
        .project(target: name, path: .relativeToRoot(path.pathString))
    }

    /// Whether the module belongs to the platform-neutral engine side of the boundary.
    public var isEngineLayer: Bool {
        switch self {
        case .engineAPI, .kernels, .color, .services, .document, .recipes, .masking, .generative, .bench, .engine: true
        case .canvas, .design, .ui, .lab, .automation: false
        }
    }

    /// The engine builds for every platform from day one. The UI layers are macOS-only
    /// until the iPad and iPhone shells land.
    /// Generative fill is offered on the Mac only (DEC-23).
    public var destinations: Destinations {
        isEngineLayer && self != .generative ? [.mac, .iPhone, .iPad] : [.mac]
    }

    public var deploymentTargets: DeploymentTargets {
        isEngineLayer && self != .generative
            ? .multiplatform(iOS: redlampIOSVersion, macOS: redlampMacOSVersion)
            : .macOS(redlampMacOSVersion)
    }

    /// The modules this module is allowed to depend on.
    ///
    /// UI layers see the engine only through `RedlampEngineAPI` (plus the pure-value
    /// document layer); they never link `RedlampEngine` or its internals.
    public var upstream: [Module] {
        switch self {
        case .engineAPI: []
        case .kernels: []
        case .color: [.engineAPI]
        case .services: [.engineAPI]
        case .document: [.engineAPI]
        // Recipes are pure values plus analysis: shared by the apps, the CLI and a future
        // companion app, so they may never reach the engine or any UI layer.
        case .recipes: [.engineAPI, .color]
        // Masks computed from the photo (Apple Vision, embedded mattes) and mask bitmaps.
        case .masking: [.engineAPI, .color]
        // Generative models on MLX (generative fill, RM-10), kept apart so nothing else links MLX.
        case .generative: [.engineAPI]
        // Pairing reads the capture kit's barcodes and matches photos with Recipes' analysis.
        case .bench: [.engineAPI, .recipes]
        case .engine: [.engineAPI, .kernels, .color, .services, .masking]
        case .canvas: [.engineAPI]
        case .design: [.engineAPI]
        case .ui: [.engineAPI, .canvas, .design, .document, .recipes]
        case .lab: [.engineAPI, .design, .recipes, .ui, .bench]
        case .automation: [.engineAPI, .canvas, .design, .document, .recipes, .ui]
        }
    }
}

// MARK: - Shared constants

public let redlampMacOSVersion = "26.0"
public let redlampIOSVersion = "26.0"
public let redlampBundlePrefix = "app.redlamp"
public let redlampDevelopmentTeam = "3JP75Z3F98"

public let redlampBaseSettings: SettingsDictionary = [
    "DEVELOPMENT_TEAM": .string(redlampDevelopmentTeam),
    // Tuist's `swiftVersion` config does not set the language mode; this does.
    "SWIFT_VERSION": "6.0",
    // Apple Silicon only, on every platform.
    "ARCHS": "arm64",
    "SWIFT_TREAT_WARNINGS_AS_ERRORS": true,
    "GCC_TREAT_WARNINGS_AS_ERRORS": true,
]

/// LibRaw is vendored as a static XCFramework built by `mise run vendor`.
public let libRawDependencies: [TargetDependency] = [
    .xcframework(path: .relativeToRoot("vendor/build/LibRaw.xcframework")),
    .sdk(name: "c++", type: .library),
    .sdk(name: "z", type: .library),
]

private let releaseSettings: SettingsDictionary = [
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "DEAD_CODE_STRIPPING": "YES",
    "EAGER_LINKING": "YES",
]

/// A function body or expression this slow to type-check fails the Debug build. The two
/// diagnostics have no warning group, so warnings-as-errors makes them errors.
private let typeCheckGuard: SettingsDictionary = [
    "OTHER_SWIFT_FLAGS": "$(inherited) -Xfrontend -warn-long-function-bodies=1500 -Xfrontend -warn-long-expression-type-checking=1000",
]

// MARK: - Target factories

public extension Target {
    static func frameworkTarget(
        module: Module,
        extraDependencies: [TargetDependency] = [],
        resources: ResourceFileElements? = nil,
    ) -> Target {
        .target(
            name: module.name,
            destinations: module.destinations,
            product: .framework,
            bundleId: "\(redlampBundlePrefix).\(module.name)",
            deploymentTargets: module.deploymentTargets,
            sources: ["Sources/**"],
            resources: resources,
            dependencies: module.upstream.map(\.dependency) + extraDependencies,
            settings: .settings(
                base: redlampBaseSettings,
                configurations: [
                    // Engine hot loops (raw copies, analysis) are 20-40x slower at -Onone,
                    // which makes Debug builds unusable for opening images.
                    .debug(
                        name: .debug,
                        settings: typeCheckGuard
                            .merging(module.isEngineLayer ? ["SWIFT_OPTIMIZATION_LEVEL": "-O"] : [:]) { $1 },
                    ),
                    .release(name: .release, settings: releaseSettings),
                ],
            ),
        )
    }

    static func frameworkTestTarget(module: Module, dependencies: [TargetDependency] = []) -> Target {
        .target(
            name: "\(module.name)Tests",
            destinations: [.mac],
            product: .unitTests,
            bundleId: "\(redlampBundlePrefix).\(module.name)Tests",
            deploymentTargets: .macOS(redlampMacOSVersion),
            sources: ["Tests/**"],
            dependencies: [.target(name: module.name)] + dependencies,
            settings: .settings(base: redlampBaseSettings),
            // Metal's validation layer turns a dispatch or binding the GPU would get wrong into a
            // failed test instead of a crash in the app.
            environmentVariables: ["MTL_DEBUG_LAYER": "1"],
        )
    }
}
