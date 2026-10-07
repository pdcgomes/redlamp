import Foundation
import RedlampEngineAPI
import Synchronization

/// A collection's place in the collection list (LIB-23), written as a keyword's is: its names from the
/// top down, with `/` between them, `%2F` for a slash inside a name and `%25` for a percent sign.
public typealias CollectionPath = KeywordPath

/// What a place in the collection list is.
public enum CollectionKind: Int, Sendable, Hashable, CaseIterable {
    /// Holds collections, smart collections and other sets, never photos itself.
    case set = 0
    /// Photos the user put in it, which their sidecars name.
    case collection = 1
    /// The photos a query finds.
    case smart = 2

    /// As `Collections.json` names it.
    public var name: String {
        switch self {
        case .set: "set"
        case .collection: "collection"
        case .smart: "smart"
        }
    }

    public init?(name: String) {
        guard let kind = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = kind
    }
}

/// What the definitions keep of one place in the collection list.
public struct CollectionOptions: Sendable, Hashable {
    public var kind: CollectionKind
    /// A smart collection's query, in the library's query language (`LibraryQuery`).
    public var query: String?
    /// Options a newer Redlamp wrote, kept and written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public init(kind: CollectionKind = .collection, query: String? = nil) {
        self.kind = kind
        self.query = query
    }

    public static let set = CollectionOptions(kind: .set)

    public static func smart(_ query: String) -> CollectionOptions {
        CollectionOptions(kind: .smart, query: query)
    }
}

/// What the library's collection list holds that its photos can't carry (DEC-42): its sets, its
/// collections, those without photos included, its smart collections and their queries, and the target
/// collection, in `Collections.json` in `LibraryPaths.definitions`. A photo's sidecar names the
/// collections it's in, so a rebuilt index loses none of their photos and the photos describe
/// themselves without the list.
///
/// The file is JSON, sorted and indented: `{"format": "app.redlamp.collections", "version": 1,
/// "collections": {"Clients": {"kind": "set"}, "Clients/Acme/Selects": {}, "Five stars": {"kind":
/// "smart", "query": "rating=5"}}, "target": "Clients/Acme/Selects"}`. A collection's `kind` is written
/// only where it isn't `collection`. Keys a newer Redlamp wrote are kept, and a file with a newer
/// `version` is never written over.
public struct CollectionDefinitions: Sendable, Hashable {
    public static let format = "app.redlamp.collections"
    public static let version = 1
    public static let fileName = "Collections.json"

