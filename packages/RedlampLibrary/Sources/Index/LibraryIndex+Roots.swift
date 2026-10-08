import Foundation

/// A root marked removed (`LibraryIndex.Writer.markRemoved`): its row, and the folders and photos every list,
/// count and search leaves out from then on, until they're swept.
public struct RootRemoval: Sendable, Hashable {
    public var root: Int64
    public var path: String
    public var folders: [Int64]
    /// In ID order.
    public var photos: [Int64]
}

/// What one step of sweeping the roots marked removed took out (`LibraryIndex.Writer.sweepRemoved`).
public struct RootSweep: Sendable, Hashable {
    public var photos: [Int64] = []
    public var folders = 0
    public var roots = 0
    /// A root is still marked removed.
    public var more = false
}

// The index's side of roots taken out of the library (LIB-05, LIB-10): a root is marked removed in the
// settings, as an offline volume is, in one small transaction; from then on the column store's reads leave out
// its photos, and its rows go a batch at a time. The mark outlives a quit, so a removal cut short is swept at the
// next launch and never shows half a root.

public extension LibraryIndex.Writer {
    /// Marks the root at `path` removed and returns what lists leave out from now on; nil when the index has
    /// nothing of it to take out. `kept` are the roots still followed: one inside it takes back the folders below
    /// it, and one it's inside takes all of its folders, whose photos then stay. Folders below `path` that another
    /// of the index's roots held (an import's destination) become its own first.
    func markRemoved(_ path: String, keeping kept: [String]) throws -> RootRemoval? {
        guard !kept.contains(path) else { return nil }
        let existing = try root(path: path)
        guard let volume = try existing?.volume ?? volume(holding: path) else { return nil }
        let sidecars = existing?.sidecars ?? .besidePhotos
        if let holder = kept.filter({ Self.isBelow(path, $0) }).max(by: { $0.count < $1.count }) {
            try own(path, by: rootID(holder, volume: volume, sidecars: sidecars))
            let parent = try database.cached("""
            UPDATE folders SET parent = (SELECT id FROM folders WHERE path = ?2) WHERE path = ?1
            """)
            try parent.bind(path, at: 1)
            try parent.bind(Self.parentPath(path), at: 2)
            try parent.run()
            if let existing {
                try deleteRoot(existing.id)
            }
            return nil
        }
        let id = try existing?.id ?? upsertRoot(RootRecord(volume: volume, path: path, sidecars: sidecars))
        try own(path, by: id)
        for inside in kept.filter({ Self.isBelow($0, path) }).sorted(by: { $0.count < $1.count }) {
            try own(inside, by: rootID(inside, volume: volume, sidecars: sidecars))
            let top = try database.cached("UPDATE folders SET parent = NULL WHERE path = ?")
            try top.bind(inside, at: 1)
            try top.run()
        }
        try setSetting(path, for: Self.removingKey(id))
        let photos = try database.cached("""
        SELECT id FROM photos WHERE folder IN (SELECT id FROM folders WHERE root = ?) ORDER BY id
        """)
        try photos.bind(id, at: 1)
        return try RootRemoval(
            root: id, path: path, folders: folders(inRoot: id).map(\.id), photos: photos.map { $0.int64(at: 0) },
        )
    }

    /// Takes away the keywords and collection memberships of photos `ids` of a root marked removed, so the
    /// counts made from them leave the photos out before their rows are swept.
    func unlinkPhotos(_ ids: [Int64]) throws {
        let keywords = try database.cached("DELETE FROM photo_keywords WHERE photo = ?")
        let collections = try database.cached("DELETE FROM collection_photos WHERE photo = ?")
        for id in ids {
            for statement in [keywords, collections] {
                try statement.bind(id, at: 1)
                try statement.run()
            }
        }
    }

