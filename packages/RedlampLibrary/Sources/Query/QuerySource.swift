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
    /// The keywords of photos `ids`, or of every photo when nil, in the order of their photos' IDs.
    func photoKeywords(of ids: [Int64]?) async throws -> [PhotoKeyword]
    /// The collections of photos `ids`, or of every photo when nil, alike.
    func photoCollections(of ids: [Int64]?) async throws -> [PhotoKeyword]
    /// The state of every photo that's missing, offline or settling.
    func photoStates() async throws -> [Int64: PhotoRecord.State]
    /// `store` with photos `ids` as the index has them now: changed, added or gone.
    func applying(_ ids: [Int64], to store: ColumnStore) async throws -> ColumnStore
    /// What Library Health's `check` finds among `store`'s photos (LIB-40).
    func healthFindings(_ check: HealthCheck, store: ColumnStore) async throws -> HealthFindings
    /// Photos `ids` that can be in a raw and JPEG pair, or every one when nil (LIB-40).
    func pairPhotos(of ids: [Int64]?) async throws -> [HealthPairs.Photo]
    /// What the pairs check finds under `rule` among `store`'s photos, judging only what changed in
    /// `pairs` and recording what it found there.
    func pairFindings(_ rule: PairRule, store: ColumnStore, pairs: inout HealthPairs) async throws -> HealthFindings
    /// The photos whose findings were kept anyway (LIB-40).
    func keptAnyway() async throws -> [Int64]
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

    func photoKeywords(of _: [Int64]?) async throws -> [PhotoKeyword] {
        []
    }

    func photoCollections(of _: [Int64]?) async throws -> [PhotoKeyword] {
        []
    }

    func photoStates() async throws -> [Int64: PhotoRecord.State] {
        [:]
    }

    func healthFindings(_ check: HealthCheck, store _: ColumnStore) async throws -> HealthFindings {
        HealthFindings(check: check)
    }

    func pairPhotos(of _: [Int64]?) async throws -> [HealthPairs.Photo] {
        []
    }

    func pairFindings(
        _ rule: PairRule,
        store _: ColumnStore,
        pairs _: inout HealthPairs,
    ) async throws -> HealthFindings {
        HealthFindings(check: .pairs(rule))
    }

    func keptAnyway() async throws -> [Int64] {
        []
    }
}

/// A photo and one of its keywords, as `photo_keywords` holds them, or one of its collections, as
/// `collection_photos` does.
struct PhotoKeyword: Sendable, Hashable {
    var photo: Int64
    var keyword: Int64
}

/// The library's small tables by ID: thousands of rows where photos are millions. Folder, camera,
/// lens, keyword and collection terms are matched here, then become IDs for the column pass.
struct QueryNames: Sendable, Hashable {
    var folders: [Int64: String] = [:]
    var cameras: [Int64: String] = [:]
    var lenses: [Int64: String] = [:]
    var keywords: [Int64: String] = [:]
    /// The paths of the collections photos are in, and of the sets above them (`Portfolio/2024`), as
    /// a keyword's are written.
    var collections: [Int64: String] = [:]
    /// The synonyms of the keywords that have some, by path, from the library's definitions.
    var keywordSynonyms: [String: [String]] = [:]
    /// The smart collections' queries, by path, from the library's definitions (LIB-23).
    var smartCollections: [String: String] = [:]
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
    /// Made the first time a keyword or collection term needs it.
    private let keywords = Mutex<KeywordMatcher?>(nil)
    private let collections = Mutex<KeywordMatcher?>(nil)
    private let matched = Mutex<[Match: [Int64]]>([:])
    /// Made the first time a column of keywords or collections is counted, or keywords completed
    /// (LIB-18).
    let levels = Mutex<[PostingKind: KeywordLevels]>([:])
    let completion = Mutex<KeywordCompletion?>(nil)
    /// Read the first time a collection's photos are listed.
    private let smart = Mutex<[(path: CollectionPath, query: LibraryQuery?)]?>(nil)

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
    /// those with a synonym holding it, and collections it names, as it names keywords.
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
        case .collections: collectionMatcher().ids(matching: text)
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

    /// The smart collections and their queries; nil for a query this build can't read, which finds
    /// nothing.
    func smartCollections() -> [(path: CollectionPath, query: LibraryQuery?)] {
        smart.withLock { smart in
            if let smart {
                return smart
            }
            let read = names.smartCollections.sorted { $0.key < $1.key }.compactMap { text, query in
                CollectionPath(text).map { ($0, try? LibraryQuery(parsing: query)) }
            }
            smart = read
            return read
        }
    }

    private func collectionMatcher() -> KeywordMatcher {
        collections.withLock { matcher in
            if let matcher {
                return matcher
            }
            let made = KeywordMatcher(keywords: names.collections, synonyms: [:])
            matcher = made
            return made
        }
    }
}

/// A table's names, each folded once (`FoldedText`), so a search runs over thousands of folders'
/// paths byte by byte, as `QueryText.contains` matches them, whatever their letters.
private struct NameMatcher: Sendable {
    private let ids: [Int64]
    private let folded: [FoldedText]

    init(_ table: [Int64: String]) {
        let sorted = table.sorted { $0.key < $1.key }
        ids = sorted.map(\.key)
        folded = sorted.map { FoldedText($0.value) }
    }

    func ids(containing part: String) -> [Int64] {
        let needle = FoldedText(part)
        return ids.indices.compactMap { folded[$0].contains(needle) ? ids[$0] : nil }
    }
}

