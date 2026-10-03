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
    /// The open session's history. Saving writes it to `history/<id>.json` beside the edit, or
    /// removes that file while the session has no edits; `nil` leaves history alone. Loading
    /// leaves it `nil`: `SidecarStore.loadHistory` reads the sessions.
    public var session: HistorySession?
    /// Saving removes every other session's history (Clear History).
    public var clearsHistory = false

    public init(
        recipe: EditRecipe,
        snapshots: [Snapshot] = [],
        metadata: PhotoMetadata? = nil,
        modified: Date = Date(),
        session: HistorySession? = nil,
    ) {
        self.recipe = recipe
        self.snapshots = snapshots
        self.metadata = metadata
        self.modified = modified
        self.session = session
    }

    /// Nothing worth keeping: the file can be deleted, unless earlier sessions' history is in it.
    public var isPristine: Bool {
        recipe.isPristine && snapshots.isEmpty && (metadata?.isEmpty ?? true) && unknownFields.isEmpty
            && session?.hasEdits != true
    }

    /// Same edit, ratings and snapshots, whenever it was written.
    func hasSameContent(as other: Sidecar) -> Bool {
        var other = other
        other.modified = modified
        other.session = session
        other.clearsHistory = clearsHistory
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
    /// The sidecar exists but this build can't decode it (damaged, or a value it doesn't know).
    /// It may still hold an edit, history and masks, so it is never overwritten or deleted.
    case unreadable(URL)
}

/// Reads and writes sidecars.
///
/// A sidecar is a package, `IMG_1234.CR3.redlamp/`, holding the edit as `edit.json`, mask
/// bitmaps as `masks/<sha256>.png` and each history session as `history/<id>.json`. Sidecars
/// written before packages are a single JSON file at the same path; they are read as they are and
/// become packages on their next save. The JSON is written atomically, and bitmaps are
/// content-addressed and written before the JSON that names them, so a crash never leaves an edit
/// pointing at a missing or torn file.
///
/// Every read and write is coordinated (`NSFileCoordinator`), so iCloud Drive and other
/// presenters never see a half-written package, and a read waits for a sidecar iCloud Drive
/// has evicted to download. Conflicting copies from two Macs are resolved on load (see `merge`).
public struct SidecarStore: Sendable {
    public static let editFile = "edit.json"
    public static let masksDirectory = "masks"
    public static let historyDirectory = "history"
    /// The history sessions a photo keeps; the oldest go as new ones are written.
    public static let keptSessions = 20

    public init() {}

    /// The sidecar: a package, or a single file written before packages.
    public func url(for image: URL) -> URL {
        image.appendingPathExtension("redlamp")
    }

    /// The edit's JSON: `edit.json` in a package, or the single-file sidecar itself.
    public func editURL(for image: URL) -> URL {
        Self.editURL(inSidecar: url(for: image))
    }

    public func bitmapURL(_ sha256: String, for image: URL) -> URL {
        Self.bitmapURL(sha256, inSidecar: url(for: image))
    }

    /// Whether reading the sidecar can't block on a download: it is missing, local, or
    /// already downloaded from iCloud Drive.
    public func isAvailableLocally(for image: URL) -> Bool {
        let status = try? url(for: image).resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        return status == nil || status == .current || status == .downloaded
    }

    public func load(for image: URL) -> Sidecar? {
        let sidecar = url(for: image)
        guard let loaded = (try? Self.reading(sidecar) { Self.decode(sidecar: $0) }) ?? nil else { return nil }
        return resolveConflicts(loaded, for: image) ?? loaded
    }

    /// Whether the image's sidecar uses a file format or process version this build
    /// doesn't have. Such edits can be shown, but saving would lose information.
    public func isWrittenByNewerVersion(for image: URL) -> Bool {
        let sidecar = url(for: image)
        return (try? Self.reading(sidecar) { url in
            (try? Data(contentsOf: Self.editURL(inSidecar: url))).map(Self.isNewer) ?? false
        }) ?? false
    }

    /// Whether the image has a sidecar this build can't decode, though no newer Redlamp wrote it.
    /// The photo shows unedited, and its sidecar is left as it is.
    public func isUnreadable(for image: URL) -> Bool {
        let sidecar = url(for: image)
        return (try? Self.reading(sidecar) { url in
            (try? Data(contentsOf: Self.editURL(inSidecar: url))).map { !Self.isNewer($0) && !Self.decodes($0) }
                ?? false
        }) ?? false
    }