    /// Takes out the rows of up to `limit` photos of a root marked removed, with their keywords, collection
    /// memberships and text, the root marked first going first; a root with no photos left goes with its folders
    /// and its mark.
    func sweepRemoved(limit: Int) throws -> RootSweep {
        let marked = try removedRoots().keys.sorted()
        guard let root = marked.first else { return RootSweep() }
        var sweep = RootSweep(more: true)
        let photos = try database.cached("""
        SELECT id FROM photos WHERE folder IN (SELECT id FROM folders WHERE root = ?) LIMIT ?
        """)
        try photos.bind(root, at: 1)
        try photos.bind(max(limit, 1), at: 2)
        sweep.photos = try photos.map { $0.int64(at: 0) }
        guard sweep.photos.isEmpty else {
            try deletePhotos(sweep.photos)
            return sweep
        }
        let folders = try database.cached("DELETE FROM folders WHERE root = ?")
        try folders.bind(root, at: 1)
        try folders.run()
        sweep.folders = database.changes
        try deleteRoot(root)
        sweep.roots = 1
        sweep.more = marked.count > 1
        return sweep
    }

    /// Removes the root's row and its mark; its folders are taken out or given to other roots first.
    private func deleteRoot(_ id: Int64) throws {
        let statement = try database.cached("DELETE FROM roots WHERE id = ?")
        try statement.bind(id, at: 1)
        try statement.run()
        try setSetting(nil, for: Self.removingKey(id))
    }

    /// The ID of the root at `path`, made on `volume` when the index has none.
    private func rootID(_ path: String, volume: Int64, sidecars: RootRecord.Sidecars) throws -> Int64 {
        try root(path: path)?.id ?? upsertRoot(RootRecord(volume: volume, path: path, sidecars: sidecars))
    }

    /// Gives the folder at `path` and every folder below it to `root`.
    private func own(_ path: String, by root: Int64) throws {
        let statement = try database
            .cached("UPDATE folders SET root = ?4 WHERE path = ?1 OR (path >= ?2 AND path < ?3)")
        try statement.bindSubtree(of: path)
        try statement.bind(root, at: 4)
        try statement.run()
    }

    /// The volume of the root holding the folder at `path` or one below it; nil when the index has none.
    private func volume(holding path: String) throws -> Int64? {
        let statement = try database.cached("""
        SELECT r.volume FROM folders f JOIN roots r ON r.id = f.root
        WHERE f.path = ?1 OR (f.path >= ?2 AND f.path < ?3) LIMIT 1
        """)
        try statement.bindSubtree(of: path)
        return try statement.first { $0.int64(at: 0) }
    }

    /// Whether `path` is below `root`, not at it.
    internal static func isBelow(_ path: String, _ root: String) -> Bool {
        path != root && (root == "/" || path.hasPrefix(root + "/"))
    }

    private static func parentPath(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    internal static func removingKey(_ root: Int64) -> String {
        removingPrefix + String(root)
    }

    internal static let removingPrefix = "library.removing."
}

public extension IndexQueries {
    /// The roots marked removed whose rows aren't all swept yet, their paths by ID.
    func removedRoots() throws -> [Int64: String] {
        let statement = try database.cached("SELECT key, value FROM settings WHERE key > ?1 AND key < ?2")
        let prefix = LibraryIndex.Writer.removingPrefix
        try statement.bind(prefix, at: 1)
        try statement.bind(String(prefix.dropLast()) + "/", at: 2)
        var roots: [Int64: String] = [:]
        try statement.forEachRow { row in
            if let key = row.string(at: 0), let id = Int64(key.dropFirst(prefix.count)) {
                roots[id] = row.string(at: 1) ?? ""
            }
        }
        return roots
    }

    /// The folders of the roots marked removed: the column store's reads leave out their photos. Empty, at the
    /// cost of one lookup, while nothing is being removed.
    func removedFolders() throws -> Set<Int64> {
        let roots = try removedRoots().keys
        guard !roots.isEmpty else { return [] }
        let statement = try database.cached("SELECT id FROM folders WHERE root = ?")
        var folders = Set<Int64>()
        for root in roots {
            try statement.bind(root, at: 1)
            try statement.forEachRow { folders.insert($0.int64(at: 0)) }
        }
        return folders
    }
}
