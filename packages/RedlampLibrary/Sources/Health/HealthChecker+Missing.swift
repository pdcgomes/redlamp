import Foundation

extension HealthChecker {
    /// The photos whose files went from their folders outside Redlamp (DEC-59), each with where it was and when change
    /// tracking found its file gone, in the order of their paths; not those of roots marked removed. Nothing is
    /// proposed:
    /// Locate… finds a photo again and Remove takes it out of the library, as the user chooses.
    func missing(store: ColumnStore?) async throws -> HealthFindings {
        let marked = store.map(Self.missing(in:))
        let found = try await index.read { reader -> [(PhotoRecord, String, Void)] in
            let ids = try marked ?? reader.missingPhotoIDs().sorted()
            let removed = try reader.removedFolders()
            return try reader.photosWithPaths(ids).compactMap { photo, folder in
                photo.state.contains(.missing) && !removed.contains(photo.folder) ? (photo, folder, ()) : nil
            }
        }
        let findings = found.map { photo, folder, _ in
            HealthFinding(photo: photo.id, check: .missing, reason: .missing(from: folder, since: photo.missingSince))
        }
        return HealthFindings(check: .missing, findings: Self.byPath(findings, found))
    }

    /// The store's photos marked missing, in ID order.
    private static func missing(in store: ColumnStore) -> [Int64] {
        var ids: [Int64] = []
        store.rows(matching: .leaf(.state(UInt8(PhotoRecord.State.missing.rawValue))), sets: [:]).forEach {
            ids.append(store.ids[$0])
            return true
        }
        return ids.sorted()
    }
}
