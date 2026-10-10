import Foundation

/// How many photos have a keyword (`photos`), and how many have it or a keyword inside it (`count`):
/// what the keyword list shows.
public struct KeywordCount: Sendable, Hashable {
    public var photos: Int
    public var count: Int

    public init(photos: Int = 0, count: Int = 0) {
        self.photos = photos
        self.count = count
    }
}

public extension IndexQueries {
    /// Every keyword the index has a row for, with its counts. A photo is counted once for a keyword
    /// however many of the keywords inside it it has; photos missing from their folders, which only
    /// Library Health's Missing check lists (DEC-59), aren't counted.
    func keywordCounts() throws -> [KeywordPath: KeywordCount] {
        var paths: [Int64: KeywordPath] = [:]
        for (id, text) in try keywordPaths() {
            paths[id] = KeywordPath(text)
        }
        var nodes: [KeywordPath: Int32] = [:]
        var counts: [KeywordCount] = []
        func node(_ path: KeywordPath) -> Int32 {
            if let found = nodes[path] {
                return found
            }
            let added = Int32(counts.count)
            nodes[path] = added
            counts.append(KeywordCount())
            return added
        }
        // Each keyword's node, then those of the keywords containing it.
        var chains: [Int64: [Int32]] = [:]
        for (id, path) in paths {
            chains[id] = [node(path)] + path.ancestors.reversed().map(node)
        }
        var own: [Int64: Int] = [:]
        try database.cached("SELECT keyword, count(*) FROM photo_keywords GROUP BY keyword").forEachRow { row in
            own[row.int64(at: 0)] = row.int(at: 1)
        }
        let missing = try missingPhotoIDs()
        if !missing.isEmpty {
            try database.cached("""
            SELECT keyword, count(*) FROM photo_keywords WHERE photo IN (\(Self.missingPhotos)) GROUP BY keyword
            """).forEachRow { row in
                own[row.int64(at: 0), default: 0] -= row.int(at: 1)
            }
        }
        for (id, photos) in own {
            if let first = chains[id]?.first {
                counts[Int(first)].photos += photos
            }
        }
        var current: Int64?
        var keywords: [Int64] = []
        var seen = Set<Int32>()
        func countPhoto() {
            if keywords.count == 1 {
                for node in chains[keywords[0]] ?? [] {
                    counts[Int(node)].count += 1
                }
            } else {
                seen.removeAll(keepingCapacity: true)
                for keyword in keywords {
                    for node in chains[keyword] ?? [] where seen.insert(node).inserted {
                        counts[Int(node)].count += 1
                    }
                }
            }
            keywords.removeAll(keepingCapacity: true)
        }
        try database.cached("SELECT photo, keyword FROM photo_keywords ORDER BY photo").forEachRow { row in
            let photo = row.int64(at: 0)
            guard !missing.contains(photo) else { return }
            if photo != current, current != nil {
                countPhoto()
            }
            current = photo
            keywords.append(row.int64(at: 1))
        }
        if current != nil {
            countPhoto()
        }
        return nodes.reduce(into: [:]) { $0[$1.key] = counts[Int($1.value)] }
    }

    /// Each of `ids`' keywords in the index, by photo; a photo the index has without keywords has an
    /// empty list, and one it doesn't have none.
    func keywordPaths(ofPhotos ids: [Int64]) throws -> [Int64: [KeywordPath]] {
        let exists = try database.cached("SELECT 1 FROM photos WHERE id = ?")
        var found: [Int64: [KeywordPath]] = [:]
        for id in ids {
            try exists.bind(id, at: 1)
            guard try exists.first({ _ in true }) == true else { continue }
            found[id] = try keywords(forPhoto: id).compactMap(KeywordPath.init)
        }
        return found
    }

    /// The photos with any keyword within `paths`, in ID order.
    func photoIDs(withKeywordsWithin paths: [KeywordPath]) throws -> [Int64] {
        var ids = Set<Int64>()
        for path in paths {
            try ids.formUnion(photoIDs(withKeyword: path.text, includingChildren: true))
        }
        return ids.sorted()
    }

    /// Each photo's path, the photo whose sidecar a change writes: its folder's path, a slash and its name. Photos
    /// missing
    /// from their folders (DEC-59) are left out, as photos the index doesn't have are: changes leave them as they are.
    func photoPaths(_ ids: [Int64]) throws -> [Int64: String] {
        let statement = try database.cached("""
        SELECT f.path || '/' || p.name FROM photos p JOIN folders f ON f.id = p.folder
        WHERE p.id = ? AND p.state & \(PhotoRecord.State.missing.rawValue) = 0
        """)
        var paths: [Int64: String] = [:]
        for id in ids {
            try statement.bind(id, at: 1)
            paths[id] = try statement.first { $0.string(at: 0) } ?? nil
        }
        return paths
    }

    /// The keywords applied last, the latest first (Recent Keywords).
    func recentKeywords() throws -> [KeywordPath] {
        guard let text = try setting(LibraryKeywords.recentKey),
              let texts = try? JSONDecoder().decode([String].self, from: Data(text.utf8))
        else { return [] }
        return KeywordPath.paths(texts)
    }
}

extension LibraryIndex.Writer {
    /// Gives each photo its keywords, `[]` for none.
    func setKeywords(_ keywords: [Int64: [KeywordPath]]) throws {
        for (photo, paths) in keywords.sorted(by: { $0.key < $1.key }) {
            try setKeywords(paths.map(\.text), forPhoto: photo)
        }
    }

    /// Removes the rows of keywords within `paths` that no photo has and that contain none that one has,
    /// and those of the keywords containing them that are left the same way.
    func removeUnusedKeywords(within paths: [KeywordPath]) throws {
        let subtree = try database.cached("""
        DELETE FROM keywords WHERE (path = ?1 OR (path >= ?2 AND path < ?3))
          AND id NOT IN (SELECT keyword FROM photo_keywords)
          AND NOT EXISTS (SELECT 1 FROM keywords below JOIN photo_keywords pk ON pk.keyword = below.id
            WHERE below.path >= keywords.path || '/' AND below.path < keywords.path || '0')
        """)
        let alone = try database.cached("""
        DELETE FROM keywords WHERE path = ?1 AND id NOT IN (SELECT keyword FROM photo_keywords)
          AND NOT EXISTS (SELECT 1 FROM keywords below WHERE below.path >= ?2 AND below.path < ?3)
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

    /// Puts `keywords` at the front of Recent Keywords.
    func recordRecent(_ keywords: [KeywordPath]) throws {
        guard !keywords.isEmpty else { return }
        var recent = keywords
        for keyword in try recentKeywords() where !recent.contains(keyword) {
            recent.append(keyword)
        }
        let texts = recent.prefix(KeywordSet.size).map(\.text)
        try setSetting(String(decoding: JSONEncoder().encode(texts), as: UTF8.self), for: LibraryKeywords.recentKey)
    }
}
