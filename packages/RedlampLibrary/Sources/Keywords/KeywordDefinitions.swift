import Foundation
import RedlampEngineAPI
import Synchronization

/// How a keyword is exported and what kind it is: Lightroom Classic's keyword tag options, and
/// darktable's category and private flags (LIB-21).
public struct KeywordOptions: Sendable, Hashable {
    /// Other names it's found by, and exported with when `exportSynonyms` says so.
    public var synonyms: [String]
    /// It's written into exported photos (Lightroom's Include on Export).
    public var includeOnExport: Bool
    /// The keywords containing it go with it, those exported themselves (Export Containing Keywords).
    public var exportContainingKeywords: Bool
    /// Its synonyms go with it (Export Synonyms).
    public var exportSynonyms: Bool
    /// A heading that organises the list: never exported itself, though the keywords inside it are,
    /// and not offered by completion.
    public var isCategory: Bool
    /// Kept with the photos and found by searches, but never exported, nor anything inside it.
    public var isPrivate: Bool
    /// A person's name (Lightroom's Person keyword): exported unless an export leaves people out.
    public var isPerson: Bool
    /// Options a newer Redlamp wrote, kept and written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public init(
        synonyms: [String] = [], includeOnExport: Bool = true, exportContainingKeywords: Bool = true,
        exportSynonyms: Bool = true, isCategory: Bool = false, isPrivate: Bool = false, isPerson: Bool = false,
    ) {
        self.synonyms = Self.tidied(synonyms)
        self.includeOnExport = includeOnExport
        self.exportContainingKeywords = exportContainingKeywords
        self.exportSynonyms = exportSynonyms
        self.isCategory = isCategory
        self.isPrivate = isPrivate
        self.isPerson = isPerson
    }

    /// Every option at its default: the keyword is in the definitions only to stay in the list.
    public var isDefault: Bool {
        self == KeywordOptions()
    }

    /// Whether it's written into exported photos itself.
    public var isExported: Bool {
        includeOnExport && !isCategory && !isPrivate
    }

    /// These options with `other`'s synonyms added, as merging keywords does.
    func adding(synonymsOf other: KeywordOptions) -> KeywordOptions {
        var merged = self
        merged.synonyms = Self.tidied(synonyms + other.synonyms)
        return merged
    }

    /// Synonyms tidied as keyword names are, each once ignoring case, in order.
    static func tidied(_ synonyms: [String]) -> [String] {
        var seen = Set<String>()
        return synonyms.compactMap(KeywordPath.canonical).filter { seen.insert($0.lowercased()).inserted }
    }
}

/// What the library's keyword list holds that its photos can't carry (DEC-42): keywords with no
/// photos yet, each keyword's synonyms, export options and kind, and the keyword sets, in
/// `Keywords.json` in `LibraryPaths.definitions`. A rebuilt index loses none of it, and photos
/// describe themselves without it: their sidecars hold their keywords' full paths.
///
/// The file is JSON, sorted and indented: `{"format": "app.redlamp.keywords", "version": 1,
/// "keywords": {"Places/Portugal/Lisbon": {"synonyms": ["Lisboa"]}, "People": {"category": true}},
/// "sets": [{"name": "Wedding", "keywords": ["Bride", null, "Groom"]}], "activeSet": "Wedding"}`.
/// A keyword's options are written only where they aren't the defaults (`includeOnExport`,
/// `exportContainingKeywords` and `exportSynonyms` true; `category`, `private` and `person`
/// false), so `{}` keeps a keyword in the list with nothing else to say. Keys a newer Redlamp wrote
/// are kept, and a file with a newer `version` is never written over.
public struct KeywordDefinitions: Sendable, Hashable {
    public static let format = "app.redlamp.keywords"
    public static let version = 1
    public static let fileName = "Keywords.json"

