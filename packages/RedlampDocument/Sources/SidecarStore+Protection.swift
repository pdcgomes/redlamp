import Foundation
import RedlampEngineAPI

/// Why a sidecar on disk must be left as it is: saving over it or deleting it would lose an
/// edit this build can't fully read.
public enum SidecarProtection: Equatable, Sendable {
    /// Its file format or process version is newer than this build's.
    case writtenByNewerVersion
    /// Its edit isn't a JSON object: no Redlamp wrote it as it is, and none can read it. It can
    /// be set aside for a new edit (`setAsideDamagedEdit(for:)`).
    case damaged
    /// Its edit can't be opened or doesn't decode: a newer Redlamp added a value this build
    /// doesn't know, or it is there but can't be read now (no permission, an I/O error, or
    /// iCloud Drive can't download it).
    case unreadable
    /// Saving it back would drop or change something: a field a newer Redlamp added where this
    /// build doesn't keep it, or a value this build can't hold.
    case lossy
}

/// Sidecars that must be left as they are, and when an emptied one can go.
public extension SidecarStore {
    /// Why the image's sidecar must be left as it is, or nil if it can be saved over or
    /// deleted (including when there is none, or a package has no edit in it).
    func protection(for image: URL) -> SidecarProtection? {
        let sidecar = url(for: image)
        do {
            return try Self.reading(sidecar) { Self.protection(atSidecar: $0) }
        } catch {
            return Self.isPresent(sidecar) ? .unreadable : nil
        }
    }
}

extension SidecarStore {
    /// The edit on disk, without its bitmaps; nil if there is none. Throws if it is protected, or
    /// the read's error if it can't be read now.
    static func existing(at destination: URL) throws -> Sidecar? {
        guard let data = try editData(inSidecar: destination) else { return nil }
        if isDamaged(data) {
            throw SidecarStoreError.damaged(destination)
        }
        if isNewer(data) {
            throw SidecarStoreError.writtenByNewerVersion(destination)
        }
        guard let existing = try? JSONDecoder.sidecar.decode(Sidecar.self, from: data) else {
            throw SidecarStoreError.unreadable(destination)
        }
        if wouldLose(data, decoding: existing) {
            throw SidecarStoreError.lossy(destination)
        }
        return existing
    }

    /// Whether saving `sidecar` at `destination` would leave nothing worth keeping.
    static func leavesNothing(_ sidecar: Sidecar, at destination: URL) throws -> Bool {
        var merged = sidecar
        if let existing = try existing(at: destination) {
            merged.unknownFields.merge(existing.unknownFields) { new, _ in new }
        }
        guard merged.isPristine else { return false }
        let open = sidecar.session.map { "\($0.id.uuidString).json" }
        return sidecar.clearsHistory || historyFiles(in: destination).allSatisfy { $0.lastPathComponent == open }
    }

    /// The edit's bytes; nil when there is none. Throws the read's error when it is there but
    /// can't be read now (no permission, an I/O error, a download that hasn't happened), which
    /// saves report and try again; `protection(atSidecar:)` takes it for `.unreadable`.
    static func editData(inSidecar sidecar: URL) throws -> Data? {
        let edit = editURL(inSidecar: sidecar)
        guard isPresent(edit) else { return nil }
        return try Data(contentsOf: edit)
    }

    /// Why the sidecar at `sidecar` must be left as it is; call it under coordination.
    static func protection(atSidecar sidecar: URL) -> SidecarProtection? {
        do {
            return try editData(inSidecar: sidecar).flatMap(protection)
        } catch {
            return .unreadable
        }
    }

