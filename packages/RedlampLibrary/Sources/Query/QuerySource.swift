import Foundation

/// What the query engine reads besides its column store: the store itself, the small tables, the
/// text index, keywords' and collections' photos, and SQL for before the store is ready. The index
/// answers all of it (`IndexQuerySource`); tests answer with synthetic libraries.
protocol QuerySource: Sendable {
    func columnStore() async throws -> ColumnStore
    func names() async throws -> QueryNames
    /// The photos matching an FTS5 query of `photo_text`.
    func photoIDs(matching match: String) async throws -> [Int64]
    func photoIDs(withKeywords keywords: [Int64]) async throws -> [Int64]
    func photoIDs(inCollections collections: [Int64]) async throws -> [Int64]
    /// `store` with photos `ids` as the index has them now: changed, added or gone.
    func applying(_ ids: [Int64], to store: ColumnStore) async throws -> ColumnStore
    /// The IDs `sql` returns, handing the first `pageSize` to `firstPage` as soon as they're read.
    func run(
        _ sql: QuerySQL, pageSize: Int, cancellation: QueryCancellation,
        firstPage: @escaping @Sendable (ContiguousArray<Int64>) -> Void,
    ) async throws -> ContiguousArray<Int64>
}

/// The library's small tables by ID: thousands of rows where photos are millions. Folder, camera,
/// lens, keyword and collection terms are matched here, then become IDs for the column pass.
struct QueryNames: Sendable, Hashable {
    var folders: [Int64: String] = [:]
    var cameras: [Int64: String] = [:]
    var lenses: [Int64: String] = [:]
    var keywords: [Int64: String] = [:]
    /// Each collection's path from the top (`Portfolio/2024`); a collection whose parents don't
    /// lead to the top has none.
    var collections: [Int64: String] = [:]

    /// The IDs whose names `matches`, in order.
    static func ids(_ names: [Int64: String], where matches: (String) -> Bool) -> [Int64] {
        names.compactMap { matches($0.value) ? $0.key : nil }.sorted()
    }
}

/// The query engine's view of a `LibraryIndex`.
struct IndexQuerySource: QuerySource {
    let index: LibraryIndex

    func columnStore() async throws -> ColumnStore {
        try await index.read { try $0.columnStore() }
    }

    func names() async throws -> QueryNames {
        try await index.read { try $0.queryNames() }
    }

    func photoIDs(matching match: String) async throws -> [Int64] {
        try await index.read { reader in
            let statement = try reader.database.cached("SELECT rowid FROM photo_text WHERE photo_text MATCH ?")
            try statement.bind(match, at: 1)
            return try statement.map { $0.int64(at: 0) }
        }
    }

    func photoIDs(withKeywords keywords: [Int64]) async throws -> [Int64] {
        try await photoIDs(keywords, "SELECT photo FROM photo_keywords WHERE keyword = ?")
    }

    func photoIDs(inCollections collections: [Int64]) async throws -> [Int64] {
        try await photoIDs(collections, "SELECT photo FROM collection_photos WHERE collection = ?")
    }

    private func photoIDs(_ owners: [Int64], _ sql: String) async throws -> [Int64] {
        guard !owners.isEmpty else { return [] }
        return try await index.read { reader in
            let statement = try reader.database.cached(sql)
            var ids: [Int64] = []
            for owner in owners {
                try statement.bind(owner, at: 1)
                try statement.forEachRow { ids.append($0.int64(at: 0)) }
            }
            return ids
        }
    }

    func applying(_ ids: [Int64], to store: ColumnStore) async throws -> ColumnStore {
        try await index.read { reader in
            let rows = try reader.columnRows(ids: ids)
            let found = Set(rows.map(\.hot.id))
            var store = store
            try store.apply(ColumnStore.Changes(upserted: rows, removed: ids.filter { !found.contains($0) })) {
                try reader.photoName(id: $0)
            }
            return store
        }
    }

    func run(
        _ sql: QuerySQL, pageSize: Int, cancellation: QueryCancellation,
        firstPage: @escaping @Sendable (ContiguousArray<Int64>) -> Void,
    ) async throws -> ContiguousArray<Int64> {
        try await index.read { reader in
            var ids = ContiguousArray<Int64>()
            try reader.run(sql, cancellation: cancellation) { id in
                ids.append(id)
                if ids.count == pageSize {
                    firstPage(ids)
                }
            }
            return ids
        }
    }
}

extension IndexQueries {
    func queryNames() throws -> QueryNames {
        var folders: [Int64: String] = [:]
        try database.cached("SELECT id, path FROM folders").forEachRow { folders[$0.int64(at: 0)] = $0.string(at: 1) }
        var collections: [Int64: (parent: Int64?, name: String)] = [:]
        try database.cached("SELECT id, parent, name FROM collections").forEachRow { row in
            collections[row.int64(at: 0)] = (row.optionalInt64(at: 1), row.string(at: 2) ?? "")
        }
        var paths: [Int64: String] = [:]
        for id in collections.keys {
            var names: [String] = []
            var next: Int64? = id
            while let current = next, let collection = collections[current], names.count < QuerySQL.collectionDepth {
                names.append(collection.name)
                next = collection.parent
            }
            if next == nil {
                paths[id] = names.reversed().joined(separator: "/")
            }
        }
        return try QueryNames(
            folders: folders, cameras: cameraNames(), lenses: lensNames(), keywords: keywordPaths(), collections: paths,
        )
    }
}
