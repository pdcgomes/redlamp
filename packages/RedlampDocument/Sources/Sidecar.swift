import Foundation
import RedlampEngineAPI

public struct Snapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var created: Date
    public var recipe: EditRecipe

    public init(id: UUID = UUID(), name: String, created: Date = Date(), recipe: EditRecipe) {
        self.id = id
        self.name = name
        self.created = created
        self.recipe = recipe
    }
}

/// Everything Redlamp stores next to an image: `IMG_1234.CR3.redlamp`.
public struct Sidecar: Codable, Sendable, Hashable {
    public static let format = "app.redlamp.edit"

    public var format: String = Sidecar.format
    public var recipe: EditRecipe
    public var snapshots: [Snapshot]
    public var modified: Date

    public init(recipe: EditRecipe, snapshots: [Snapshot] = [], modified: Date = Date()) {
        self.recipe = recipe
        self.snapshots = snapshots
        self.modified = modified
    }
}

/// Reads and writes sidecars. Writes are atomic so a crash never leaves a torn file.
public struct SidecarStore: Sendable {
    public init() {}

    public func url(for image: URL) -> URL {
        image.appendingPathExtension("redlamp")
    }

    public func load(for image: URL) -> Sidecar? {
        guard let data = try? Data(contentsOf: url(for: image)) else { return nil }
        return try? JSONDecoder.sidecar.decode(Sidecar.self, from: data)
    }

    public func save(_ sidecar: Sidecar, for image: URL) throws {
        let data = try JSONEncoder.sidecar.encode(sidecar)
        try data.write(to: url(for: image), options: .atomic)
    }

    public func delete(for image: URL) {
        try? FileManager.default.removeItem(at: url(for: image))
    }
}

extension JSONEncoder {
    static var sidecar: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var sidecar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
