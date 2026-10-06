import Foundation
import RedlampEngineAPI

/// A metadata preset (LIB-22), as Photo Mechanic's templates are: the fields it ticks, each with its text
/// and whether it replaces what a photo has, goes after it or goes before it. Fields it doesn't tick are
/// left as they are.
public struct MetadataPreset: Sendable, Hashable {
    /// What a ticked field does to what a photo has.
    public enum Mode: String, Sendable, Hashable, CaseIterable {
        case replace, append, prefix
    }

    /// A field a preset can fill.
    public enum Field: String, Sendable, Hashable, CaseIterable, Comparable {
        case title, caption, creator, copyright, sublocation, city, state, country, countryCode

        /// The sidecar's key: `location.city` for a place's.
        var key: String {
            switch self {
            case .title, .caption, .creator, .copyright: rawValue
            case .sublocation, .city, .state, .country, .countryCode: "location." + rawValue
            }
        }

        /// What goes between a photo's text and the preset's when one is added to the other.
        var separator: String {
            self == .creator ? "; " : " "
        }

        public static func < (lhs: Field, rhs: Field) -> Bool {
            allCases.firstIndex(of: lhs) ?? 0 < allCases.firstIndex(of: rhs) ?? 0
        }
    }

    public struct Entry: Sendable, Hashable {
        public var text: String
        public var mode: Mode
        /// Options a newer Redlamp wrote, kept and written back unchanged.
        public var unknownFields: [String: JSONValue] = [:]

        public init(_ text: String, mode: Mode = .replace) {
            self.text = text
            self.mode = mode
        }
    }

    public var name: String
    /// The fields it ticks.
    public var fields: [Field: Entry]
    /// Keys a newer Redlamp wrote, kept and written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public init(name: String, fields: [Field: Entry]) {
        self.name = name
        self.fields = fields
    }

    /// What it does to each photo's sidecar fields, `codes` expanded in its texts. A replacing field
    /// with no text clears the photo's.
    func edits(codes: CodeReplacements) -> [String: FieldEdit] {
        var edits: [String: FieldEdit] = [:]
        for (field, entry) in fields {
            let text = codes.expanded(entry.text)
            edits[field.key] = switch entry.mode {
            case .replace where field.key.contains("."):
                .set(XMPSource.trimmed(text).map(JSONValue.string))
            case .replace: .set(.string(text))
            case .append: .append(text, separator: field.separator)
            case .prefix: .prefix(text, separator: field.separator)
            }
        }
        return edits
    }
}

/// The library's metadata presets, in `Metadata Presets.json` in `LibraryPaths.definitions`:
/// `{"format": "app.redlamp.metadata-presets", "version": 1, "presets": [{"name": "Wedding", "fields":
/// {"caption": {"text": "\wed\ at the chapel", "mode": "append"}, "city": {"text": "Sintra"}}}]}`, a
/// field's `mode` written only where it isn't `replace`. Keys a newer Redlamp wrote are kept, and a file
/// with a newer `version` is never written over.
public struct MetadataPresets: Sendable, Hashable {
    public static let format = "app.redlamp.metadata-presets"
    public static let version = 1
    public static let fileName = "Metadata Presets.json"

    public var presets: [MetadataPreset]
    public private(set) var fileVersion = MetadataPresets.version
    public var unknownFields: [String: JSONValue] = [:]

    public init(presets: [MetadataPreset] = []) {
        self.presets = presets
    }

    public subscript(name: String) -> MetadataPreset? {
        presets.first { $0.name == name }
    }

    public var isWritable: Bool {
        fileVersion <= Self.version
    }

    public static func url(in paths: LibraryPaths) -> URL {
        paths.definitions.appending(path: fileName)
    }

    /// The presets at `url`; none when there's no file.
    public static func load(from url: URL) throws -> MetadataPresets {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return MetadataPresets()
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let presets = MetadataPresets(json: json)
        else { throw MetadataError.unreadableFile(url.lastPathComponent) }
        return presets
    }

    /// Writes the presets to `url` whole, replacing what's there in one step.
    public func save(to url: URL) throws {
        guard isWritable else { throw MetadataError.unreadableFile(url.lastPathComponent) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(json)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    init?(json: JSONValue) {
        guard case let .object(object) = json else { return nil }
        if case let .number(version)? = object["version"] {
            fileVersion = Int(version)
        }
        presets = []
        if case let .array(entries)? = object["presets"] {
            presets = entries.compactMap(MetadataPreset.init(json:))
        }
        let known: Set = ["format", "version", "presets"]
        unknownFields = object.filter { !known.contains($0.key) }
    }

    var json: JSONValue {
        var object = unknownFields
        object["format"] = .string(Self.format)
        object["version"] = .number(Double(max(fileVersion, Self.version)))
        object["presets"] = .array(presets.map(\.json))
        return .object(object)
    }
}

extension MetadataPreset {
    init?(json: JSONValue) {
        guard case let .object(object) = json, let name = object["name"]?.textValue else { return nil }
        var fields: [Field: Entry] = [:]
        var unknownFields = object.filter { $0.key != "name" && $0.key != "fields" }
        if case let .object(entries)? = object["fields"] {
            var unknownEntries: [String: JSONValue] = [:]
            for (key, value) in entries {
                guard let field = Field(rawValue: key), case let .object(entry) = value,
                      let text = entry["text"]?.textValue
                else {
                    unknownEntries[key] = value
                    continue
                }
                var parsed = Entry(text, mode: entry["mode"]?.textValue.flatMap(Mode.init(rawValue:)) ?? .replace)
                parsed.unknownFields = entry.filter { $0.key != "text" && $0.key != "mode" }
                if case let .string(mode)? = entry["mode"], Mode(rawValue: mode) == nil {
                    parsed.unknownFields["mode"] = .string(mode)
                }
                fields[field] = parsed
            }
            if !unknownEntries.isEmpty {
                unknownFields["fields"] = .object(unknownEntries)
            }
        }
        self.init(name: name, fields: fields)
        self.unknownFields = unknownFields
    }

    var json: JSONValue {
        var object = unknownFields
        var entries = object["fields"]?.objectValue ?? [:]
        for (field, entry) in fields {
            var value = entry.unknownFields
            value["text"] = .string(entry.text)
            if entry.mode != .replace, value["mode"] == nil {
                value["mode"] = .string(entry.mode.rawValue)
            }
            entries[field.rawValue] = .object(value)
        }
        object["name"] = .string(name)
        object["fields"] = .object(entries)
        return .object(object)
    }
}

public extension LibraryMetadata {
    /// `Metadata Presets.json` in the library's definitions.
    var presetsURL: URL {
        MetadataPresets.url(in: paths)
    }

    func presets() async throws -> MetadataPresets {
        let url = presetsURL
        return try await LibraryIndex.offCaller { try MetadataPresets.load(from: url) }
    }

    /// Keeps `preset`, in place of the one with its name.
    func save(_ preset: MetadataPreset) async throws {
        let url = presetsURL
        try await LibraryIndex.offCaller {
            var presets = try MetadataPresets.load(from: url)
            if let place = presets.presets.firstIndex(where: { $0.name == preset.name }) {
                presets.presets[place] = preset
            } else {
                presets.presets.append(preset)
            }
            try presets.save(to: url)
        }
    }

    /// Forgets the preset named `name`.
    func removePreset(named name: String) async throws {
        let url = presetsURL
        try await LibraryIndex.offCaller {
            var presets = try MetadataPresets.load(from: url)
            presets.presets.removeAll { $0.name == name }
            try presets.save(to: url)
        }
    }
}
