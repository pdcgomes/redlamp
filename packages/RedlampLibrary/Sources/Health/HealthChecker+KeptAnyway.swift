import Foundation
import RedlampDocument

extension HealthChecker {
    /// The photos what's kept anyway names, each with its entry: by content key and modification date, by
    /// path for a photo without one, and a duplicate group's copies by the full hash the index recorded for
    /// them.
    func keptAnyway() async throws -> [(photo: Int64, kept: KeptAnyway)] {
        let entries = definitions.keptAnyway
        guard !entries.isEmpty else { return [] }
        return try await index.read { reader in
            var found: [(photo: Int64, kept: KeptAnyway)] = []
            var byContent: [Data: [KeptAnyway]] = [:]
            for entry in entries {
                switch entry.key {
                case let .content(key, _):
                    byContent[key.data, default: []].append(entry)
                case let .file(path, size, modified):
                    if let photo = try reader.photo(path: path), photo.contentKey == nil, photo.size == size,
                       LibraryIndexer.Run.same(photo.modified, modified) {
                        found.append((photo.id, entry))
                    }
                case let .group(sha256, _):
                    let statement = try reader.database.cached("""
                    SELECT h.photo FROM photo_hashes h JOIN photos p ON p.id = h.photo
                    WHERE h.sha256 = ? AND p.size = h.size AND abs(p.modified - h.modified) < 1e-6
                      AND p.content_key = h.content_key ORDER BY h.photo
                    """)
                    try statement.bind(sha256, at: 1)
                    found += try statement.map { ($0.int64(at: 0), entry) }
                }
            }
            if !byContent.isEmpty {
                try reader.database
                    .cached("SELECT id, content_key, modified FROM photos WHERE content_key IS NOT NULL")
                    .forEachRow { row in
                        guard let key = row.data(at: 1), let kept = byContent[key] else { return }
                        let modified = Date(timeIntervalSince1970: row.double(at: 2))
                        for entry in kept
                            where entry.keeps(entry.check, contentKey: key, path: "", size: 0, modified: modified) {
                            found.append((row.int64(at: 0), entry))
                        }
                    }
            }
            return found
        }
    }
}
