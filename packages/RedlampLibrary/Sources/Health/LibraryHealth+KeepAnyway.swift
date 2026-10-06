import Foundation
import RedlampDocument

public extension LibraryHealth {
    /// Keeps `photos`' findings in `findings` anyway: each by its content key, or by its path for a
    /// photo without one, and a duplicate's by its group's SHA-256 with its copies, so another copy
    /// opens the group again. Lists follow.
    func keepAnyway(_ photos: [Int64], in findings: HealthFindings) async throws {
        let chosen = findings.findings.filter { photos.contains($0.photo) }
        guard !chosen.isEmpty else { return }
        let rows = try await index.read { reader in
            try Dictionary(reader.photosWithPaths(chosen.map(\.photo)).map { ($0.photo.id, $0) }) { first, _ in first }
        }
        var entries: [KeptAnyway] = []
        for finding in chosen {
            if case let .duplicates(sha256)? = finding.group {
                let copies = findings.findings.count { $0.group == finding.group }
                entries.append(KeptAnyway(check: .duplicates, key: .group(sha256: sha256, copies: copies)))
            } else if let (photo, folder) = rows[finding.photo] {
                let key: KeptAnyway.Key = if let content = photo.contentKey.flatMap(ContentKey.init(data:)) {
                    .content(content)
                } else {
                    .file(path: folder + "/" + photo.name, size: photo.size, modified: photo.modified)
                }
                entries.append(KeptAnyway(check: finding.check, key: key))
            }
        }
        let kept = entries
        try await changeDefinitions { definitions in
            for entry in kept
                where !definitions.keptAnyway.contains(where: { $0.check == entry.check && $0.key == entry.key }) {
                definitions.keptAnyway.append(entry)
            }
        }
    }

    /// What's kept anyway, each with the photos it keeps that the library has.
    func keptAnyway() async throws -> [(kept: KeptAnyway, photos: [Int64])] {
        let definitions = HealthDefinitions.cached(at: HealthDefinitions.url(in: paths))
        let found = try await HealthChecker(index: index, paths: paths).keptAnyway()
        return definitions.keptAnyway.map { kept in
            (kept, found.filter { $0.kept == kept }.map(\.photo).sorted())
        }
    }

    /// Takes `kept` back from the Kept Anyway list: their findings are listed again.
    func takeBack(_ kept: [KeptAnyway]) async throws {
        try await changeDefinitions { definitions in
            definitions.keptAnyway
                .removeAll { entry in kept.contains { $0.check == entry.check && $0.key == entry.key } }
        }
    }

    private func changeDefinitions(_ change: @escaping @Sendable (inout HealthDefinitions) -> Void) async throws {
        let url = HealthDefinitions.url(in: paths)
        try await LibraryIndex.offCaller {
            var definitions = try HealthDefinitions.load(from: url)
            change(&definitions)
            try definitions.save(to: url)
        }
        await changed()
    }
}
