import Foundation
import Synchronization

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
    /// The synonyms of the library's keywords, by keyword path (LIB-21).
    func keywordSynonyms() async throws -> [String: [String]]
    /// `store` with photos `ids` as the index has them now: changed, added or gone.
    func applying(_ ids: [Int64], to store: ColumnStore) async throws -> ColumnStore
    /// The IDs `sql` returns, handing the first `pageSize` to `firstPage` as soon as they're read.
    func run(
        _ sql: QuerySQL, pageSize: Int, cancellation: QueryCancellation,
        firstPage: @escaping @Sendable (ContiguousArray<Int64>) -> Void,
    ) async throws -> ContiguousArray<Int64>
}

extension QuerySource {
    func keywordSynonyms() async throws -> [String: [String]] {
        [:]
    }
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
    /// The synonyms of the keywords that have some, by path, from the library's definitions.
    var keywordSynonyms: [String: [String]] = [:]

    /// The IDs whose names `matches`, in order.
    static func ids(_ names: [Int64: String], where matches: (String) -> Bool) -> [Int64] {
        names.compactMap { matches($0.value) ? $0.key : nil }.sorted()
    }
}

/// The small tables ready to match terms against, made again whenever they're read, keeping what
/// each term matched: typing a character at a time asks about the same terms again and again.
final class QueryVocabulary: Sendable {
    enum Table: Sendable, Hashable {
        case folders, cameras, lenses, keywords, collections
        /// Keywords by what their synonyms hold, for free text.
        case keywordSynonyms
    }

    let names: QueryNames
    private let folders: NameMatcher
    private let cameras: NameMatcher
    private let lenses: NameMatcher
    /// Made the first time a keyword term needs it.
    private let keywords = Mutex<KeywordMatcher?>(nil)
    private let matched = Mutex<[Match: [Int64]]>([:])

    private struct Match: Hashable {
        let table: Table
        let text: String
    }

    init(_ names: QueryNames = QueryNames()) {
        self.names = names
        folders = NameMatcher(names.folders)
        cameras = NameMatcher(names.cameras)
        lenses = NameMatcher(names.lenses)
    }

    /// The IDs in `table` that `text` matches, in order: folders, cameras and lenses whose path or
    /// name holds it (`QueryText.contains`), keywords it names or is a synonym of (`KeywordQuery`) and
    /// those with a synonym holding it, and collections it names (`QueryText.levelsMatch`).
    func ids(in table: Table, matching text: String) -> [Int64] {
        let match = Match(table: table, text: text)
        if let ids = matched.withLock({ $0[match] }) {
            return ids
        }
        let ids = switch table {
        case .folders: folders.ids(containing: text)
        case .cameras: cameras.ids(containing: text)
        case .lenses: lenses.ids(containing: text)
        case .keywords: keywordMatcher().ids(matching: text)
        case .keywordSynonyms: keywordMatcher().ids(withSynonymContaining: text)
        case .collections: QueryNames.ids(names.collections) { QueryText.levelsMatch(path: $0, value: text) }
        }
        matched.withLock { matched in
            if matched.count >= 4096 {
                matched.removeAll()
            }
            matched[match] = ids
        }
        return ids
    }

    /// Whether any keyword has a synonym: free text looks them up only then.
    var hasKeywordSynonyms: Bool {
        !names.keywordSynonyms.isEmpty
    }

    private func keywordMatcher() -> KeywordMatcher {
        keywords.withLock { matcher in
            if let matcher {
                return matcher
            }
            let made = KeywordMatcher(keywords: names.keywords, synonyms: names.keywordSynonyms)
            matcher = made
            return made
        }
    }
}

/// A table's names, with the ASCII ones lowercased once, so `QueryText.contains` runs over thousands
/// of folders' paths in well under a millisecond.
private struct NameMatcher: Sendable {
    private let ids: [Int64]
    private let names: [String]
    private let lowercased: [ContiguousArray<UInt8>?]

    init(_ table: [Int64: String]) {
        let sorted = table.sorted { $0.key < $1.key }
        ids = sorted.map(\.key)
        names = sorted.map(\.value)
        lowercased = names.map(QueryText.asciiLowercased)
    }

    func ids(containing part: String) -> [Int64] {
        let needle = QueryText.asciiLowercased(part)
        return ids.indices.compactMap { index in
            let found = if let needle, let name = lowercased[index] {
                QueryText.contains(name, needle)
            } else {
                QueryText.contains(names[index], part)
            }
            return found ? ids[index] : nil
        }
    }
}

/// The query engine's view of a `LibraryIndex`.
struct IndexQuerySource: QuerySource {
    let index: LibraryIndex

    func columnStore() async throws -> ColumnStore {
        try await index.read { try $0.columnStore() }
    }

    func names() async throws -> QueryNames {
        var names = try await index.read { try $0.queryNames() }
        names.keywordSynonyms = try await keywordSynonyms()
        return names
    }

    func keywordSynonyms() async throws -> [String: [String]] {
        let url = KeywordDefinitions.url(in: LibraryPaths(root: index.url.deletingLastPathComponent()))
        return try await LibraryIndex.offCaller { KeywordDefinitions.cached(at: url).synonyms }
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

public extension IndexQueries {
    /// The photo's path: its folder's path, a slash and its name.
    func photoPath(id: Int64) throws -> String? {
        let statement = try database.cached("""
        SELECT f.path || '/' || p.name FROM photos p JOIN folders f ON f.id = p.folder WHERE p.id = ?
        """)
        try statement.bind(id, at: 1)
        return try statement.first { $0.string(at: 0) } ?? nil
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