    /// Keywords with something to say beyond their photos, by path.
    public var keywords: [KeywordPath: KeywordOptions]
    /// The keyword sets the user keeps; nil for the ones Redlamp starts with (`KeywordSet.builtIn`).
    public var sets: [KeywordSet]?
    /// The set ⌥1 to ⌥9 apply; nil for Recent Keywords.
    public var activeSet: String?
    /// The file's version: newer than `version`, it's read but never written.
    public private(set) var fileVersion = KeywordDefinitions.version
    /// Top-level keys a newer Redlamp wrote, kept and written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public init(keywords: [KeywordPath: KeywordOptions] = [:], sets: [KeywordSet]? = nil, activeSet: String? = nil) {
        self.keywords = keywords
        self.sets = sets
        self.activeSet = activeSet
    }

    /// The options of `keyword`: its own, or the defaults.
    public func options(_ keyword: KeywordPath) -> KeywordOptions {
        keywords[keyword] ?? KeywordOptions()
    }

    /// Every synonym by its keyword's path, for the keywords that have some.
    public var synonyms: [String: [String]] {
        keywords.reduce(into: [:]) { synonyms, entry in
            if !entry.value.synonyms.isEmpty {
                synonyms[entry.key.text] = entry.value.synonyms
            }
        }
    }

    /// The sets the keywording panel offers after Recent Keywords.
    public var keywordSets: [KeywordSet] {
        sets ?? KeywordSet.builtIn
    }

    public var isWritable: Bool {
        fileVersion <= Self.version
    }

    // MARK: - The file

    /// `Keywords.json` in `paths.definitions`.
    public static func url(in paths: LibraryPaths) -> URL {
        paths.definitions.appending(path: fileName)
    }

    /// The definitions at `url`; empty ones when there's no file.
    public static func load(from url: URL) throws -> KeywordDefinitions {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return KeywordDefinitions()
        }
        return try KeywordDefinitions(json: JSONDecoder().decode(JSONValue.self, from: data))
    }

    /// Writes the definitions to `url` whole, replacing what's there in one step.
    public func save(to url: URL) throws {
        guard isWritable else { throw KeywordError.newerDefinitions(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data().write(to: url, options: .atomic)
        Self.cache.withLock { $0[url.path] = nil }
    }

    /// The definitions as the file holds them.
    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(json)
        data.append(0x0A)
        return data
    }

    /// The definitions at `url`, read again only when the file changed since they were last read
    /// here; empty ones when it's missing or can't be read.
    static func cached(at url: URL) -> KeywordDefinitions {
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
        ])
        let stamp = values.map { "\($0.contentModificationDate?.timeIntervalSince1970 ?? 0) \($0.fileSize ?? 0)" }
        guard let stamp else { return KeywordDefinitions() }
        if let found = cache.withLock({ $0[url.path] }), found.stamp == stamp {
            return found.definitions
        }
        let definitions = (try? load(from: url)) ?? KeywordDefinitions()
        cache.withLock { $0[url.path] = (stamp, definitions) }
        return definitions
    }

    private static let cache = Mutex<[String: (stamp: String, definitions: KeywordDefinitions)]>([:])

    // MARK: - JSON

    init(json: JSONValue) throws {
        guard case let .object(object) = json else { throw KeywordError.unreadableDefinitions }
        self.init()
        if case let .number(version)? = object["version"] {
            fileVersion = Int(version)
        }
        if case let .object(keywords)? = object["keywords"] {
            for (text, value) in keywords {
                guard let path = KeywordPath(text) else { continue }
                let options = KeywordOptions(json: value)
                self.keywords[path] = self.keywords[path].map { $0.adding(synonymsOf: options) } ?? options
            }
        }
        if case let .array(sets)? = object["sets"] {
            self.sets = sets.compactMap(KeywordSet.init(json:))
        }
        if case let .string(active)? = object["activeSet"] {
            activeSet = active
        }
        let known: Set = ["format", "version", "keywords", "sets", "activeSet"]
        unknownFields = object.filter { !known.contains($0.key) }
    }

    var json: JSONValue {
        var object = unknownFields
        object["format"] = .string(Self.format)
        object["version"] = .number(Double(max(fileVersion, Self.version)))
        object["keywords"] = .object(Dictionary(uniqueKeysWithValues: keywords.map { ($0.key.text, $0.value.json) }))
        if let sets {
            object["sets"] = .array(sets.map(\.json))
        }
        if let activeSet {
            object["activeSet"] = .string(activeSet)
        }
        return .object(object)
    }
}