/// The query engine's view of a `LibraryIndex`.
struct IndexQuerySource: QuerySource {
    let index: LibraryIndex

    /// Read in parts, a range of photo IDs on each of the index's readers, the last open-ended, once
    /// the index file is in memory, then joined. Each part is read in a transaction of its own:
    /// what's written while they're read reaches the store through the updates that follow the load.
    func columnStore() async throws -> ColumnStore {
        await index.readAhead()
        guard let ids = try await index.read({ try $0.photoIDs() }) else { return ColumnStore() }
        let ranges = Self.ranges(ids, parts: index.readerCount)
        let capacity = Int(ids.upperBound - ids.lowerBound) / ranges.count + 1
        let parts = try await withThrowingTaskGroup(of: (Int, ColumnStore.Part).self) { [index] group in
            for (number, range) in ranges.enumerated() {
                group.addTask {
                    try await (number, index.read { try $0.columnStorePart(ids: range, capacity: capacity) })
                }
            }
            var parts = [ColumnStore.Part](repeating: ColumnStore.Part(), count: ranges.count)
            for try await (number, part) in group {
                parts[number] = part
            }
            return parts
        }
        return await ColumnStore.joining(parts)
    }

    /// `ids` cut into at most `parts` ranges of about as many IDs, the last reaching every ID above.
    static func ranges(_ ids: ClosedRange<Int64>, parts: Int) -> [ClosedRange<Int64>] {
        let width = max((ids.upperBound - ids.lowerBound) / Int64(max(parts, 1)) + 1, 1)
        var ranges: [ClosedRange<Int64>] = []
        var lower = ids.lowerBound
        while lower <= ids.upperBound {
            let upper = lower + width - 1
            ranges.append(lower ... (upper >= ids.upperBound ? .max : upper))
            lower = upper + 1
        }
        return ranges
    }

    func names() async throws -> QueryNames {
        var names = try await index.read { try $0.queryNames() }
        names.keywordSynonyms = try await keywordSynonyms()
        let collections = CollectionDefinitions.url(in: paths)
        names.smartCollections = try await LibraryIndex.offCaller {
            CollectionDefinitions.cached(at: collections).smartQueries
        }
        return names
    }

    func keywordSynonyms() async throws -> [String: [String]] {
        let url = KeywordDefinitions.url(in: paths)
        return try await LibraryIndex.offCaller { KeywordDefinitions.cached(at: url).synonyms }
    }

    /// The library whose index it is, at `LibraryPaths.index` in its folder.
    private var paths: LibraryPaths {
        LibraryPaths(root: index.url.deletingLastPathComponent())
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

    func photoKeywords(of ids: [Int64]?) async throws -> [PhotoKeyword] {
        try await pairs(of: ids, table: "photo_keywords", owner: "keyword")
    }

    func photoCollections(of ids: [Int64]?) async throws -> [PhotoKeyword] {
        try await pairs(of: ids, table: "collection_photos", owner: "collection")
    }

    /// The photos and owners `table` pairs for photos `ids`, or for every photo, in the order of the
    /// photos' IDs.
    private func pairs(of ids: [Int64]?, table: String, owner: String) async throws -> [PhotoKeyword] {
        try await index.read { reader in
            var found: [PhotoKeyword] = []
            guard let ids else {
                try reader.database.cached("SELECT photo, \(owner) FROM \(table) ORDER BY photo, \(owner)")
                    .forEachRow { found.append(PhotoKeyword(photo: $0.int64(at: 0), keyword: $0.int64(at: 1))) }
                return found
            }
            let statement = try reader.database.cached(
                "SELECT \(owner) FROM \(table) WHERE photo = ? ORDER BY \(owner)",
            )
            for id in Set(ids).sorted() {
                try statement.bind(id, at: 1)
                try statement.forEachRow { found.append(PhotoKeyword(photo: id, keyword: $0.int64(at: 0))) }
            }
            return found
        }
    }

    func photoStates() async throws -> [Int64: PhotoRecord.State] {
        try await index.read { reader in
            var states: [Int64: PhotoRecord.State] = [:]
            try reader.database.cached("SELECT id, state FROM photos WHERE state != 0").forEachRow { row in
                states[row.int64(at: 0)] = PhotoRecord.State(rawValue: row.int(at: 1))
            }
            return states
        }
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

    func healthFindings(_ check: HealthCheck, store: ColumnStore) async throws -> HealthFindings {
        try await HealthChecker(index: index, paths: paths).findings(check, store: store)
    }

    func pairPhotos(of ids: [Int64]?) async throws -> [HealthPairs.Photo] {
        try await index.read { try $0.pairPhotos(of: ids) }
    }

    func pairFindings(_ rule: PairRule, store: ColumnStore, pairs: inout HealthPairs) async throws -> HealthFindings {
        try await HealthChecker(index: index, paths: paths).pairs(rule, store: store, following: &pairs)
    }

    func keptAnyway() async throws -> [Int64] {
        try await HealthChecker(index: index, paths: paths).keptAnyway().map(\.photo)
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
        var collections: [Int64: String] = [:]
        try database.cached("SELECT id, path FROM collections WHERE path IS NOT NULL").forEachRow { row in
            collections[row.int64(at: 0)] = row.string(at: 1)
        }
        return try QueryNames(
            folders: folders, cameras: cameraNames(), lenses: lensNames(), keywords: keywordPaths(),
            collections: collections,
        )
    }
}