    /// Whether `url` is there, downloaded or not: iCloud Drive leaves a placeholder in place of
    /// a file it evicted.
    static func isPresent(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: url.path) || FileManager.default
            .fileExists(atPath: placeholder.path)
    }

    static func protection(_ data: Data) -> SidecarProtection? {
        if isDamaged(data) {
            return .damaged
        }
        if isNewer(data) {
            return .writtenByNewerVersion
        }
        guard let decoded = try? JSONDecoder.sidecar.decode(Sidecar.self, from: data) else { return .unreadable }
        return wouldLose(data, decoding: decoded) ? .lossy : nil
    }

    // MARK: - Round trip

    /// Whether saving `decoded`, read from `data`, would drop or change something in the file:
    /// a field this build ignores, or a value it changed on reading (clamped into range, say).
    /// Keys left out because they hold the default, and upgrades from older formats (the format
    /// version, a base look's old id), aren't losses.
    static func wouldLose(_ data: Data, decoding decoded: Sidecar) -> Bool {
        let decoder = JSONDecoder()
        guard let original = try? decoder.decode(JSONValue.self, from: data),
              let encoded = try? JSONEncoder.sidecar.encode(decoded),
              let written = try? decoder.decode(JSONValue.self, from: encoded)
        else { return true }
        return JSONPatch.diff(from: original, to: written).contains { operation in
            switch operation.op {
            case .add: false
            case .replace: !isUpgrade(
                    from: value(at: operation.path, in: original),
                    to: operation.value,
                    at: operation.path,
                )
            case .remove: isArrayElement(operation.path, in: original)
                || isIgnored(operation.path, in: original, decoded: decoded)
            }
        }
    }

    /// Whether `path` is an element of an array: dropping one is always a loss, though no
    /// other value there would change what this build reads.
    private static func isArrayElement(_ path: String, in original: JSONValue) -> Bool {
        guard let slash = path.lastIndex(of: "/"), Int(path[path.index(after: slash)...]) != nil,
              case .array = value(at: String(path[..<slash]), in: original)
        else { return false }
        return true
    }

    /// Whether this build ignores the key at `path`: no other value there changes what it reads.
    /// A key it reads but leaves out when it holds the default isn't ignored.
    private static func isIgnored(_ path: String, in original: JSONValue, decoded: Sidecar) -> Bool {
        guard let value = value(at: path, in: original) else { return false }
        return probes(for: value).allSatisfy { probe in
            guard let probed = try? JSONPatch.apply([JSONPatch.Operation(.replace, path, probe)], to: original),
                  let data = try? JSONEncoder().encode(probed),
                  let reread = try? JSONDecoder.sidecar.decode(Sidecar.self, from: data)
            else { return false }
            return reread == decoded
        }
    }

    /// Other values of the same kind, or of another kind for containers and null. Numbers move
    /// both ways, so a default at the end of a range still changes.
    private static func probes(for value: JSONValue) -> [JSONValue] {
        switch value {
        case let .bool(bool): [.bool(!bool)]
        case let .number(number): [.number(number + 1), .number(number - 1)]
        case let .integer(number): [.integer(number &+ 1), .integer(number &- 1)]
        case let .unsignedInteger(number): [.unsignedInteger(number &+ 1), .unsignedInteger(number &- 1)]
        case let .string(string): [.string(string + "~")]
        case .null, .array, .object: [.string("~")]
        }
    }

    private static func isUpgrade(from old: JSONValue?, to new: JSONValue?, at path: String) -> Bool {
        switch (path.split(separator: "/").last, old, new) {
        case let ("version", .number(old), .number(new)):
            old < new && new == Double(EditRecipe.formatVersion)
        case let ("id", .string(old), .string(new)):
            BuiltInBaseLook(legacyID: old)?.rawValue == new
        default:
            false
        }
    }

    /// The value at a JSON Pointer `path`.
    private static func value(at path: String, in document: JSONValue) -> JSONValue? {
        let tokens = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        return tokens.reduce(Optional(document)) { value, token in
            let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch value {
            case let .object(object): return object[key]
            case let .array(array): return Int(key).flatMap { array.indices.contains($0) ? array[$0] : nil }
            default: return nil
            }
        }
    }

    /// Whether `data` isn't a JSON object, as a truncated or overwritten file isn't.
    static func isDamaged(_ data: Data) -> Bool {
        guard case .object = try? JSONDecoder().decode(JSONValue.self, from: data) else { return true }
        return false
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
