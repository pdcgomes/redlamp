import Foundation

/// A place in the index's collection list, as its row has it.
public struct CollectionRecord: Sendable, Hashable {
    public var id: Int64
    public var parent: Int64?
    public var path: CollectionPath
    public var kind: CollectionKind
}

public extension IndexQueries {
    /// Every collection and set the index has a row for, by ID: the collections the photos are in, and
    /// the sets above them.
    func collections() throws -> [Int64: CollectionRecord] {
        var found: [Int64: CollectionRecord] = [:]
        try database.cached("SELECT id, parent, path, kind FROM collections WHERE path IS NOT NULL").forEachRow { row in
            guard let path = row.string(at: 2).flatMap(CollectionPath.init) else { return }
            found[row.int64(at: 0)] = CollectionRecord(
                id: row.int64(at: 0), parent: row.optionalInt64(at: 1), path: path,
                kind: CollectionKind(rawValue: row.int(at: 3)) ?? .collection,
            )
        }
        return found
    }

    /// How many photos each collection holds itself, by path.
    func collectionCounts() throws -> [CollectionPath: Int] {
        var counts: [CollectionPath: Int] = [:]
        try database.cached("""
        SELECT c.path, count(*) FROM collection_photos cp JOIN collections c ON c.id = cp.collection
        WHERE c.path IS NOT NULL GROUP BY c.id
        """).forEachRow { row in
            if let path = row.string(at: 0).flatMap(CollectionPath.init) {
                counts[path] = row.int(at: 1)
            }
        }
        return counts
    }

    /// The collections `photo` is in, by path.
    func collections(ofPhoto photo: Int64) throws -> [CollectionPath] {
        let statement = try database.cached("""
        SELECT c.path FROM collection_photos cp JOIN collections c ON c.id = cp.collection
        WHERE cp.photo = ? AND c.path IS NOT NULL ORDER BY c.path
        """)
        try statement.bind(photo, at: 1)
        return try statement.map { $0.string(at: 0) }.compactMap { $0.flatMap(CollectionPath.init) }
    }

    /// Each of `ids`' collections, by photo; a photo the index has in none has an empty list, and one it
    /// doesn't have none.
    func collectionPaths(ofPhotos ids: [Int64]) throws -> [Int64: [CollectionPath]] {
        let exists = try database.cached("SELECT 1 FROM photos WHERE id = ?")
        var found: [Int64: [CollectionPath]] = [:]
        for id in ids {
            try exists.bind(id, at: 1)
            guard try exists.first({ _ in true }) == true else { continue }
            found[id] = try collections(ofPhoto: id)
        }
        return found
    }

    /// The photos in any collection at or within `paths`, in ID order.
    func photoIDs(inCollectionsWithin paths: [CollectionPath]) throws -> [Int64] {
        let statement = try database.cached("""
        SELECT DISTINCT cp.photo FROM collections c JOIN collection_photos cp ON cp.collection = c.id
        WHERE c.path = ?1 OR (c.path >= ?2 AND c.path < ?3) ORDER BY cp.photo
        """)
        var ids = Set<Int64>()
        for path in paths {
            try statement.bindSubtree(of: path.text)
            try ids.formUnion(statement.map { $0.int64(at: 0) })
        }
        return ids.sorted()
    }
}

public extension LibraryIndex.Writer {
    /// Gives `photo` the collections at `paths` and no others, adding the rows the index lacks: each a
    /// collection, the paths above it sets.
    func setCollections(_ paths: [String], forPhoto photo: Int64) throws {
        let wanted = try Set(CollectionPath.paths(paths).map(collectionID(for:)))
        let current = try database.cached("SELECT collection FROM collection_photos WHERE photo = ?")
        try current.bind(photo, at: 1)
        let had = try Set(current.map { $0.int64(at: 0) })
        guard had != wanted else { return }
        let unlink = try database.cached("DELETE FROM collection_photos WHERE collection = ? AND photo = ?")
        for collection in had.subtracting(wanted) {
            try unlink.bind(collection, at: 1)
            try unlink.bind(photo, at: 2)
            try unlink.run()
        }
        let link = try database.cached("INSERT OR IGNORE INTO collection_photos (collection, photo) VALUES (?, ?)")
        for collection in wanted.subtracting(had) {
            try link.bind(collection, at: 1)
            try link.bind(photo, at: 2)
            try link.run()
        }
    }

    /// Gives each photo its collections, `[]` for none.
    func setCollections(_ collections: [Int64: [CollectionPath]]) throws {
        for (photo, paths) in collections.sorted(by: { $0.key < $1.key }) {
            try setCollections(paths.map(\.text), forPhoto: photo)
        }
    }

    /// The ID of the collection at `path`, added with the sets above it the index lacks. A set photos are
    /// put in becomes a collection.
    func collectionID(for path: CollectionPath) throws -> Int64 {
        var parent: Int64?
        for ancestor in path.ancestors {
            parent = try collectionRow(ancestor, parent: parent, kind: .set)
        }
        return try collectionRow(path, parent: parent, kind: .collection)
    }

    /// Removes the rows of collections within `paths` that hold no photo and contain no collection that
    /// does, and those of the sets above them left the same way.
    func removeUnusedCollections(within paths: [CollectionPath]) throws {
        let subtree = try database.cached("""
        DELETE FROM collections WHERE (path = ?1 OR (path >= ?2 AND path < ?3))
          AND id NOT IN (SELECT collection FROM collection_photos)
          AND NOT EXISTS (SELECT 1 FROM collections below JOIN collection_photos cp ON cp.collection = below.id
            WHERE below.path >= collections.path || '/' AND below.path < collections.path || '0')
        """)
        let alone = try database.cached("""
        DELETE FROM collections WHERE path = ?1 AND id NOT IN (SELECT collection FROM collection_photos)
          AND NOT EXISTS (SELECT 1 FROM collections below WHERE below.path >= ?2 AND below.path < ?3)
        """)
        for path in paths {
            try subtree.bindSubtree(of: path.text)
            try subtree.run()
            for ancestor in path.ancestors.reversed() {
                try alone.bindSubtree(of: ancestor.text)
                try alone.run()
                guard database.changes > 0 else { break }
            }
        }
    }

    /// The row at `path`, added as `kind` under `parent` when there's none, with an ID no collection had
    /// (`IndexIDs`); an existing set photos are put in becomes a collection.
    private func collectionRow(_ path: CollectionPath, parent: Int64?, kind: CollectionKind) throws -> Int64 {
        let select = try database.cached("SELECT id, kind FROM collections WHERE path = ?")
        try select.bind(path.text, at: 1)
        if let found = try select.first({ (id: $0.int64(at: 0), kind: $0.int(at: 1)) }) {
            let id = found.id
            if kind == .collection, found.kind == CollectionKind.set.rawValue {
                let upgrade = try database.cached("UPDATE collections SET kind = ? WHERE id = ?")
                try upgrade.bind(CollectionKind.collection.rawValue, at: 1)
                try upgrade.bind(id, at: 2)
                try upgrade.run()
            }
            return id
        }
        let insert = try database.cached("""
        INSERT INTO collections (parent, name, kind, path, id) VALUES (?, ?, ?, ?, ?) RETURNING id
        """)
        try insert.bind(parent, at: 1)
        try insert.bind(path.name, at: 2)
        try insert.bind(kind.rawValue, at: 3)
        try insert.bind(path.text, at: 4)
        try insert.bind(newID(of: .collections), at: 5)
        return try returnedID(insert)
    }
}
