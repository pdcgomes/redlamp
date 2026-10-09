import Foundation
import RedlampDocument

public extension LibraryHealth {
    /// Keeps `photos`' findings in `findings` anyway: each by its content key, or by its path for a
    /// photo without one, and a duplicate's by its group's SHA-256 with its copies, so another copy
    /// opens the group again. Lists follow. Returns the entries it added, those already kept left out,
    /// which `takeBack` takes back.
    @discardableResult
    func keepAnyway(_ photos: [Int64], in findings: HealthFindings) async throws -> [KeptAnyway] {
        let wanted = Set(photos)
        let chosen = findings.findings.filter { wanted.contains($0.photo) }
        guard !chosen.isEmpty else { return [] }
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
                    .content(content, modified: photo.modified)
                } else {
                    .file(path: folder + "/" + photo.name, size: photo.size, modified: photo.modified)
                }
                entries.append(KeptAnyway(check: finding.check, key: key))
            }
        }
        return try await keepAnyway(entries)
    }

    /// Keeps `entries` anyway, those not kept already, as Keep Anyway made them: Redo after `takeBack`.
    /// Lists follow. Returns the entries it added.
    @discardableResult
    func keepAnyway(_ entries: [KeptAnyway]) async throws -> [KeptAnyway] {
        try await changeDefinitions { definitions in
            var added: [KeptAnyway] = []
            for entry in entries
                where !definitions.keptAnyway.contains(where: { $0.check == entry.check && $0.key == entry.key }) {
                definitions.keptAnyway.append(entry)
                added.append(entry)
            }
            return added
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

    private func changeDefinitions<T: Sendable>(
        _ change: @escaping @Sendable (inout HealthDefinitions) -> T,
    ) async throws -> T {
        let url = HealthDefinitions.url(in: paths)
        let made = try await LibraryIndex.offCaller {
            var definitions = try HealthDefinitions.load(from: url)
            let made = change(&definitions)
            try definitions.save(to: url)
            return made
        }
        await changed()
        return made
    }
}
