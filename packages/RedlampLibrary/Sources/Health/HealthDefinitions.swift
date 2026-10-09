import Foundation
import RedlampEngineAPI
import Synchronization

/// A finding the user kept anyway (LIB-40): it's no longer listed, until it's taken back from the
/// Kept Anyway list. Each is keyed by what the photo shows, so an index rebuild keeps it, and by when its file
/// was last modified, so a photo rewritten since is listed again.
public struct KeptAnyway: Sendable, Hashable {
    public enum Key: Sendable, Hashable {
        /// The photo's content key, and when its file was last modified; nil in an entry an earlier Redlamp
        /// wrote, which keeps the photo whatever its date. The key reads only the file's start, and its date
        /// tells a rewrite that keeps the size from the photo it kept.
        case content(ContentKey, modified: Date?)
        /// A photo without a content key, an unreadable or empty one, by where it is and its file.
        case file(path: String, size: Int64, modified: Date)
        /// A duplicate group, by the full SHA-256 its copies share and how many there were: another
        /// copy opens it again.
        case group(sha256: Data, copies: Int)
    }

    public var check: HealthCheck.Kind
    public var key: Key
    /// Keys a newer Redlamp wrote, kept and written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public init(check: HealthCheck.Kind, key: Key) {
        self.check = check
        self.key = key
    }

    /// Whether it keeps a finding of `check` for a photo with `contentKey` and `modified`, or without a
    /// content key at `path` with `size` and `modified`.
    func keeps(_ check: HealthCheck.Kind, contentKey: Data?, path: String, size: Int64, modified: Date) -> Bool {
        guard check == self.check else { return false }
        switch key {
        case let .content(key, keptModified):
            return contentKey == key.data && keptModified.map { LibraryIndexer.Run.same($0, modified) } != false
        case let .file(kept, keptSize, keptModified):
            return contentKey == nil && kept == path && keptSize == size
                && LibraryIndexer.Run.same(keptModified, modified)
        case .group: return false
        }
    }
}

/// What Library Health keeps beside the index (DEC-42): the findings kept anyway, in `Health.json` in
/// `LibraryPaths.definitions`, so an index rebuild loses none of them, and nothing is written in a
/// photo's sidecar for them.
///
/// The file is JSON, sorted and indented: `{"format": "app.redlamp.health", "version": 1, "keptAnyway":
/// [{"check": "damaged", "contentKey": "…", "modified": 1759700000}, {"check": "duplicates", "sha256": "…",
/// "copies": 2}, {"check": "damaged", "path": "/Photos/IMG_1.JPG", "size": 0, "modified": 1759700000}]}`. An
/// entry by content key without `modified`, as the first builds wrote them, keeps its photo whatever its date.
/// Keys a newer Redlamp wrote are kept, in the file and in each entry, and a file with a newer `version` is never
/// written over.
public struct HealthDefinitions: Sendable, Hashable {
    public static let format = "app.redlamp.health"
    public static let version = 1
    public static let fileName = "Health.json"

