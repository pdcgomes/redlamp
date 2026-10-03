import Foundation

public extension SidecarStore {
    /// Conflicting copies, made when the same photo was edited on two Macs before iCloud Drive
    /// synced them. The most recently modified edit wins, and every other distinct edit is kept
    /// as a snapshot of the winner, so nothing is lost; snapshots of every copy are kept too.
    static func merge(_ current: Sidecar, _ conflicts: [Sidecar]) -> Sidecar {
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

    /// Merges and saves the sidecar's unresolved conflict versions, then marks them resolved;
    /// nil when there are none (or they can't be merged now, so they stay for the next load).
    internal func resolveConflicts(_ current: Sidecar, for image: URL) -> Sidecar? {
        let sidecar = url(for: image)
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: sidecar), !versions.isEmpty
        else { return nil }
        guard let merged = Self.merge(current, conflictsAt: versions.map(\.url)) else { return nil }
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
}
