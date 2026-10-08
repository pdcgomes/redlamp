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
///
/// Each LUT-backed look is its JSON compressed with LZFSE (`.json.lzfse`), listed with its
/// details in the folder's index, so listing the looks reads no table; a look's file is
/// read the first time its table is used.
public enum BuiltInBaseLooks {
    private final class BundleToken {}

    static let bundle = Bundle(for: BundleToken.self)
    private static let fileExtension = "json.lzfse"
    private static let indexName = "BaseLooks.json"

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

    public static let resources: [BaseLookPackage] = read().sorted { ($0.slot ?? $0.id) < ($1.slot ?? $1.id) }

    /// The bundled looks in file name order, their tables unread.
    static func read() -> [BaseLookPackage] {
        // Xcode may flatten the BaseLooks folder into the bundle's root.
        let folder = bundle.url(forResource: "BaseLooks", withExtension: "json", subdirectory: "BaseLooks")
            ?? bundle.url(forResource: "BaseLooks", withExtension: "json")
        return folder.map { read(from: $0.deletingLastPathComponent()) } ?? []
    }

    /// The looks a folder's index lists, in file name order, their tables unread.
    static func read(from folder: URL) -> [BaseLookPackage] {
        guard let data = try? Data(contentsOf: folder.appending(path: indexName)),
              let index = try? RecipeFile.decoder.decode([IndexEntry].self, from: data)
        else { return [] }
        return index.map { $0.package(in: folder) }
    }

    /// Writes `package` into a Resources/BaseLooks folder as `<name>.json.lzfse`, then lists
    /// the folder's looks in its index again.
    public static func install(_ package: BaseLookPackage, as name: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = try RecipeFile.encoder.encode(package)
        try ((json as NSData).compressed(using: .lzfse) as Data)
            .write(to: folder.appending(path: "\(name).\(fileExtension)"), options: .atomic)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".\(fileExtension)") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let index = try files.map { try IndexEntry(decode($0), file: $0.lastPathComponent) }
        try RecipeFile.encoder.encode(index).write(to: folder.appending(path: indexName), options: .atomic)
    }

    /// The look installed as `<name>` in a Resources/BaseLooks folder.
    public static func installed(_ name: String, in folder: URL) -> BaseLookPackage? {
        try? decode(folder.appending(path: "\(name).\(fileExtension)"))
    }

    private static func decode(_ url: URL) throws -> BaseLookPackage {
        let json = try (Data(contentsOf: url) as NSData).decompressed(using: .lzfse) as Data
        return try RecipeFile.decoder.decode(BaseLookPackage.self, from: json)
    }

    /// A look as the index lists it: everything but its table's data.
    private struct IndexEntry: Codable {
        struct Table: Codable {
            var size: Int
            var space: String
            var sha256: String
        }

        var file: String
        var id: String
        var version: Int
        var name: String
        var summary: String?
        var slot: String?
        var look: BaseLookParameters
        var table: Table?

        init(_ package: BaseLookPackage, file: String) {
            self.file = file
            id = package.id
            version = package.version
            name = package.name
            summary = package.summary
            slot = package.slot
            look = package.parameters
            table = package.table.map { Table(size: $0.size, space: $0.space, sha256: $0.sha256) }
        }

        func package(in folder: URL) -> BaseLookPackage {
            var package = BaseLookPackage(
                id: id, version: version, name: name, summary: summary, slot: slot, parameters: look,
            )
            if let table {
                let url = folder.appending(path: file)
                let sha256 = table.sha256
                package.table = LookTableFile(size: table.size, space: table.space, sha256: sha256) {
                    guard let stored = try? BuiltInBaseLooks.decode(url).table,
                          stored.sha256 == sha256 else { return "" }
                    return stored.data
                }
            }
            return package
        }
    }

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
