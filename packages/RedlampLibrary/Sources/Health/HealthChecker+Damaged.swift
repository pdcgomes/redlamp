import Foundation
import RedlampDocument

extension HealthChecker {
    /// Photos whose health says they're damaged, and those marked unreadable without one, but not
    /// those still being written. Those Redlamp may not read are listed with nothing proposed.
    func damaged(store: ColumnStore?) async throws -> HealthFindings {
        let definitions = definitions
        let settled = now().addingTimeInterval(-Self.settling)
        let unreadable = store.map { store in
            var ids: [Int64] = []
            store.rows(matching: .leaf(.state(UInt8(PhotoRecord.State.unreadable.rawValue))), sets: [:]).forEach {
                ids.append(store.ids[$0])
                return true
            }
            return ids
        }
        let found = try await index.read { reader -> [(PhotoRecord, String, PhotoHealth.Damage)] in
            let health = try reader.photoHealth()
            var damage = health.compactMapValues(\.health.damage)
            let marked = try unreadable ?? reader.unreadablePhotoIDs()
            for id in marked where damage[id] == nil {
                damage[id] = .unreadable("")
            }
            return try reader.photosWithPaths(damage.keys.sorted()).compactMap { photo, folder in
                damage[photo.id].map { (photo, folder, $0) }
            }
        }
        var findings: [HealthFinding] = []
        var kept = 0
        for (photo, folder, damage) in found {
            guard !photo.state.contains(.settling), photo.modified <= settled else { continue }
            if definitions.keeps(
                .damaged, contentKey: photo.contentKey, path: folder + "/" + photo.name, size: photo.size,
                modified: photo.modified,
            ) {
                kept += 1
                continue
            }
            findings.append(HealthFinding(
                photo: photo.id, check: .damaged, reason: .damage(damage), proposal: damage.isForbidden ? nil : .trash,
                apart: Self.isDecided(photo) ? .decided : nil,
            ))
        }
        return HealthFindings(check: .damaged, findings: Self.byPath(findings, found), keptAnyway: kept)
    }
}
