import Foundation
import RedlampEngineAPI

/// Base Looks installed on this machine, one JSON file per look version.
///
/// Files are named by id, version and table hash, and are never deleted when a recipe
/// is: an edit made with a look keeps rendering exactly, even after its recipe is gone.
public struct LookStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func fileName(for package: BaseLookPackage) -> String {
        let id = package.id.replacingOccurrences(of: "/", with: "~")
        let content = package.table.map { String($0.sha256.prefix(20)) } ?? "parametric"
        return "\(id)@\(package.version)-\(content).json"
    }

    /// Stores a look; storing the same version again is a no-op.
    public func save(_ package: BaseLookPackage) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(for: package))
        if FileManager.default.fileExists(atPath: url.path) {
            return
        }
        try RecipeFile.encoder.encode(package).write(to: url, options: .atomic)
    }

    public func all() -> [BaseLookPackage] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let package = try? RecipeFile.decoder.decode(BaseLookPackage.self, from: data)
                else { return nil }
                return package
            }
    }
}

/// The Base Looks that ship with Redlamp: the parametric built-ins plus the LUT-backed
/// looks in the framework's resources.
public enum BuiltInBaseLooks {
    private final class BundleToken {}

    /// Every bundled look, built-ins first.
    public static let all: [BaseLookPackage] = parametric + resources

    public static let parametric: [BaseLookPackage] = BuiltInBaseLook.allCases.map { look in
        BaseLookPackage(
            id: look.rawValue,
            version: look.version,
            name: look.name,
            summary: look.summary,
            parameters: look.parameters,
        )
    }

    public static let resources: [BaseLookPackage] = {
        let bundle = Bundle(for: BundleToken.self)
        // Xcode may flatten the BaseLooks folder into the bundle's root.
        let nested = bundle.urls(forResourcesWithExtension: "json", subdirectory: "BaseLooks") ?? []
        let urls = !nested.isEmpty ? nested
            : (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("base-") || $0.lastPathComponent.hasPrefix("stock-") }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let package = try? RecipeFile.decoder.decode(BaseLookPackage.self, from: data)
            else { return nil }
            return package
        }
        .sorted { ($0.slot ?? $0.id) < ($1.slot ?? $1.id) }
    }()

    public static func package(id: String, version: Int) -> BaseLookPackage? {
        all.first { $0.id == id && $0.version == version }
    }

    /// The newest bundled look filling a camera-card slot, such as `chrome`. Older versions
    /// stay bundled for the edits that pinned them.
    public static func package(slot: String) -> BaseLookPackage? {
        resources.filter { $0.slot == slot }.max { $0.version < $1.version }
    }

    public static func package(slot: String, version: Int) -> BaseLookPackage? {
        resources.first { $0.slot == slot && $0.version == version }
    }

    /// Every look once, at its newest version: what menus and browsers list.
    public static func newest(_ packages: [BaseLookPackage]) -> [BaseLookPackage] {
        var newest: [String: BaseLookPackage] = [:]
        for package in packages where (newest[package.id]?.version ?? 0) < package.version {
            newest[package.id] = package
        }
        return packages.filter { newest[$0.id] == $0 }
    }
}
