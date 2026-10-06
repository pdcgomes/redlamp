import Foundation
import RedlampDocument

extension HealthChecker {
    /// Photos whose health says they're damaged, and those marked unreadable without one, but not
    /// those still being written.
    func damaged(store: ColumnStore?) async throws -> HealthFindings {
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
        for (photo, _, damage) in found {
            guard !photo.state.contains(.settling), photo.modified <= settled else { continue }
            findings.append(HealthFinding(
                photo: photo.id, check: .damaged, reason: .damage(damage), proposal: .trash,
                apart: Self.isDecided(photo) ? .decided : nil,
            ))
        }
        return HealthFindings(check: .damaged, findings: Self.byPath(findings, found))
    }
}
