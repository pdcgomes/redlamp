// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RedlampDependencies",
    dependencies: [
        // Only the app target links it, and a Mac App Store build must leave it out.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
)
