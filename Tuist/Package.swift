// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RedlampDependencies",
    dependencies: [
        // Only the app target links it, and a Mac App Store build must leave it out.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        // Generative fill on the Mac (RM-10; DEC-25 approved it).
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
    ],
)

#if TUIST
    import struct ProjectDescription.PackageSettings

    let packageSettings = PackageSettings(
        // MLX's C++ core holds the Metal device and its caches, so it's linked once, as a framework.
        productTypes: ["Cmlx": .framework, "MLX": .framework],
    )
#endif
