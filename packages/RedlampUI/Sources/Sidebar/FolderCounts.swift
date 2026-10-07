import Foundation
import RedlampLibrary

/// How many photos each folder the library's index holds has, by path (LIB-10): those directly in it and
/// those in it and every folder below it, for the folder tree to count a folder as Show Photos in
/// Subfolders shows it. Photos that can't be read are left out, as every list leaves them out (LIB-40).
///
/// They're counted from the index's folders and its photos' folder index, without a listing of the disk:
/// 40 to 45 ms at a million photos, off the main thread.
struct FolderCounts: Sendable, Equatable {
    struct Count: Sendable, Equatable {
        /// The photos directly in the folder.
        var own: Int
        /// The photos in it and in every folder below it.
        var all: Int
    }

    /// By path, as the index keeps it.
    var folders: [String: Count] = [:]

    /// The paths whose counts differ from `other`'s, those only one of them has included.
    func changed(from other: FolderCounts) -> Set<String> {
        var changed = Set<String>()
        for (path, count) in folders where other.folders[path] != count {
            changed.insert(path)
        }
        for path in other.folders.keys where folders[path] == nil {
            changed.insert(path)
        }
        return changed
    }

    /// The counts as `index` has them now, less the photos `engine` finds can't be read.
    static func read(index: LibraryIndex, engine: QueryEngine) async throws -> FolderCounts {
        let unreadable = try await engine.list(.allPhotographs, matching: unreadableQuery).ids
        return try await index.read { reader in
            var folders: [(id: Int64, parent: Int64?, path: String)] = []
            try reader.database.cached("SELECT id, parent, path FROM folders").forEachRow { row in
                folders.append((row.int64(at: 0), row.optionalInt64(at: 1), row.string(at: 2) ?? ""))
            }
            var own = try reader.photoCountsByFolder()
            for id in unreadable {
                if let folder = try reader.photo(id: id)?.folder, let count = own[folder] {
                    own[folder] = max(count - 1, 0)
                }
            }
            var all = own
            // Deepest first: each folder's total is complete before it's added to its parent's.
            let depths = folders.map { folder in folder.path.utf8.count { $0 == UInt8(ascii: "/") } }
            for place in folders.indices.sorted(by: { depths[$0] > depths[$1] }) {
                let folder = folders[place]
                if let parent = folder.parent, let total = all[folder.id] {
                    all[parent, default: 0] += total
                }
            }
            var counts = FolderCounts()
            counts.folders.reserveCapacity(folders.count)
            for folder in folders {
                counts.folders[folder.path] = Count(own: own[folder.id] ?? 0, all: all[folder.id] ?? 0)
            }
            return counts
        }
    }

    private static let unreadableQuery = LibraryQuery.filter(LibraryQuery.Filter(.unreadable, .equal, [.bool(true)]))
}
