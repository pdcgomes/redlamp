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
public struct Sidecar: Sendable, Hashable {
    public static let format = "app.redlamp.edit"

    public var format: String = Sidecar.format
    public var recipe: EditRecipe
    public var snapshots: [Snapshot]
    /// Optional so sidecars written before ratings existed still decode.
    public var metadata: PhotoMetadata?
    public var modified: Date
    /// Top-level fields written by a newer Redlamp, written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

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
        recipe.isPristine && snapshots.isEmpty && (metadata?.isEmpty ?? true) && unknownFields.isEmpty
    }

    /// Same edit, ratings and snapshots, whenever it was written.
    func hasSameContent(as other: Sidecar) -> Bool {
        var other = other
        other.modified = modified
        return self == other
    }
}

extension Sidecar: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case format, recipe, snapshots, metadata, modified
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? Sidecar.format
        recipe = try container.decode(EditRecipe.self, forKey: .recipe)
        snapshots = try container.decodeIfPresent([Snapshot].self, forKey: .snapshots) ?? []
        metadata = try container.decodeIfPresent(PhotoMetadata.self, forKey: .metadata)
        modified = try container.decodeIfPresent(Date.self, forKey: .modified) ?? .distantPast
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(recipe, forKey: .recipe)
        try container.encode(snapshots, forKey: .snapshots)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encode(modified, forKey: .modified)
    }
}

public enum SidecarStoreError: Error, Equatable {
    /// The sidecar was written by a newer Redlamp. It is read-only here, so it is never
    /// overwritten or deleted.
    case writtenByNewerVersion(URL)
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

    /// Whether the image's sidecar uses a file format or process version this build
    /// doesn't have. Such edits can be shown, but saving would lose information.
    public func isWrittenByNewerVersion(for image: URL) -> Bool {
        guard let data = try? Data(contentsOf: url(for: image)) else { return false }
        return Self.isNewer(data)
    }

    /// Writes the sidecar unless nothing but `modified` changed, so unchanged edits don't
    /// wake up sync services. Fields a newer Redlamp added to the file on disk are kept.
    public func save(_ sidecar: Sidecar, for image: URL) throws {
        let destination = url(for: image)
        var sidecar = sidecar
        if let data = try? Data(contentsOf: destination) {
            if Self.isNewer(data) {
                throw SidecarStoreError.writtenByNewerVersion(destination)
            }
            if let existing = try? JSONDecoder.sidecar.decode(Sidecar.self, from: data) {
                sidecar.unknownFields = existing.unknownFields.merging(sidecar.unknownFields) { _, new in new }
                if existing.hasSameContent(as: sidecar) {
                    return
                }
            }
        }
        try JSONEncoder.sidecar.encode(sidecar).write(to: destination, options: .atomic)
    }

    /// Removes the sidecar, unless a newer Redlamp wrote it.
    public func delete(for image: URL) {
        guard !isWrittenByNewerVersion(for: image) else { return }
        try? FileManager.default.removeItem(at: url(for: image))
    }

    private static func isNewer(_ data: Data) -> Bool {
        struct Probe: Decodable {
            struct Versions: Decodable {
                var version: Int?
                var processVersion: Int?
            }

            var recipe: Versions?
        }
        guard let versions = (try? JSONDecoder.sidecar.decode(Probe.self, from: data))?.recipe else { return false }
        return (versions.version ?? 1) > EditRecipe.formatVersion
            || (versions.processVersion ?? 1) > EditRecipe.currentProcessVersion
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
