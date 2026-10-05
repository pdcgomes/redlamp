import CryptoKit
import Foundation
import RedlampEngineAPI

/// A sidecar as an editor last read or wrote it, so a save can tell when another writer (another
/// Mac through iCloud Drive or Dropbox, a second Redlamp) has saved it since. Kept in memory only.
public struct SidecarBase: Sendable, Hashable {
    /// SHA-256 of the edit's bytes; nil when there was none.
    let digest: Data?
    /// The edit as it was then.
    public let sidecar: Sidecar?
}

/// What a save over a base did.
public enum SidecarSaveOutcome: Sendable {
    /// Written (or removed) as asked: the disk was as the base had it.
    case saved(SidecarBase)
    /// Another writer had saved it and nothing here had changed, so nothing was written: their
    /// edit (nil: they removed it) stands.
    case theirs(SidecarBase)
    /// Both had changed it: what each changed alone was kept, and where both changed the edit,
    /// the newer won and the other became an "Edit from another Mac" snapshot.
    case merged(SidecarBase)
}

/// A sidecar as an editor reads it to open a photo: its edit, the base its saves go over, and
/// why it must be left as it is, all from one coordinated read.
public struct SidecarRead: Sendable {
    public var sidecar: Sidecar?
    public var base: SidecarBase
    public var protection: SidecarProtection?
    /// It is there but couldn't be read (no permission, an I/O error, another app's file
    /// presenter): `protection` is `.unreadable`, and reading it again may work.
    public var failed: Bool
}

public extension SidecarStore {
    /// The image's sidecar to edit. One read, so the base can't come from another file than
    /// the edit: a save over an edit that wasn't read would write over it.
    func readForEditing(for image: URL) -> SidecarRead {
        let sidecar = url(for: image)
        let read: (data: Data?, protection: SidecarProtection?, decoded: Sidecar?)
        do {
            read = try Self.reading(sidecar) { url in
                guard let data = try Self.editData(inSidecar: url) else { return (nil, nil, nil) }
                let protection = Self.protection(data)
                return (data, protection, protection == .unreadable ? nil : Self.decode(data, inSidecar: url))
            }
        } catch {
            let none = SidecarBase(digest: nil, sidecar: nil)
            guard Self.isPresent(Self.editURL(inSidecar: sidecar)) else {
                return SidecarRead(sidecar: nil, base: none, protection: nil, failed: false)
            }
            return SidecarRead(sidecar: nil, base: none, protection: .unreadable, failed: true)
        }
        let loaded = read.decoded.map { resolveConflicts($0, for: image) ?? $0 }
        let digest = read.data.map { Data(SHA256.hash(data: $0)) }
        return SidecarRead(
            sidecar: loaded, base: SidecarBase(digest: digest, sidecar: loaded), protection: read.protection,
            failed: false,
        )
    }

    /// The image's sidecar, and its base for `saveOrRemove(_:for:over:opened:)`.
    func loadWithBase(for image: URL) -> (sidecar: Sidecar?, base: SidecarBase) {
        // The digest first: a save landing between the two then looks like another writer's,
        // never the other way round.
        let digest = (try? Self.reading(url(for: image)) { try Self.digest(at: $0) }) ?? nil
        let sidecar = load(for: image)
        return (sidecar, SidecarBase(digest: digest, sidecar: sidecar))
    }

    /// The base of the sidecar as it is now.
    func base(for image: URL) -> SidecarBase {
        loadWithBase(for: image).base
    }

    /// Saves `sidecar`, or removes it as `saveOrRemove(_:for:)` does, unless another writer has
    /// saved it since `base`: then what changed here since `opened` (the editor's state when it
    /// took `base`) is merged into theirs, or, with nothing changed here, nothing is written.
    /// Throws, changing nothing, if their edit is protected (see `protection(for:)`).
    func saveOrRemove(
        _ sidecar: Sidecar, for image: URL, over base: SidecarBase, opened: Sidecar,
    ) throws -> SidecarSaveOutcome {
        let destination = url(for: image)
        let options: NSFileCoordinator.WritingOptions = Self.isPackage(destination) ? [] : .forReplacing
        return try Self.writing(destination, options: options) { destination in
            try makeFolder(for: destination, of: image)
            guard try Self.digest(at: destination) == base.digest else {
                return try Self.saveOverOtherWriter(sidecar, at: destination, base: base, opened: opened)
            }
            if try Self.leavesNothing(sidecar, at: destination) {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try Self.remove(destination)
                }
                return .saved(SidecarBase(digest: nil, sidecar: nil))
            }
            try Self.write(sidecar, to: destination)
            return try .saved(SidecarBase(digest: Self.digest(at: destination), sidecar: sidecar))
        }
    }

    /// The edit `saveOrRemove(_:for:over:opened:)` would leave if another writer has saved
    /// since `base`, without writing anything: for an editor to show while its saves fail. Nil
    /// when none has, they removed it, or it is protected or can't be read.
    func mergedWithOtherWriter(
        _ sidecar: Sidecar,
        for image: URL,
        over base: SidecarBase,
        opened: Sidecar,
    ) -> Sidecar? {
        let merged = try? Self.reading(url(for: image)) { destination -> Sidecar? in
            guard try Self.digest(at: destination) != base.digest, try Self.existing(at: destination) != nil,
                  let theirs = Self.decode(sidecar: destination)
            else { return nil }
            guard !sidecar.hasSameContent(as: opened) else { return theirs }
            return Self.merge(sidecar, theirs, base: base.sidecar ?? Sidecar(recipe: EditRecipe()), opened: opened)
        }
        return merged ?? nil
    }
}

