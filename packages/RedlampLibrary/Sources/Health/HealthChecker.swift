import Foundation
import RedlampDocument

/// Works out Library Health's checks (LIB-40) from the index and the column store, reading no photo:
/// duplicates from content keys and the full hashes the index records (LIB-39), pairs from the stacks
/// found in the store (LIB-28), and damaged files and wrong extensions from what indexing kept of each
/// photo's read.
struct HealthChecker: Sendable {
    let index: LibraryIndex
    let paths: LibraryPaths
    let now: @Sendable () -> Date

    /// How long after a file was last written it's taken for one still being written, whose damage
    /// isn't listed yet.
    static let settling: TimeInterval = 60

    init(index: LibraryIndex, paths: LibraryPaths, now: @escaping @Sendable () -> Date = Date.init) {
        self.index = index
        self.paths = paths
        self.now = now
    }

    /// `check`'s findings; pairs are found in `store`, and with no store there are none.
    func findings(_ check: HealthCheck, store: ColumnStore?) async throws -> HealthFindings {
        switch check {
        case .duplicates: try await duplicates()
        case let .pairs(rule): try await pairs(rule, store: store)
        case .damaged: try await damaged(store: store)
        case .extensions: try await extensions()
        }
    }

    // MARK: - Helpers

    /// Whether the user rated, flagged or labelled the photo.
    static func isDecided(_ photo: PhotoRecord) -> Bool {
        photo.rating > 0 || photo.flag != nil || photo.label != nil || photo.customLabel != nil
    }

    static func isDecided(_ row: Int, store: ColumnStore) -> Bool {
        let packed = store.packed[row]
        return Packed.rating(packed) > 0 || Packed.flag(packed) != 0 || Packed.label(packed) != 0
            || store.customLabels[row] != 0
    }

    /// `findings` in the order of their photos' paths, `found` holding each one's row and folder.
    static func byPath(
        _ findings: [HealthFinding],
        _ found: [(PhotoRecord, String, some Any)],
    ) -> [HealthFinding] {
        let paths = Dictionary(found.map { ($0.0.id, $0.1 + "/" + $0.0.name) }) { first, _ in first }
        return findings.sorted { lhs, rhs in
            let (left, right) = (paths[lhs.photo] ?? "", paths[rhs.photo] ?? "")
            return left != right ? FileOrder.precedes(left, right) : lhs.photo < rhs.photo
        }
    }

    /// The content keys of photos `ids`, by ID.
    func contentKeys(_ ids: [Int64]) async throws -> [Int64: Data] {
        try await index.read { reader in
            let statement = try reader.database.cached("SELECT content_key FROM photos WHERE id = ?")
            var keys: [Int64: Data] = [:]
            for id in ids {
                try statement.bind(id, at: 1)
                if let key = try statement.first({ $0.data(at: 0) }) ?? nil {
                    keys[id] = key
                }
            }
            return keys
        }
    }
}

extension IndexQueries {
    /// The photos marked unreadable, in ID order.
    func unreadablePhotoIDs() throws -> [Int64] {
        let statement = try database.cached("SELECT id FROM photos WHERE state & ? != 0 ORDER BY id")
        try statement.bind(PhotoRecord.State.unreadable.rawValue, at: 1)
        return try statement.map { $0.int64(at: 0) }
    }
}
