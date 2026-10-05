import Foundation

/// The index's side of the file operations (LIB-26): rows that follow photos and folders as they're
/// renamed, moved, made, removed and put back, keeping their IDs, so nothing is read again.
public extension LibraryIndex.Writer {
    /// The folder at `path`: its row, made when it has none, with rows for the folders above it up to
    /// its root. A folder made empty is marked indexed. Nil when `path` isn't in a root.
    func folderID(forPath path: String, makingEmpty empty: Bool = false) throws -> Int64? {
        if let folder = try folder(anyFormOf: path) {
            return folder.id
        }
        guard let root = try root(containing: path) else { return nil }
        let parent: Int64?
        if path == root.path {
            parent = nil
        } else {
            let slash = path.lastIndex(of: "/") ?? path.startIndex
            parent = try folderID(forPath: slash == path.startIndex ? "/" : String(path[..<slash]))
        }
        let signature = empty ? FolderSignature([]).rawValue : nil
        return try upsertFolder(FolderRecord(
            root: root.id, parent: parent, path: path, signature: signature, indexedSignature: signature,
            listedAt: empty ? Date() : nil,
        ))
    }

    /// Moves `folder` and the folders under it to `path`, in `root`, keeping their rows.
    func moveFolder(_ folder: Int64, to path: String, parent: Int64?, root: Int64) throws {
        try moveFolder(folder, to: path, parent: parent)
        let statement = try database
            .cached("UPDATE folders SET root = ?4 WHERE path = ?1 OR (path >= ?2 AND path < ?3)")
        try statement.bindSubtree(of: path)
        try statement.bind(root, at: 4)
        try statement.run()
    }

    /// Removes the folder's row if no photo or folder is in it; whether it went.
    @discardableResult
    func removeFolderIfEmpty(_ path: String) throws -> Bool {
        guard let folder = try folder(anyFormOf: path) else { return false }
        let statement = try database.cached("""
        DELETE FROM folders WHERE id = ?1 AND NOT EXISTS (SELECT 1 FROM photos WHERE folder = folders.id)
          AND NOT EXISTS (SELECT 1 FROM folders f WHERE f.parent = folders.id)
        """)
        try statement.bind(folder.id, at: 1)
        try statement.run()
        return database.changes > 0
    }

    /// Puts photos where `places` say, keeping their IDs, whatever order they swap names in: a photo
    /// whose new place another of them still has waits under a name no file can have. A row of a
    /// photo not among them that still holds a place is of a file that's gone, and is removed;
    /// returns those removed.
    @discardableResult
    func placePhotos(_ places: [(photo: Int64, folder: Int64, name: String)]) throws -> [Int64] {
        let moving = Set(places.map(\.photo))
        var stale: [Int64] = []
        let park = try database.cached("UPDATE photos SET name = ? WHERE id = ?")
        for place in places {
            guard let holder = try photo(folder: place.folder, name: place.name),
                  holder.id != place.photo else { continue }
            if moving.contains(holder.id) {
                try park.bind("/moving/\(holder.id)", at: 1)
                try park.bind(holder.id, at: 2)
                try park.run()
            } else {
                stale.append(holder.id)
            }
        }
        try deletePhotos(stale)
        try movePhotos(places)
        return stale
    }

    func setFileID(_ fileID: UInt64?, forPhoto photo: Int64) throws {
        let statement = try database.cached("UPDATE photos SET file_id = ? WHERE id = ?")
        try statement.bind(fileID.map { Int64(bitPattern: $0) }, at: 1)
        try statement.bind(photo, at: 2)
        try statement.run()
    }

    func setSidecarModified(_ date: Date?, forPhoto photo: Int64) throws {
        let statement = try database.cached("UPDATE photos SET sidecar_modified = ? WHERE id = ?")
        try statement.bind(date?.timeIntervalSince1970, at: 1)
        try statement.bind(photo, at: 2)
        try statement.run()
    }