extension SidecarStore {
    static func digest(at sidecar: URL) throws -> Data? {
        try editData(inSidecar: sidecar).map { Data(SHA256.hash(data: $0)) }
    }

    private static func saveOverOtherWriter(
        _ ours: Sidecar, at destination: URL, base: SidecarBase, opened: Sidecar,
    ) throws -> SidecarSaveOutcome {
        _ = try existing(at: destination)
        let digest = try digest(at: destination)
        let theirs = decode(sidecar: destination)
        guard !ours.hasSameContent(as: opened) else {
            return .theirs(SidecarBase(digest: digest, sidecar: theirs))
        }
        guard let theirs else {
            // They removed it: what is changed here stands.
            try write(ours, to: destination)
            return try .merged(SidecarBase(digest: Self.digest(at: destination), sidecar: ours))
        }
        let merged = merge(ours, theirs, base: base.sidecar ?? Sidecar(recipe: EditRecipe()), opened: opened)
        try write(merged, to: destination)
        return try .merged(SidecarBase(digest: Self.digest(at: destination), sidecar: merged))
    }

    /// Three-way: each field one side changed alone takes that side's value; an edit both
    /// changed goes to the newer, the other kept as a snapshot. Every snapshot of both is kept,
    /// and this session's history is written beside theirs.
    public static func merge(_ ours: Sidecar, _ theirs: Sidecar, base: Sidecar, opened: Sidecar) -> Sidecar {
        var merged = ours
        switch (ours.recipe != opened.recipe, theirs.recipe != base.recipe) {
        case (true, true):
            let newer = merge(ours, [theirs])
            merged.recipe = newer.recipe
            merged.snapshots = newer.snapshots
        case (false, _):
            merged.recipe = theirs.recipe
        case (true, false):
            break
        }
        for snapshot in ours.snapshots + theirs.snapshots
            where !merged.snapshots.contains(where: { $0.id == snapshot.id }) {
            merged.snapshots.append(snapshot)
        }
        merged.metadata = PhotoMetadata.merge(
            ours.metadata, theirs.metadata, base: base.metadata, opened: opened.metadata,
        )
        merged.unknownFields = theirs.unknownFields.merging(ours.unknownFields) { _, new in new }
        merged.session = ours.session
        merged.clearsHistory = false
        merged.modified = max(ours.modified, theirs.modified)
        return merged
    }
}

extension PhotoMetadata {
    /// Three-way, field by field: each field (an unknown one by its key) takes theirs if only
    /// they changed it since `base`, and ours, changed here since `opened` or not, otherwise.
    /// Nil when nothing is left of either.
    static func merge(
        _ ours: PhotoMetadata?, _ theirs: PhotoMetadata?, base: PhotoMetadata?, opened: PhotoMetadata?,
    ) -> PhotoMetadata? {
        guard ours != nil || theirs != nil else { return nil }
        let (ours, theirs) = (ours ?? PhotoMetadata(), theirs ?? PhotoMetadata())
        let (base, opened) = (base ?? PhotoMetadata(), opened ?? PhotoMetadata())
        func pick<Value: Equatable>(_ field: (PhotoMetadata) -> Value) -> Value {
            field(theirs) != field(base) && field(ours) == field(opened) ? field(theirs) : field(ours)
        }
        var merged = PhotoMetadata(
            rating: pick(\.rating), flag: pick(\.flag), label: pick(\.label), originalName: pick(\.originalName),
        )
        for key in Set(ours.unknownFields.keys).union(theirs.unknownFields.keys) {
            merged.unknownFields[key] = pick { $0.unknownFields[key] }
        }
        return merged.isEmpty ? nil : merged
    }
}
