import Foundation

/// The library's newest import that's over, as the Library panel's Previous Import shows it (LIB-23): the
/// photos it put at its destination, from the imports' journal (`ImportJournal`), which keeps the 50
/// newest. An import a forced quit cut short isn't over until it's finished.
public struct PreviousImport: Sendable, Hashable {
    public let id: UUID
    public let created: Date
    /// Each photo file it put at its destination, a raw and its JPEG both, as the index keeps their paths.
    public let photos: [String]
    /// The folders those are in, as the index keeps their paths.
    public let folders: [String]
}

public extension ImportJournal {
    /// The newest import that finished, or was cancelled, with photos done; nil when there's none.
    func previousImport() throws -> PreviousImport? {
        for entry in try entries().reversed() where !entry.state.isUnfinished && entry.done > 0 {
            guard let (plan, progress) = try? load(entry.id) else { continue }
            var photos: [String] = []
            for item in progress.done.sorted() where plan.items.indices.contains(item) {
                for copy in plan.items[item].photos {
                    if let target = plan.targets(of: copy).first {
                        photos.append(LibraryIndexer.path(target))
                    }
                }
            }
            guard !photos.isEmpty else { continue }
            let folders = Set(photos.map { ($0 as NSString).deletingLastPathComponent })
            return PreviousImport(id: entry.id, created: entry.created, photos: photos, folders: folders.sorted())
        }
        return nil
    }
}
