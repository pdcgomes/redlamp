import Foundation

public extension SidecarStore {
    /// Conflicting copies, made when the same photo was edited on two Macs before iCloud Drive
    /// synced them. The most recently modified edit wins, and every other distinct edit is kept
    /// as a snapshot of the winner, so nothing is lost; snapshots of every copy are kept too.
    /// Rating, flag, label and unknown metadata come each from the newest copy that set it.
    static func merge(_ current: Sidecar, _ conflicts: [Sidecar]) -> Sidecar {
        let copies = [current] + conflicts
        let newest = copies.indices.reduce(0) { copies[$1].modified > copies[$0].modified ? $1 : $0 }
        var winner = copies[newest]
        let oldestFirst = copies.indices.filter { $0 != newest }.sorted { copies[$0].modified < copies[$1].modified }
        winner.metadata = (oldestFirst + [newest]).reduce(nil) { merged, index in
            PhotoMetadata.merge(merged, copies[index].metadata, base: nil, opened: merged)
        }
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

    /// `current` merged with the conflicting copies at `versions`; nil when this build can't
    /// read one of them without losing something (see `protection(for:)`), so that every copy
    /// stays unresolved for a build that can.
    static func merge(_ current: Sidecar, conflictsAt versions: [URL]) -> Sidecar? {
        var conflicts: [Sidecar] = []
        for version in versions {
            guard let data = try? Data(contentsOf: editURL(inSidecar: version)), protection(data) == nil,
                  let conflict = decode(sidecar: version)
            else { return nil }
            conflicts.append(conflict)
        }
        return merge(current, conflicts)
    }

    /// Whether the image's sidecar has conflicting copies still unresolved: once `load` has
    /// run, ones this build couldn't merge.
    func hasUnmergedConflicts(for image: URL) -> Bool {
        !conflicts.versions(url(for: image)).isEmpty
    }

    /// Merges and saves the sidecar's unresolved conflict versions, then marks them resolved and
    /// removes them; nil when there are none (or they can't be merged now, so they stay for the
    /// next load).
    internal func resolveConflicts(_ current: Sidecar, for image: URL) -> Sidecar? {
        let sidecar = url(for: image)
        let versions = conflicts.versions(sidecar)
        guard !versions.isEmpty else { return nil }
        guard let merged = Self.merge(current, conflictsAt: versions.map(\.url)) else { return nil }
        do {
            try save(merged, for: image)
            try Self.writing(sidecar, options: []) { url in
                for version in versions {
                    try Self.copyHistory(from: version.url, into: url)
                }
            }
            for version in versions {
                version.resolve()
            }
            // Only the versions merged: one that arrived since stays for the next load.
            try Self.writing(sidecar, options: []) { _ in
                for version in versions {
                    try version.remove()
                }
            }
            return merged
        } catch {
            return nil
        }
    }
}

/// A conflicting copy of a sidecar, kept until it's resolved: one of iCloud Drive's
/// `NSFileVersion`s.
protocol SidecarConflict {
    /// Where its copy of the sidecar is.
    var url: URL { get }
    /// Marks it resolved, so it isn't found again.
    func resolve()
    func remove() throws
}

extension NSFileVersion: SidecarConflict {
    func resolve() {
        isResolved = true
    }
}

/// Where a store finds a sidecar's unresolved conflicting copies.
struct SidecarConflicts: Sendable {
    let versions: @Sendable (_ sidecar: URL) -> [any SidecarConflict]

    static let iCloudDrive = SidecarConflicts { NSFileVersion.unresolvedConflictVersionsOfItem(at: $0) ?? [] }
}