    /// Every set, collection and smart collection the library keeps, by path.
    public var collections: [CollectionPath: CollectionOptions]
    /// The collection the add-to-target key puts photos in; nil for the quick collection (the mark).
    public var target: CollectionPath?
    /// The file's version: newer than `version`, it's read but never written.
    public private(set) var fileVersion = CollectionDefinitions.version
    /// Top-level keys a newer Redlamp wrote, kept and written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public init(collections: [CollectionPath: CollectionOptions] = [:], target: CollectionPath? = nil) {
        self.collections = collections
        self.target = target
    }

    public var isWritable: Bool {
        fileVersion <= Self.version
    }

    // MARK: - The file

    /// `Collections.json` in `paths.definitions`.
    public static func url(in paths: LibraryPaths) -> URL {
        paths.definitions.appending(path: fileName)
    }

    /// The definitions at `url`; empty ones when there's no file.
    public static func load(from url: URL) throws -> CollectionDefinitions {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return CollectionDefinitions()
        }
        return try CollectionDefinitions(json: JSONDecoder().decode(JSONValue.self, from: data))
    }

    /// The definitions at `url`, read again only when the file's date or size changed since they
    /// were last read; empty ones when there's no file or it can't be read.
    static func cached(at url: URL) -> CollectionDefinitions {
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
        ])
        let stamp = values.map { "\($0.contentModificationDate?.timeIntervalSince1970 ?? 0) \($0.fileSize ?? 0)" }
        guard let stamp else { return CollectionDefinitions() }
        if let found = cache.withLock({ $0[url.path] }), found.stamp == stamp {
            return found.definitions
        }
        let definitions = (try? load(from: url)) ?? CollectionDefinitions()
        cache.withLock { $0[url.path] = (stamp, definitions) }
        return definitions
    }

    private static let cache = Mutex<[String: (stamp: String, definitions: CollectionDefinitions)]>([:])

    /// The smart collections' queries, by path.
    var smartQueries: [String: String] {
        collections.reduce(into: [:]) { queries, entry in
            if entry.value.kind == .smart {
                queries[entry.key.text] = entry.value.query ?? ""
            }
        }
    }

    /// Writes the definitions to `url` whole, replacing what's there in one step.
    public func save(to url: URL) throws {
        guard isWritable else { throw CollectionError.newerDefinitions(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data().write(to: url, options: .atomic)
    }

    /// The definitions as the file holds them.
    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(json)
        data.append(0x0A)
        return data
    }

    // MARK: - JSON

    init(json: JSONValue) throws {
        guard case let .object(object) = json else { throw CollectionError.unreadableDefinitions }
        self.init()
        if case let .number(version)? = object["version"] {
            fileVersion = Int(version)
        }
        if case let .object(collections)? = object["collections"] {
            for (text, value) in collections {
                guard let path = CollectionPath(text) else { continue }
                self.collections[path] = CollectionOptions(json: value)
            }
        }
        if case let .string(target)? = object["target"] {
            self.target = CollectionPath(target)
        }
        let known: Set = ["format", "version", "collections", "target"]
        unknownFields = object.filter { !known.contains($0.key) }
    }

    var json: JSONValue {
        var object = unknownFields
        object["format"] = .string(Self.format)
        object["version"] = .number(Double(max(fileVersion, Self.version)))
        object["collections"] = .object(Dictionary(uniqueKeysWithValues: collections.map {
            ($0.key.text, $0.value.json)
        }))
        if let target {
            object["target"] = .string(target.text)
        }
        return .object(object)
    }
}

extension CollectionOptions {
    private static let known: Set = ["kind", "query"]

    init(json: JSONValue) {
        guard case let .object(object) = json else {
            self.init()
            return
        }
        let kind = object["kind"]?.textValue.flatMap(CollectionKind.init(name:)) ?? .collection
        self.init(kind: kind, query: kind == .smart ? object["query"]?.textValue : nil)
        unknownFields = object.filter { !Self.known.contains($0.key) }
        if case let .string(name)? = object["kind"], CollectionKind(name: name) == nil {
            unknownFields["kind"] = .string(name)
        }
    }

    var json: JSONValue {
        var object = unknownFields
        if kind != .collection, object["kind"] == nil {
            object["kind"] = .string(kind.name)
        }
        if let query {
            object["query"] = .string(query)
        }
        return .object(object)
    }
}

/// Why a collection change or file couldn't be made.
public enum CollectionError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The definitions were written by a newer Redlamp: they're read, never written over.
    case newerDefinitions(URL)
    case unreadableDefinitions
    /// The collection or set isn't in the list.
    case noSuchCollection(CollectionPath)
    /// Something else is at the path already.
    case taken(CollectionPath)
    /// A set or collection can't be renamed or moved to where it is, or inside itself.
    case insideItself(CollectionPath)
    /// Photos go only in collections, and things only in sets.
    case notACollection(CollectionPath)
    case notASet(CollectionPath)

    public var description: String {
        switch self {
        case let .newerDefinitions(url): "\(url.path) was written by a newer Redlamp: it's left as it is"
        case .unreadableDefinitions: "the collection definitions can't be read"
        case let .noSuchCollection(path): "there's no collection or set \(path.text)"
        case let .taken(path): "\(path.text) is in the collection list already"
        case let .insideItself(path): "\(path.text) can't go inside itself"
        case let .notACollection(path): "\(path.text) isn't a collection: photos go only in collections"
        case let .notASet(path): "\(path.text) isn't a set: only sets hold collections"
        }
    }
}
