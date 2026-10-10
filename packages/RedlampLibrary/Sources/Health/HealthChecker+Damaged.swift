import Foundation
import RedlampDocument

/// The photos the damaged files check lists, without their findings (`is:damaged`), and what else decides which.
struct DamagedPhotos: Sendable, Hashable {
    /// In ID order.
    var photos: [Int64]
    /// The check's findings kept anyway.
    var keptAnyway: [KeptAnyway]
    /// When the first photo left out for having been written in the last minute is to be listed; nil for none.
    var settles: Date?
}

extension HealthChecker {
    /// Photos whose health says they're damaged, and those marked unreadable without one, but not
    /// those still being written. Those Redlamp may not read are listed with nothing proposed.
    func damaged(store: ColumnStore?) async throws -> HealthFindings {
        let definitions = definitions
        let settled = now().addingTimeInterval(-Self.settling)
        let unreadable = store.map(Self.unreadable(in:))
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

    /// The findings kept anyway of the damaged files check: with the photos' rows and health, what decides which
    /// photos it lists.
    var keptDamaged: [KeptAnyway] {
        definitions.keptAnyway.filter { $0.check == .damaged }
    }

    /// The photos `damaged(store:)` lists, from what decides it alone: no finding's reason, row or path but those
    /// Keep Anyway asks for, and no order by path. For `is:damaged`, which needs only the photos. With `ids`, those
    /// of them it lists, for photos changed since it was asked.
    func damagedPhotos(store: ColumnStore?, among ids: [Int64]? = nil) async throws -> DamagedPhotos {
        let ids = ids.map { Array(Set($0)) }
        let definitions = definitions
        let keeping = definitions.keepsAny(.damaged)
        let settled = now().addingTimeInterval(-Self.settling).timeIntervalSince1970
        let unreadable = store.map { store in
            ids.map { $0.filter { Self.isUnreadable($0, in: store) } } ?? Self.unreadable(in: store)
        }
        return try await index.read { reader in
            // With Keep Anyway, what it's keyed by.
            let columns = "p.id, p.state, p.modified" + (keeping ? ", p.size, p.content_key, p.folder, p.name" : "")
            var found: [Int64] = []
            var settles: Double?
            var folders: [Int64: String] = [:]
            func consider(_ row: SQLiteStatement) throws {
                let modified = row.double(at: 2)
                guard !PhotoRecord.State(rawValue: row.int(at: 1)).contains(.settling) else { return }
                guard modified <= settled else {
                    settles = min(settles ?? .infinity, modified + Self.settling)
                    return
                }
                if keeping {
                    let folder = row.int64(at: 5)
                    if folders[folder] == nil {
                        folders[folder] = try reader.folder(id: folder)?.path ?? ""
                    }
                    let path = (folders[folder] ?? "") + "/" + (row.string(at: 6) ?? "")
                    guard !definitions.keeps(
                        .damaged, contentKey: row.data(at: 4), path: path, size: row.int64(at: 3),
                        modified: Date(timeIntervalSince1970: modified),
                    ) else { return }
                }
                found.append(row.int64(at: 0))
            }
            // CROSS JOIN keeps the health rows the outer loop: with conditions on the photos, SQLite would scan those.
            let damaged = try """
            SELECT \(columns) FROM photo_health h CROSS JOIN photos p ON p.id = h.photo
            WHERE h.damage BETWEEN 1 AND 4 AND p.size = h.size AND abs(p.modified - h.modified) < 1e-6
              AND \(reader.inLibrary(folder: "p.folder", state: "p.state"))
            """
            if let ids {
                let statement = try reader.database.cached(damaged + " AND h.photo = ?")
                for id in ids {
                    try statement.bind(id, at: 1)
                    try statement.forEachRow(consider)
                }
            } else {
                try reader.database.cached(damaged).forEachRow(consider)
            }
            // Those marked unreadable that aren't found already, each looked up with the same conditions.
            let marked = try unreadable ?? reader.unreadablePhotoIDs(among: ids)
            if !marked.isEmpty {
                let listed = Set(found)
                let photo = try reader.database.cached("SELECT \(columns) FROM photos p WHERE p.id = ?")
                for id in marked where !listed.contains(id) {
                    try photo.bind(id, at: 1)
                    try photo.forEachRow(consider)
                }
            }
            return DamagedPhotos(
                photos: found.sorted(), keptAnyway: definitions.keptAnyway.filter { $0.check == .damaged },
                settles: settles.map(Date.init(timeIntervalSince1970:)),
            )
        }
    }

    /// Whether photo `id` is marked unreadable in `store`, and not missing, which only the Missing check lists.
    private static func isUnreadable(_ id: Int64, in store: ColumnStore) -> Bool {
        guard let row = store.row(of: id) else { return false }
        let state = PhotoRecord.State(rawValue: Int(store.states[row]))
        return state.contains(.unreadable) && !state.contains(.missing)
    }

    /// The store's photos marked unreadable, by ID, but those missing, which only the Missing check lists.
    private static func unreadable(in store: ColumnStore) -> [Int64] {
        var ids: [Int64] = []
        let marked = store.rows(matching: .leaf(.state(UInt8(PhotoRecord.State.unreadable.rawValue))), sets: [:])
        store.listed(marked, unreadable: true).forEach {
            ids.append(store.ids[$0])
            return true
        }
        return ids
    }
}
