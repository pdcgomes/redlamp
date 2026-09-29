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

public enum PhotoFlag: String, Codable, Sendable, Hashable {
    case pick, reject
}

/// Lightroom's color labels, keyed 6–9 (purple has no key).
public enum ColorLabel: String, Codable, Sendable, Hashable, CaseIterable {
    case red, yellow, green, blue, purple
}

/// Rating, flag and label: the culling metadata Lightroom lets you set while developing.
public struct PhotoMetadata: Codable, Sendable, Hashable {
    /// 0–5 stars.
    public var rating: Int
    public var flag: PhotoFlag?
    public var label: ColorLabel?

    public init(rating: Int = 0, flag: PhotoFlag? = nil, label: ColorLabel? = nil) {
        self.rating = min(max(rating, 0), 5)
        self.flag = flag
        self.label = label
    }

    public var isEmpty: Bool {
        rating == 0 && flag == nil && label == nil
    }
}

/// Everything Redlamp stores next to an image: `IMG_1234.CR3.redlamp`.
public struct Sidecar: Codable, Sendable, Hashable {
    public static let format = "app.redlamp.edit"

    public var format: String = Sidecar.format
    public var recipe: EditRecipe
    public var snapshots: [Snapshot]
    /// Optional so sidecars written before ratings existed still decode.
    public var metadata: PhotoMetadata?
    public var modified: Date

    public init(
        recipe: EditRecipe,
        snapshots: [Snapshot] = [],
        metadata: PhotoMetadata? = nil,
        modified: Date = Date(),
    ) {
        self.recipe = recipe
        self.snapshots = snapshots
        self.metadata = metadata
        self.modified = modified
    }

    /// Nothing worth keeping: the file can be deleted.
    public var isPristine: Bool {
        recipe.isPristine && snapshots.isEmpty && (metadata?.isEmpty ?? true)
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