    /// Whether the image's sidecar must not be saved over or deleted: a newer Redlamp wrote it, or
    /// this build can't read it.
    public func isReadOnly(for image: URL) -> Bool {
        isWrittenByNewerVersion(for: image) || isUnreadable(for: image)
    }

    /// Writes the sidecar unless nothing but `modified` changed, so unchanged edits don't
    /// wake up sync services. Fields a newer Redlamp added to the file on disk are kept.
    public func save(_ sidecar: Sidecar, for image: URL) throws {
        let destination = url(for: image)
        let options: NSFileCoordinator.WritingOptions = Self.isPackage(destination) ? [] : .forReplacing
        try Self.writing(destination, options: options) { destination in
            try Self.write(sidecar, to: destination)
        }
    }

    /// Removes the sidecar, unless a newer Redlamp wrote it or this build can't read it.
    public func delete(for image: URL) {
        let sidecar = url(for: image)
        try? Self.writing(sidecar, options: .forDeleting) { url in
            if let data = try? Data(contentsOf: Self.editURL(inSidecar: url)),
               Self.isNewer(data) || !Self.decodes(data) {
                return
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Conflicts

    /// Conflicting copies, made when the same photo was edited on two Macs before iCloud Drive
    /// synced them. The most recently modified edit wins, and every other distinct edit is kept
    /// as a snapshot of the winner, so nothing is lost; snapshots of every copy are kept too.
    public static func merge(_ current: Sidecar, _ conflicts: [Sidecar]) -> Sidecar {
        let copies = [current] + conflicts
        var winner = copies.reduce(current) { $1.modified > $0.modified ? $1 : $0 }
        var snapshots = winner.snapshots
        for copy in copies {
            for snapshot in copy.snapshots where !snapshots.contains(where: { $0.id == snapshot.id }) {
                snapshots.append(snapshot)
            }
        }
        for copy in copies
            where copy.recipe != winner.recipe && !snapshots.contains(where: { $0.recipe == copy.recipe }) {
            snapshots.append(Snapshot(
                name: "Edit from another Mac, \(copy.modified.formatted(date: .abbreviated, time: .shortened))",
                created: copy.modified,
                recipe: copy.recipe,
            ))
        }
        winner.snapshots = snapshots
        for copy in copies {
            winner.unknownFields.merge(copy.unknownFields) { kept, _ in kept }
        }
        return winner
    }

    /// Merges and saves the sidecar's unresolved conflict versions, then marks them resolved;
    /// nil when there are none (or they can't be merged now, so they stay for the next load).
    private func resolveConflicts(_ current: Sidecar, for image: URL) -> Sidecar? {
        let sidecar = url(for: image)
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: sidecar), !versions.isEmpty
        else { return nil }
        let merged = Self.merge(current, versions.compactMap { Self.decode(sidecar: $0.url) })
        do {
            try save(merged, for: image)
            try Self.writing(sidecar, options: []) { url in
                for version in versions {
                    try Self.copyHistory(from: version.url, into: url)
                }
            }
            for version in versions {
                version.isResolved = true
            }
            try Self.writing(sidecar, options: []) { url in
                try NSFileVersion.removeOtherVersionsOfItem(at: url)
            }
            return merged
        } catch {
            return nil
        }
    }

    // MARK: - Files

    /// Runs `body` with coordinated read access to `url`.
    static func reading<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var result: Result<T, any Error>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError {
            throw coordinationError
        }
        return try (result ?? .failure(CocoaError(.fileReadUnknown))).get()
    }

    /// Runs `body` with coordinated write access to `url`.
    static func writing<T>(
        _ url: URL,
        options: NSFileCoordinator.WritingOptions,
        _ body: (URL) throws -> T,
    ) throws -> T {
        var result: Result<T, any Error>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: options, error: &coordinationError,
        ) { url in
            result = Result { try body(url) }
        }
        if let coordinationError {
            throw coordinationError
        }
        return try (result ?? .failure(CocoaError(.fileWriteUnknown))).get()
    }

    private static func editURL(inSidecar sidecar: URL) -> URL {
        isPackage(sidecar) ? sidecar.appending(path: editFile) : sidecar
    }

    static func bitmapURL(_ sha256: String, inSidecar sidecar: URL) -> URL {
        sidecar.appending(path: masksDirectory).appending(path: "\(sha256).png")
    }

