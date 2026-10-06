import Foundation
import RedlampDocument

extension HealthChecker {
    /// Photos whose format doesn't fit their names' extensions, each proposed the name its format's
    /// extension gives it, unless another photo of its folder has that name.
    func extensions() async throws -> HealthFindings {
        let definitions = definitions
        let found = try await index.read { reader -> [(PhotoRecord, String, PhotoHealth, Set<String>)] in
            let wrong = try reader.photoHealth().filter { !$0.value.health.format.fits(name: $0.value.name) }
            var names: [Int64: Set<String>] = [:]
            return try reader.photosWithPaths(wrong.keys.sorted()).compactMap { photo, folder in
                guard let health = wrong[photo.id]?.health else { return nil }
                if names[photo.folder] == nil {
                    names[photo.folder] = try Set(reader.photoNames(inFolder: photo.folder).map(NamingJob.fold))
                }
                return (photo, folder, health, names[photo.folder] ?? [])
            }
        }
        var findings: [HealthFinding] = []
        var kept = 0
        for (photo, folder, health, names) in found where !photo.state.contains(.unreadable) {
            if definitions.keeps(
                .extensions, contentKey: photo.contentKey, path: folder + "/" + photo.name, size: photo.size,
                modified: photo.modified,
            ) {
                kept += 1
                continue
            }
            let ext = NamingJob.split(photo.name).ext
            let renamed = health.proposedExtension.map { Self.name(photo.name, withExtension: $0) }
            let free = renamed.map { !names.contains(NamingJob.fold($0)) } ?? false
            findings.append(HealthFinding(
                photo: photo.id, check: .extensions, reason: .wrongExtension(named: ext, holds: health.format),
                proposal: free ? renamed.map(HealthProposal.rename) : nil,
                apart: Self.isDecided(photo) ? .decided : nil,
            ))
        }
        return HealthFindings(
            check: .extensions, findings: Self.byPath(findings, found.map { ($0.0, $0.1, ()) }), keptAnyway: kept,
        )
    }

    /// `name` with its extension `ext`, in capitals when the extension it had was.
    static func name(_ name: String, withExtension ext: String) -> String {
        let (base, old) = NamingJob.split(name)
        let capitals = !old.isEmpty && old == old.uppercased() && old != old.lowercased()
        return base + "." + (capitals ? ext.uppercased() : ext.lowercased())
    }
}