    public var keptAnyway: [KeptAnyway]
    /// The file's version: newer than `version`, it's read but never written.
    public private(set) var fileVersion = HealthDefinitions.version
    /// Top-level keys a newer Redlamp wrote, kept and written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public init(keptAnyway: [KeptAnyway] = []) {
        self.keptAnyway = keptAnyway
    }

    public var isWritable: Bool {
        fileVersion <= Self.version
    }

    /// The groups of duplicates kept anyway, by SHA-256, with how many copies each had.
    var keptGroups: [Data: Int] {
        keptAnyway.reduce(into: [:]) { groups, kept in
            if kept.check == .duplicates, case let .group(sha256, copies) = kept.key {
                groups[sha256] = max(groups[sha256] ?? 0, copies)
            }
        }
    }

    /// Whether a finding of `check` for the photo is kept anyway.
    func keeps(_ check: HealthCheck.Kind, contentKey: Data?, path: String, size: Int64, modified: Date) -> Bool {
        keptAnyway.contains { $0.keeps(check, contentKey: contentKey, path: path, size: size, modified: modified) }
    }

    /// Whether `check` has anything kept anyway.
    func keepsAny(_ check: HealthCheck.Kind) -> Bool {
        keptAnyway.contains { $0.check == check }
    }

    // MARK: - The file

    /// `Health.json` in `paths.definitions`.
    public static func url(in paths: LibraryPaths) -> URL {
        paths.definitions.appending(path: fileName)
    }

    /// The definitions at `url`; empty ones when there's no file.
    public static func load(from url: URL) throws -> HealthDefinitions {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return HealthDefinitions()
        }
        return try HealthDefinitions(json: JSONDecoder().decode(JSONValue.self, from: data))
    }

    /// Writes the definitions to `url` whole, replacing what's there in one step.
    public func save(to url: URL) throws {
        guard isWritable else { throw HealthError.newerDefinitions(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(json)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        Self.cache.withLock { $0[url.path] = nil }
    }

    /// The definitions at `url`, read again only when the file changed since they were last read
    /// here; empty ones when it's missing or can't be read.
    static func cached(at url: URL) -> HealthDefinitions {
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
        ])
        let stamp = values.map { "\($0.contentModificationDate?.timeIntervalSince1970 ?? 0) \($0.fileSize ?? 0)" }
        guard let stamp else { return HealthDefinitions() }
        if let found = cache.withLock({ $0[url.path] }), found.stamp == stamp {
            return found.definitions
        }
        let definitions = (try? load(from: url)) ?? HealthDefinitions()
        cache.withLock { $0[url.path] = (stamp, definitions) }
        return definitions
    }

    private static let cache = Mutex<[String: (stamp: String, definitions: HealthDefinitions)]>([:])

    // MARK: - JSON

    init(json: JSONValue) throws {
        guard case let .object(object) = json else { throw HealthError.unreadableDefinitions }
        self.init()
        if case let .number(version)? = object["version"] {
            fileVersion = Int(version)
        }
        if case let .array(entries)? = object["keptAnyway"] {
            keptAnyway = entries.compactMap(KeptAnyway.init(json:))
        }
        let known: Set = ["format", "version", "keptAnyway"]
        unknownFields = object.filter { !known.contains($0.key) }
    }

    var json: JSONValue {
        var object = unknownFields
        object["format"] = .string(Self.format)
        object["version"] = .number(Double(max(fileVersion, Self.version)))
        object["keptAnyway"] = .array(keptAnyway.map(\.json))
        return .object(object)
    }
}

extension KeptAnyway {
    private static let known: Set = ["check", "contentKey", "path", "size", "modified", "sha256", "copies"]

    /// An entry as the file has it; nil for one this build can't read, which is dropped.
    init?(json: JSONValue) {
        guard case let .object(object) = json, case let .string(name)? = object["check"],
              let check = HealthCheck.Kind(rawValue: name)
        else { return nil }
        func number(_ key: String) -> Double? {
            if case let .number(value)? = object[key] {
                return value
            }
            return nil
        }
        if case let .string(hex)? = object["contentKey"], let key = ContentKey(hex: hex) {
            let modified = number("modified").map(Date.init(timeIntervalSince1970:))
            self.init(check: check, key: .content(key, modified: modified))
        } else if case let .string(hex)? = object["sha256"], let sha256 = Data(hex: hex),
                  let copies = number("copies") {
            self.init(check: check, key: .group(sha256: sha256, copies: Int(copies)))
        } else if case let .string(path)? = object["path"], let size = number("size"),
                  let modified = number("modified") {
            self.init(
                check: check,
                key: .file(path: path, size: Int64(size), modified: Date(timeIntervalSince1970: modified)),
            )
        } else {
            return nil
        }
        unknownFields = object.filter { !Self.known.contains($0.key) }
    }

    var json: JSONValue {
        var object = unknownFields
        object["check"] = .string(check.rawValue)
        switch key {
        case let .content(key, modified):
            object["contentKey"] = .string(key.hex)
            if let modified {
                object["modified"] = .number(modified.timeIntervalSince1970)
            }
        case let .file(path, size, modified):
            object["path"] = .string(path)
            object["size"] = .number(Double(size))
            object["modified"] = .number(modified.timeIntervalSince1970)
        case let .group(sha256, copies):
            object["sha256"] = .string(sha256.hex)
            object["copies"] = .number(Double(copies))
        }
        return .object(object)
    }
}

extension Data {
    /// The bytes `hex` spells, in either case; nil unless it's pairs of hexadecimal digits.
    init?(hex: String) {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index ..< index + 2], as: UTF8.self), radix: 16) else {
                return nil
            }
            bytes.append(byte)
        }
        self.init(bytes)
    }

    /// Lowercase hexadecimal digits, two a byte.
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
