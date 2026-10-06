import Foundation

/// The look-development image set: `research/look-dev/manifest.json`, downloaded into
/// `build/look-dev/` by `mise run lookdev`. Shared by the CLI, the MCP server and the Lab.
public struct LookDevSet: Codable, Sendable {
    public struct Image: Codable, Sendable, Hashable {
        public var file: String
        public var url: String
        public var sha256: String?
        public var camera: String
        public var categories: [String]
        public var license: String
        public var source: String?
    }

    public var version: Int?
    public var description: String?
    public var gaps: [String]?
    public var images: [Image]

    public static func manifestURL(root: URL) -> URL {
        root.appendingPathComponent("research/look-dev/manifest.json")
    }

    public static func folder(root: URL) -> URL {
        root.appendingPathComponent("build/look-dev", isDirectory: true)
    }

    public static func load(root: URL) -> LookDevSet? {
        guard let data = try? Data(contentsOf: manifestURL(root: root)) else { return nil }
        return try? JSONDecoder().decode(LookDevSet.self, from: data)
    }

    /// Downloaded images, optionally only those in `category`.
    public func available(root: URL, category: String? = nil) -> [(image: Image, url: URL)] {
        let folder = Self.folder(root: root)
        return images
            .filter { category == nil || $0.categories.contains(category!) }
            .map { ($0, folder.appendingPathComponent($0.file)) }
            .filter { FileManager.default.fileExists(atPath: $0.1.path) }
    }
}