    /// Puts back a photo's row as it was, in `folder` and named `name`, with its keywords and its
    /// places in the collections still there: under its own ID, unless another photo has taken it
    /// since. Returns the ID it has.
    func restorePhoto(_ removed: RemovedPhoto, inFolder folder: Int64, name: String) throws -> Int64 {
        var record = removed.photo.record(inFolder: folder)
        record.name = name
        let id = try upsertPhotos([record])[0]
        var restored = id
        if id != removed.photo.id, try photo(id: removed.photo.id) == nil {
            let renumber = try database.cached("UPDATE photos SET id = ? WHERE id = ?")
            try renumber.bind(removed.photo.id, at: 1)
            try renumber.bind(id, at: 2)
            try renumber.run()
            let text = try database.cached("DELETE FROM photo_text WHERE rowid = ?")
            try text.bind(id, at: 1)
            try text.run()
            for table in ["photo_keywords", "collection_photos"] {
                let statement = try database.cached("UPDATE OR IGNORE \(table) SET photo = ? WHERE photo = ?")
                try statement.bind(removed.photo.id, at: 1)
                try statement.bind(id, at: 2)
                try statement.run()
            }
            restored = removed.photo.id
            try movePhotos([(restored, folder, name)])
        }
        try setKeywords(removed.keywords, forPhoto: restored)
        let place = try database.cached("""
        INSERT OR IGNORE INTO collection_photos (collection, photo, position)
        SELECT ?1, ?2, ?3 WHERE EXISTS (SELECT 1 FROM collections WHERE id = ?1)
        """)
        for collection in removed.collections {
            try place.bind(collection.collection, at: 1)
            try place.bind(restored, at: 2)
            try place.bind(collection.position, at: 3)
            try place.run()
        }
        return restored
    }

    /// Puts back a folder's row as it was, under its own ID unless another folder has taken it.
    @discardableResult
    func restoreFolder(_ removed: RemovedFolder) throws -> Int64 {
        if let existing = try folder(anyFormOf: removed.path) {
            return existing.id
        }
        let slash = removed.path.lastIndex(of: "/") ?? removed.path.startIndex
        let parentPath = slash == removed.path.startIndex ? "/" : String(removed.path[..<slash])
        let parent = try root(containing: removed.path)?.path == removed.path ? nil : folderID(forPath: parentPath)
        let id = try upsertFolder(FolderRecord(
            root: removed.root, parent: parent, path: removed.path, signature: removed.signature,
            indexedSignature: removed.indexedSignature,
        ))
        guard id != removed.id, try folder(id: removed.id) == nil else { return id }
        for sql in [
            "UPDATE folders SET id = ?1 WHERE id = ?2", "UPDATE folders SET parent = ?1 WHERE parent = ?2",
            "UPDATE photos SET folder = ?1 WHERE folder = ?2",
        ] {
            let statement = try database.cached(sql)
            try statement.bind(removed.id, at: 1)
            try statement.bind(id, at: 2)
            try statement.run()
        }
        return removed.id
    }
}

public extension IndexQueries {
    /// The folder at `path`, its names in Unicode's composed or decomposed form: listings give
    /// them as each was made, and file URLs decompose them.
    func folder(anyFormOf path: String) throws -> FolderRecord? {
        for form in [path, path.precomposedStringWithCanonicalMapping, path.decomposedStringWithCanonicalMapping] {
            if let folder = try folder(path: form) {
                return folder
            }
        }
        return nil
    }

    /// The root whose folder holds `path`, the deepest if roots nest.
    func root(containing path: String) throws -> RootRecord? {
        try roots().filter { root in
            path == root.path || root.path == "/" || path.hasPrefix(root.path + "/")
        }.max { $0.path.count < $1.path.count }
    }

    /// The collections `photo` is in, with its place in each.
    func collectionPlaces(ofPhoto photo: Int64) throws -> [CollectionPlace] {
        let statement = try database.cached("SELECT collection, position FROM collection_photos WHERE photo = ?")
        try statement.bind(photo, at: 1)
        return try statement.map { CollectionPlace(collection: $0.int64(at: 0), position: $0.optionalInt(at: 1)) }
    }

    /// `folder` and every folder under it, parents first.
    func folders(inSubtreeOf folder: Int64) throws -> [FolderRecord] {
        guard let path = try self.folder(id: folder)?.path else { return [] }
        let statement = try database.cached("""
        SELECT \(IndexColumns.folder) FROM folders WHERE path = ?1 OR (path >= ?2 AND path < ?3) ORDER BY path
        """)
        try statement.bindSubtree(of: path)
        return try statement.map(FolderRecord.init)
    }

    /// Photos `ids` with their folders' paths, leaving out the IDs the index doesn't have.
    func photosWithPaths(_ ids: [Int64]) throws -> [(photo: PhotoRecord, folder: String)] {
        var folders: [Int64: String] = [:]
        var found: [(photo: PhotoRecord, folder: String)] = []
        for id in ids {
            guard let photo = try photo(id: id) else { continue }
            if folders[photo.folder] == nil {
                folders[photo.folder] = try folder(id: photo.folder)?.path
            }
            guard let folder = folders[photo.folder] else { continue }
            found.append((photo, folder))
        }
        return found
    }
}
