import Foundation
import RedlampEngineAPI

/// Why a sidecar on disk must be left as it is: saving over it or deleting it would lose an
/// edit this build can't fully read.
public enum SidecarProtection: Equatable, Sendable {
    /// Its file format or process version is newer than this build's.
    case writtenByNewerVersion
    /// Its edit doesn't decode: a newer Redlamp added a value this build doesn't know, or the
    /// file is damaged.
    case unreadable
}

/// Sidecars that must be left as they are, and when an emptied one can go.
public extension SidecarStore {
    /// Whether the image's sidecar uses a file format or process version this build
    /// doesn't have. Such edits can be shown, but saving would lose information.
    func isWrittenByNewerVersion(for image: URL) -> Bool {
        protection(for: image) == .writtenByNewerVersion
    }

    /// Why the image's sidecar must be left as it is, or nil if it can be saved over or
    /// deleted (including when there is none, or a package has no edit in it).
    func protection(for image: URL) -> SidecarProtection? {
        let sidecar = url(for: image)
        return (try? Self.reading(sidecar) { url in
            (try? Data(contentsOf: Self.editURL(inSidecar: url))).flatMap(Self.protection)
        }) ?? nil
    }
}

extension SidecarStore {
    /// The edit on disk, without its bitmaps; nil if there is none. Throws if it is protected.
    static func existing(at destination: URL) throws -> Sidecar? {
        guard let data = try? Data(contentsOf: editURL(inSidecar: destination)) else { return nil }
        if isNewer(data) {
            throw SidecarStoreError.writtenByNewerVersion(destination)
        }
        guard let existing = try? JSONDecoder.sidecar.decode(Sidecar.self, from: data) else {
            throw SidecarStoreError.unreadable(destination)
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

    static func protection(_ data: Data) -> SidecarProtection? {
        if isNewer(data) {
            return .writtenByNewerVersion
        }
        return (try? JSONDecoder.sidecar.decode(Sidecar.self, from: data)) == nil ? .unreadable : nil
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