    /// The sidecar at `sidecar` (a package or a single file), with its mask bitmaps.
    private static func decode(sidecar: URL) -> Sidecar? {
        guard let data = try? Data(contentsOf: editURL(inSidecar: sidecar)),
              var decoded = try? JSONDecoder.sidecar.decode(Sidecar.self, from: data)
        else { return nil }
        let bitmaps = { (sha: String) in try? Data(contentsOf: bitmapURL(sha, inSidecar: sidecar)) }
        decoded.recipe.loadMaskBitmaps(bitmaps)
        for index in decoded.snapshots.indices {
            decoded.snapshots[index].recipe.loadMaskBitmaps(bitmaps)
        }
        return decoded
    }

    /// The write itself, under coordination.
    private static func write(_ sidecar: Sidecar, to destination: URL) throws {
        let existingPackage = isPackage(destination)
        var sidecar = sidecar
        if let data = try? Data(contentsOf: editURL(inSidecar: destination)) {
            if isNewer(data) {
                throw SidecarStoreError.writtenByNewerVersion(destination)
            }
            guard let existing = try? JSONDecoder.sidecar.decode(Sidecar.self, from: data) else {
                throw SidecarStoreError.unreadable(destination)
            }
            sidecar.unknownFields = existing.unknownFields.merging(sidecar.unknownFields) { _, new in new }
            if existing.hasSameContent(as: sidecar), existingPackage, hasEveryBitmap(sidecar, in: destination) {
                if try writeHistory(of: sidecar, in: destination) {
                    removeUnusedBitmaps(of: sidecar, in: destination)
                }
                return
            }
        }
        let json = try JSONEncoder.sidecar.encode(sidecar)
        let fileManager = FileManager.default
        if existingPackage {
            try writeBitmaps(of: sidecar, into: destination)
            try json.write(to: destination.appending(path: editFile), options: .atomic)
            try writeHistory(of: sidecar, in: destination)
            removeUnusedBitmaps(of: sidecar, in: destination)
            return
        }
        // A new package, or a single-file sidecar becoming one: built beside it, then moved in.
        let staging = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try writeBitmaps(of: sidecar, into: staging)
            try json.write(to: staging.appending(path: editFile), options: .atomic)
            try writeHistory(of: sidecar, in: staging)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    static func isPackage(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func bitmaps(of sidecar: Sidecar) -> [MaskBitmap] {
        let session = sidecar.session.flatMap { $0.hasEdits ? $0.maskBitmaps : nil } ?? []
        return sidecar.recipe.maskBitmaps + sidecar.snapshots.flatMap(\.recipe.maskBitmaps) + session
    }

    private static func hasEveryBitmap(_ sidecar: Sidecar, in package: URL) -> Bool {
        bitmaps(of: sidecar).allSatisfy { bitmap in
            FileManager.default.fileExists(atPath: bitmapURL(bitmap.sha256, inSidecar: package).path)
        }
    }

    /// Writes the bitmaps the package doesn't have yet. A bitmap whose bytes weren't loaded is
    /// left as it is.
    private static func writeBitmaps(of sidecar: Sidecar, into package: URL) throws {
        let masks = package.appending(path: masksDirectory)
        for bitmap in bitmaps(of: sidecar) {
            let file = masks.appending(path: "\(bitmap.sha256).png")
            guard let png = bitmap.png, !FileManager.default.fileExists(atPath: file.path) else { continue }
            try FileManager.default.createDirectory(at: masks, withIntermediateDirectories: true)
            try png.write(to: file, options: .atomic)
        }
    }

    /// Bitmaps no edit, snapshot or history session names any more. Nothing is removed while a
    /// session file can't be read, since the bitmaps it needs aren't known.
    private static func removeUnusedBitmaps(of sidecar: Sidecar, in package: URL) {
        var used = Set(bitmaps(of: sidecar).map(\.sha256))
        for file in historyFiles(in: package) {
            guard let summary = historySummary(file) else { return }
            used.formUnion(summary.bitmaps ?? [])
        }
        let masks = package.appending(path: masksDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: masks.path)) ?? []
        for file in files where file.hasSuffix(".png") && !used.contains(String(file.dropLast(4))) {
            try? FileManager.default.removeItem(at: masks.appending(path: file))
        }
    }

    private static func decodes(_ data: Data) -> Bool {
        (try? JSONDecoder.sidecar.decode(Sidecar.self, from: data)) != nil
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
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
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
