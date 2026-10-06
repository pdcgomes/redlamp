import Foundation
import RedlampEngineAPI

public struct Snapshot: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var created: Date
    public var recipe: EditRecipe
    /// Fields written by a newer Redlamp, written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

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

/// Rating, flag and label: the culling metadata Lightroom lets you set while developing; the
/// photo's name before Redlamp first renamed it; and its keywords.
public struct PhotoMetadata: Sendable, Hashable {
    /// 0–5 stars.
    public var rating: Int
    public var flag: PhotoFlag?
    public var label: ColorLabel?
    /// The photo's file name before Redlamp first renamed it, `IMG_1234.CR3`, kept through every
    /// rename and move after that; nil for a photo Redlamp hasn't renamed (LIB-26).
    public var originalName: String?
    /// The photo's keywords, each its full path from the top of the keyword list with `/` between
    /// levels, `Places/Portugal/Lisbon`, and `%2F` for a slash inside a keyword, `%25` for a percent
    /// sign (LIB-21). Kept as written. Empty: the photo has none; nil: the keywords embedded in it and
    /// in other apps' `.xmp` are its keywords.
    public var keywords: [String]?
    /// Fields written by a newer Redlamp (a caption, say), written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public init(
        rating: Int = 0, flag: PhotoFlag? = nil, label: ColorLabel? = nil, originalName: String? = nil,
        keywords: [String]? = nil,
    ) {
        self.rating = min(max(rating, 0), 5)
        self.flag = flag
        self.label = label
        self.originalName = originalName
        self.keywords = keywords
    }

    public var isEmpty: Bool {
        rating == 0 && flag == nil && label == nil && originalName == nil && keywords == nil && unknownFields.isEmpty
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
    /// Earlier sessions of the photo whose saves failed, written to `history/` with this one.
    /// Never in the edit.
    public var unsavedSessions: [HistorySession] = []

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
            && session?.hasEdits != true && !unsavedSessions.contains(where: \.hasEdits)
    }

    /// Same edit, ratings and snapshots, whenever it was written. Compared as written, since the
    /// file keeps dates only to the second.
    public func hasSameContent(as other: Sidecar) -> Bool {
        var other = other
        other.modified = modified
        guard let written = try? JSONEncoder.sidecar.encode(self),
              let otherWritten = try? JSONEncoder.sidecar.encode(other)
        else { return false }
        return written == otherWritten
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
    /// The sidecar's edit isn't a JSON object. It is never overwritten or deleted, only set aside.
    case damaged(URL)
    /// The sidecar's edit doesn't decode in this build, so it is never overwritten or deleted.
    case unreadable(URL)
    /// Saving over the sidecar would drop or change what's in it, so it is never overwritten or
    /// deleted.
    case lossy(URL)
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

    /// Where its sidecars are written and read from.
    public let locator: SidecarLocator
    /// Where a sidecar's conflicting copies are found: iCloud Drive's versions, or a test's.
    let conflicts: SidecarConflicts

    /// Keeps every sidecar beside its photo.
    public init() {
        locator = .besidePhotos
        conflicts = .iCloudDrive
    }

    /// Writes each sidecar where `locator` says; `load` and `summary` read it from where
    /// `SidecarLocator.readURL(for:)` finds it.
    public init(locator: SidecarLocator) {
        self.locator = locator
        conflicts = .iCloudDrive
    }

    init(locator: SidecarLocator, conflicts: SidecarConflicts) {
        self.locator = locator
        self.conflicts = conflicts
    }

    /// The sidecar: a package, or a single file written before packages.
    public func url(for image: URL) -> URL {
        locator.url(for: image)
    }

    /// The edit's JSON: `edit.json` in a package, or the single-file sidecar itself.
    public func editURL(for image: URL) -> URL {
        Self.editURL(inSidecar: url(for: image))
    }

    public func bitmapURL(_ sha256: String, for image: URL) -> URL {
        Self.bitmapURL(sha256, inSidecar: url(for: image))
    }

    public func load(for image: URL) -> Sidecar? {
        let sidecar = locator.readURL(for: image)
        guard let loaded = (try? Self.reading(sidecar) { Self.decode(sidecar: $0) }) ?? nil else { return nil }
        return resolveConflicts(loaded, for: image) ?? loaded
    }

    /// The image's sidecar, or nil only when it has none. Where `load(for:)` takes a sidecar it
    /// can't read for none, this throws: the coordinated read's or the file's error (worth trying
    /// again), `SidecarStoreError.damaged` when the edit isn't JSON, or `.unreadable` when it
    /// doesn't decode. Use it wherever what's read is saved back.
    public func loadThrowing(for image: URL) throws -> Sidecar? {
        let sidecar = url(for: image)
        guard let loaded = try Self.reading(sidecar, { try Self.decodeThrowing(sidecar: $0) }) else { return nil }
        return resolveConflicts(loaded, for: image) ?? loaded
    }

    /// The sidecar at `sidecar` (a package or a single file, wherever it is), with its mask
    /// bitmaps, read as `loadThrowing(for:)` reads a photo's: nil when there's nothing there, and
    /// the same errors. For tools given a sidecar's path rather than its photo's.
    public func read(sidecarAt sidecar: URL) throws -> Sidecar? {
        try Self.reading(sidecar) { try Self.decodeThrowing(sidecar: $0) }
    }

    /// Writes the sidecar unless nothing but `modified` changed, so unchanged edits don't
    /// wake up sync services. Fields a newer Redlamp added to the file on disk are kept.
    public func save(_ sidecar: Sidecar, for image: URL) throws {
        let destination = url(for: image)
        let options: NSFileCoordinator.WritingOptions = Self.isPackage(destination) ? [] : .forReplacing
        try Self.writing(destination, options: options) { destination in
            try makeFolder(for: destination, of: image)
            try Self.write(sidecar, to: destination)
        }
    }

    /// Saves the sidecar, or removes it when nothing would be left worth keeping: the edit is
    /// pristine, the file on disk has no fields this build doesn't know, and no history session
    /// would remain. A photo without a sidecar doesn't get one just to hold nothing.
    public func saveOrRemove(_ sidecar: Sidecar, for image: URL) throws {
        let destination = url(for: image)
        let options: NSFileCoordinator.WritingOptions = Self.isPackage(destination) ? [] : .forReplacing
        try Self.writing(destination, options: options) { destination in
            guard try Self.leavesNothing(sidecar, at: destination) else {
                try makeFolder(for: destination, of: image)
                return try Self.write(sidecar, to: destination)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try Self.remove(destination)
            }
        }
    }

    /// Makes the folders a sidecar kept on this Mac goes in. Beside the photo there's nothing to
    /// make: the photo's folder is there, or the save fails.
    func makeFolder(for destination: URL, of image: URL) throws {
        guard destination.path != SidecarLocator.besidePhoto(image).path else { return }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
    }

    /// Removes the sidecar, history included, unless it is protected (see `protection(for:)`).
    /// To save an edit that may have gone back to defaults, use `saveOrRemove`.
    public func delete(for image: URL) {
        let sidecar = url(for: image)
        try? Self.writing(sidecar, options: .forDeleting) { url in
            if Self.protection(atSidecar: url) != nil {
                return
            }
            try Self.remove(url)
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

    static func editURL(inSidecar sidecar: URL) -> URL {
        isPackage(sidecar) ? sidecar.appending(path: editFile) : sidecar
    }

    static func bitmapURL(_ sha256: String, inSidecar sidecar: URL) -> URL {
        sidecar.appending(path: masksDirectory).appending(path: "\(sha256).png")
    }

    /// The sidecar at `sidecar` (a package or a single file), with its mask bitmaps; nil when it
    /// has none or it can't be read.
    static func decode(sidecar: URL) -> Sidecar? {
        try? decodeThrowing(sidecar: sidecar)
    }

    /// The sidecar at `sidecar`, with its mask bitmaps; nil when it has none. Throws the read's
    /// error when its edit can't be read now, `SidecarStoreError.damaged` when it isn't JSON, and
    /// `.unreadable` when it doesn't decode.
    static func decodeThrowing(sidecar: URL) throws -> Sidecar? {
        guard let data = try editData(inSidecar: sidecar) else { return nil }
        if isDamaged(data) {
            throw SidecarStoreError.damaged(sidecar)
        }
        guard let decoded = decode(data, inSidecar: sidecar) else {
            throw SidecarStoreError.unreadable(sidecar)
        }
        return decoded
    }

    /// The edit `data`, read from `sidecar`, with its mask bitmaps; nil when it doesn't decode.
    static func decode(_ data: Data, inSidecar sidecar: URL) -> Sidecar? {
        guard var decoded = try? JSONDecoder.sidecar.decode(Sidecar.self, from: data) else { return nil }
        let bitmaps = { (sha: String) in try? Data(contentsOf: bitmapURL(sha, inSidecar: sidecar)) }
        decoded.recipe.loadMaskBitmaps(bitmaps)
        for index in decoded.snapshots.indices {
            decoded.snapshots[index].recipe.loadMaskBitmaps(bitmaps)
        }
        return decoded
    }

    /// The write itself, under coordination.
    static func write(_ sidecar: Sidecar, to destination: URL) throws {
        let existingPackage = isPackage(destination)
        try write(sidecar, to: destination, over: existing(at: destination), isPackage: existingPackage)
    }

    /// The write over `existing`, the edit at `destination` as `existing(at:)` read it, a package when
    /// `existingPackage`; `edits` puts the edit's bytes in its file.
    static func write(
        _ sidecar: Sidecar, to destination: URL, over existing: Sidecar?, isPackage existingPackage: Bool,
        edits: EditWriter = .foundation,
    ) throws {
        var sidecar = sidecar
        if let existing {
            sidecar.unknownFields = existing.unknownFields.merging(sidecar.unknownFields) { _, new in new }
        }
        let json = try JSONEncoder.sidecar.encode(sidecar)
        if let existing, existing.hasSameContent(as: sidecar), existingPackage,
           hasEveryBitmap(sidecar, in: destination) {
            if try writeHistory(of: sidecar, in: destination) {
                removeUnusedBitmaps(of: sidecar, in: destination, json: json)
            }
            return
        }
        let fileManager = FileManager.default
        if existingPackage {
            // History first: an interrupted save leaves the new step in history, where it can be
            // restored, rather than an edit its history doesn't record.
            try writeBitmaps(of: sidecar, into: destination)
            try writeHistory(of: sidecar, in: destination)
            try edits.replace(json, destination.appending(path: editFile))
            removeUnusedBitmaps(of: sidecar, in: destination, json: json)
            return
        }
        // A new package, or a single-file sidecar becoming one: built beside it, then moved in.
        let staging = hiddenSibling(of: destination)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try writeBitmaps(of: sidecar, into: staging)
            try edits.create(json, staging.appending(path: editFile))
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
        let sessions = ([sidecar.session].compactMap(\.self) + sidecar.unsavedSessions).filter(\.hasEdits)
        return sidecar.recipe.maskBitmaps + sidecar.snapshots.flatMap(\.recipe.maskBitmaps)
            + sessions.flatMap(\.maskBitmaps)
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

    /// Whether any of `written` names the bitmap `sha256`, in a field this build may not know.
    static func isNamed(_ sha256: String, in written: [Data]) -> Bool {
        written.contains { $0.range(of: Data(sha256.utf8)) != nil }
    }

    /// Removes the package's bitmaps that nothing refers to: not the edit, its snapshots or its
    /// history, nor any field of `json` (the edit as written), of a history file or of a damaged
    /// edit set aside, where fields a newer build added (a mask shape this build doesn't know,
    /// say) may name one. Nothing is removed while a session file can't be read, since the
    /// bitmaps it needs aren't known.
    private static func removeUnusedBitmaps(of sidecar: Sidecar, in package: URL, json: Data) {
        var used = Set(bitmaps(of: sidecar).map(\.sha256))
        var written = [json] + damagedCopies(in: package).compactMap { try? Data(contentsOf: $0) }
        for file in historyFiles(in: package) {
            guard let data = try? Data(contentsOf: file),
                  let summary = try? JSONDecoder.sidecar.decode(HistoryFile.Summary.self, from: data)
            else { return }
            used.formUnion(summary.bitmaps ?? [])
            written.append(data)
        }
        let masks = package.appending(path: masksDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: masks.path)) ?? []
        for file in files where file.hasSuffix(".png") {
            let sha256 = String(file.dropLast(4))
            if !used.contains(sha256), !isNamed(sha256, in: written) {
                try? FileManager.default.removeItem(at: masks.appending(path: file))
            }
        }
    }
}

/// How a save puts an edit's bytes in its file.
struct EditWriter: Sendable {
    /// Replaces the edit of a package, atomically.
    let replace: @Sendable (Data, URL) throws -> Void
    /// Writes the edit of a package being built, which nothing reads before it's moved into place.
    let create: @Sendable (Data, URL) throws -> Void

    /// As single saves write it: `Data.write(options: .atomic)`.
    static let foundation = EditWriter(
        replace: { try $0.write(to: $1, options: .atomic) }, create: { try $0.write(to: $1, options: .atomic) },
    )
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