extension KeywordOptions {
    private static let known: Set = [
        "synonyms", "includeOnExport", "exportContainingKeywords", "exportSynonyms", "category", "private", "person",
    ]

    init(json: JSONValue) {
        guard case let .object(object) = json else {
            self.init()
            return
        }
        func flag(_ key: String, _ standard: Bool) -> Bool {
            if case let .bool(value)? = object[key] {
                return value
            }
            return standard
        }
        var synonyms: [String] = []
        if case let .array(values)? = object["synonyms"] {
            synonyms = values.compactMap(\.textValue)
        }
        self.init(
            synonyms: synonyms, includeOnExport: flag("includeOnExport", true),
            exportContainingKeywords: flag("exportContainingKeywords", true), exportSynonyms: flag(
                "exportSynonyms",
                true,
            ),
            isCategory: flag("category", false), isPrivate: flag("private", false), isPerson: flag("person", false),
        )
        unknownFields = object.filter { !Self.known.contains($0.key) }
    }

    var json: JSONValue {
        var object = unknownFields
        if !synonyms.isEmpty {
            object["synonyms"] = .array(synonyms.map(JSONValue.string))
        }
        for (key, value, standard) in [
            ("includeOnExport", includeOnExport, true), ("exportContainingKeywords", exportContainingKeywords, true),
            ("exportSynonyms", exportSynonyms, true), ("category", isCategory, false), ("private", isPrivate, false),
            ("person", isPerson, false),
        ] where value != standard {
            object[key] = .bool(value)
        }
        return .object(object)
    }
}

/// Why a keyword change or file couldn't be made.
public enum KeywordError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The definitions were written by a newer Redlamp: they're read, never written over.
    case newerDefinitions(URL)
    case unreadableDefinitions
    /// A keyword path, or a name for one, with nothing left in it once tidied.
    case emptyKeyword(String)
    /// The keyword isn't in the list.
    case noSuchKeyword(KeywordPath)
    /// A keyword can't be renamed or moved to where it is, or inside itself.
    case insideItself(KeywordPath)
    /// A keyword-list file that isn't text.
    case unreadableFile
    case noSuchBatch(UUID)
    case damagedJournal(UUID)
    case newerJournal(UUID)
    /// A batch a forced quit interrupted waits for `LibraryKeywords.recover`.
    case unfinished(UUID)
    case nothingToUndo

    public var description: String {
        switch self {
        case let .newerDefinitions(url): "\(url.path) was written by a newer Redlamp: it's left as it is"
        case .unreadableDefinitions: "the keyword definitions can't be read"
        case let .emptyKeyword(text): "“\(text)” has no keyword in it"
        case let .noSuchKeyword(path): "there's no keyword \(path.text)"
        case let .insideItself(path): "\(path.text) can't go inside itself"
        case .unreadableFile: "the file isn't a keyword list"
        case let .noSuchBatch(id): "no keyword change \(id) in the journal"
        case let .damagedJournal(id): "the keyword change \(id) in the journal can't be read"
        case let .newerJournal(id): "the keyword change \(id) was written by a newer Redlamp"
        case let .unfinished(id): "a keyword change a forced quit interrupted (\(id)) is unfinished"
        case .nothingToUndo: "no keyword change to undo"
        }
    }
}

extension JSONValue {
    var textValue: String? {
        if case let .string(text) = self {
            return text
        }
        return nil
    }
}
