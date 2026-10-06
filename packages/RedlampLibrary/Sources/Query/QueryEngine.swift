import Foundation
import Synchronization

/// What a search found: the first page as soon as it's full, then every photo.
public struct QueryResult: Sendable, Hashable {
    /// The photos' IDs in the sort's order: the first page, or all of them once it's complete.
    public var ids: ContiguousArray<Int64>
    /// How many photos match: known with the first page once the column store is ready, and with the
    /// complete result before.
    public var count: Int?
    public var isComplete: Bool

    public init(ids: ContiguousArray<Int64>, count: Int?, isComplete: Bool) {
        self.ids = ids
        self.count = count
        self.isComplete = isComplete
    }
}

/// Searches the library (LIB-06). Queries run over the column store, built from the index in the
/// background by `load`: text, keyword and collection terms are looked up in the index, folder,
/// camera and lens terms in its small tables, then one pass over the columns finds the photos and
/// one in the sort's order lists them. Until the store is ready, a query is compiled to SQL and the
/// index answers it.
///
/// A search cancels the one before it, and its facets; nothing runs on the caller's thread. What the
/// index looked up for a term, and what a query found, is kept until the store changes, so typing a
/// character at a time looks up only what changed.
public final class QueryEngine: Sendable {
    let source: any QuerySource
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date
    private let state = Mutex(State())

    private struct State {
        var store: ColumnStore?
        var vocabulary = QueryVocabulary()
        /// Changes with the store, so what was kept for another store isn't used.
        var generation = 0
        var plans: [PlanKey: QueryPlan] = [:]
        var rowSets: [QueryPlan.RowSet: RowBits] = [:]
        var matches: [QueryPlan: RowBits] = [:]
        var search: Task<Void, Never>?
        var facets: Task<Void, Never>?
        /// Loading and updates, one at a time in the order they're asked for.
        var changing: Task<Void, any Error>?
        /// Each photo's keywords or collections, once a column of them is counted, and the photos
        /// changed since.
        var postings: [PostingKind: KeywordPostings] = [:]
        var stalePostings: [PostingKind: Set<Int64>] = [:]
        var readingPostings: [PostingKind: Int] = [:]
        /// The columns counted for this store, by what they counted.
        var columnCounts: [ColumnKey: FacetColumnCounts] = [:]
        /// What Library Health's checks found in this store (LIB-40).
        var health: [HealthCheck: HealthFindings] = [:]
    }

    /// A column counted over a source's photos in a store.
    struct ColumnKey: Hashable {
        let generation: Int
        let source: PhotoSource
        let column: FacetColumn
        let query: LibraryQuery?
        let today: Int
    }

    /// A query as it's compiled: the day decides what `today` is.
    private struct PlanKey: Hashable {
        let query: LibraryQuery?
        let today: Int
    }

    /// Plans, row sets and results kept, at most, before they're dropped.
    private static let kept = 64

    /// `timeZone` and `now` decide what `today` and `last:30d` are.
    public convenience init(
        index: LibraryIndex, timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = Date.init,
    ) {
        self.init(source: IndexQuerySource(index: index), timeZone: timeZone, now: now)
    }

    init(source: any QuerySource, timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = Date.init) {
        self.source = source
        self.timeZone = timeZone
        self.now = now
    }

    /// Whether the column store is built: until it is, searches go to SQLite.
    public var isLoaded: Bool {
        state.withLock { $0.store != nil }
    }

    /// The column store as it is now, once it's built.
    public var store: ColumnStore? {
        state.withLock { $0.store }
    }

    /// Builds the column store from the index, with the small tables beside it.
    public func load() async throws {
        state.withLock { $0.postings = [:] }
        try await change { [source] _ in
            async let names = source.names()
            return try await (source.columnStore(), names)
        }
    }

    /// Brings the column store up to date with photos `ids` as the index has them now: added,
    /// changed or removed. Call it once their writes are committed; until the store is loaded there's
    /// nothing to do, since loading reads them.
    public func update(photos ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        state.withLock { state in
            for kind in [PostingKind.keywords, .collections]
                where state.postings[kind] != nil || state.readingPostings[kind, default: 0] > 0 {
                state.stalePostings[kind, default: []].formUnion(ids)
            }
        }
        try await change { [source] store in
            guard let store else { return nil }
            async let names = source.names()
            return try await (source.applying(ids, to: store), names)
        }
    }

    /// Reads the small tables again: after folders are renamed or moved, or keywords or collections
    /// change without their photos.
    public func updateNames() async throws {
        try await change { [source] store in
            guard let store else { return nil }
            return try await (store, source.names())
        }
    }

    /// Keeps `key`'s order in the store from now on, sorting it once, unless it's kept already.
    func prepareOrder(_ key: QuerySort.Key) async throws {
        guard state.withLock({ $0.store.map { !$0.keepsOrder(key) } ?? false }) else { return }
        try await change { [self] store in
            guard var store, !store.keepsOrder(key) else { return nil }
            store.prepareOrder(key)
            return (store, state.withLock { $0.vocabulary.names })
        }
    }

    /// Runs `body` after the changes asked for before, and replaces the store and the names with
    /// what it returns.
    private func change(
        _ body: @escaping @Sendable (ColumnStore?) async throws -> (ColumnStore, QueryNames)?,
    ) async throws {
        let task = state.withLock { state in
            let previous = state.changing
            let task = Task { [self] in
                _ = await previous?.result
                guard let (store, names) = try await body(self.state.withLock { $0.store }) else { return }
                let vocabulary = QueryVocabulary(names)
                self.state.withLock { state in
                    state.store = store
                    state.vocabulary = vocabulary
                    state.generation += 1
                    state.plans.removeAll()
                    state.rowSets.removeAll()
                    state.matches.removeAll()
                    state.columnCounts.removeAll()
                    state.health.removeAll()
                }
            }
            state.changing = task
            return task
        }
        try await task.value
    }

    // MARK: - Searching

    /// The photos `query` finds, in `sort`'s order: the first `pageSize` as soon as they're found,
    /// then all of them. Cancels the search before it and its facets. The stream finishes early,
    /// throwing `CancellationError`, when a newer search cancels it.
    public func search(
        _ query: LibraryQuery, sort: QuerySort = QuerySort(), pageSize: Int = 100,
    ) -> AsyncThrowingStream<QueryResult, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: QueryResult.self)
        let task = Task.detached(priority: .userInitiated) { [self] in
            do {
                try await find(query.searchable, sort: sort, pageSize: max(pageSize, 1)) { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        let previous = state.withLock { state in
            defer { state.search = task }
            state.facets?.cancel()
            return state.search
        }
        previous?.cancel()
        return stream
    }

    private func find(
        _ query: LibraryQuery?, sort: QuerySort, pageSize: Int, yield: @escaping @Sendable (QueryResult) -> Void,
    ) async throws {
        if snapshot().map({ !$0.0.keepsOrder(sort.key) }) == true {
            try await prepareOrder(sort.key)
        }
        guard let (store, vocabulary, generation) = snapshot() else {
            return try await searchSQL(query, sort: sort, pageSize: pageSize, yield: yield)
        }
        var matches = try await matches(for: query, in: store, vocabulary: vocabulary, generation: generation)
        if query?.findsUnreadable != true {
            matches = store.readable(matches)
        }
        let count = matches.count
        let order = store.order(sort.key)
        var ids = ContiguousArray<Int64>()
        ids.reserveCapacity(min(count, pageSize))
        var place = store.collect(
            matches, in: order, ascending: sort.ascending, from: 0, limit: pageSize, places: order.count, into: &ids,
        )
        guard ids.count < count else { return yield(QueryResult(ids: ids, count: count, isComplete: true)) }
        yield(QueryResult(ids: ids, count: count, isComplete: false))
        ids.reserveCapacity(count)
        while ids.count < count, place < order.count {
            try Task.checkCancellation()
            place = store.collect(
                matches, in: order, ascending: sort.ascending, from: place, limit: count, places: 1 << 16, into: &ids,
            )
        }
        yield(QueryResult(ids: ids, count: count, isComplete: true))
    }

    private func searchSQL(
        _ query: LibraryQuery?, sort: QuerySort, pageSize: Int, yield: @escaping @Sendable (QueryResult) -> Void,
    ) async throws {
        let sql = try await QuerySQL(query, sort: sort, today: today, synonyms: source.keywordSynonyms())
        let cancellation = QueryCancellation()
        let ids = try await withTaskCancellationHandler {
            try await source.run(sql, pageSize: pageSize, cancellation: cancellation) { page in
                yield(QueryResult(ids: page, count: nil, isComplete: false))
            }
        } onCancel: {
            cancellation.cancel()
        }
        yield(QueryResult(ids: ids, count: ids.count, isComplete: true))
    }

    /// The store, the small tables and their generation, once the store is built.
    func snapshot() -> (ColumnStore, QueryVocabulary, Int)? {
        state.withLock { state in state.store.map { ($0, state.vocabulary, state.generation) } }
    }

    /// The store's snapshot once it's loaded, waiting for a load in progress.
    func loadedSnapshot() async -> (ColumnStore, QueryVocabulary, Int)? {
        if let snapshot = snapshot() {
            return snapshot
        }
        _ = await state.withLock { $0.changing }?.result
        return snapshot()
    }

    var today: Int {
        QueryCalendar.today(now: now(), timeZone: timeZone)
    }

    /// The rows `query` finds in `store`, compiling it unless its plan is kept.
    func matches(
        for query: LibraryQuery?, in store: ColumnStore, vocabulary: QueryVocabulary, generation: Int,
    ) async throws -> RowBits {
        let key = PlanKey(query: query, today: today)
        let (kept, keptMatches) = state.withLock { state -> (QueryPlan?, RowBits?) in
            guard state.generation == generation, let plan = state.plans[key] else { return (nil, nil) }
            return (plan, state.matches[plan])
        }
        if let keptMatches {
            return keptMatches
        }
        let plan = kept ?? QueryPlan(query, store: store, vocabulary: vocabulary, today: key.today)
        if kept == nil {
            state.withLock { state in
                guard state.generation == generation else { return }
                if state.plans.count >= Self.kept {
                    state.plans.removeAll()
                }
                state.plans[key] = plan
            }
        }
        return try await rows(for: plan, in: store, generation: generation)
    }

    /// The rows `plan` finds in `store`, looking up its row sets in the index unless they're kept.
    func rows(for plan: QueryPlan, in store: ColumnStore, generation: Int) async throws -> RowBits {
        if let kept = state.withLock({ $0.generation == generation ? $0.matches[plan] : nil }) {
            return kept
        }
        var sets: [QueryPlan.RowSet: RowBits] = [:]
        for set in plan.rowSets {
            if let kept = state.withLock({ $0.generation == generation ? $0.rowSets[set] : nil }) {
                sets[set] = kept
                continue
            }
            try Task.checkCancellation()
            let rows = try await store.rows(withIDs: photoIDs(set))
            sets[set] = rows
            state.withLock { state in
                guard state.generation == generation else { return }
                if state.rowSets.count >= Self.kept {
                    state.rowSets.removeAll()
                }
                state.rowSets[set] = rows
            }
        }
        try Task.checkCancellation()
        let matches = store.rows(matching: plan, sets: sets)
        state.withLock { state in
            guard state.generation == generation else { return }
            if state.matches.count >= Self.kept {
                state.matches.removeAll()
            }
            state.matches[plan] = matches
        }
        return matches
    }

    private func photoIDs(_ set: QueryPlan.RowSet) async throws -> [Int64] {
        switch set {
        case let .match(match): try await source.photoIDs(matching: match)
        case let .keywords(keywords): try await source.photoIDs(withKeywords: keywords)
        case let .collections(collections): try await source.photoIDs(inCollections: collections)
        }
    }

    // MARK: - Library Health

    /// What Library Health's `check` finds in the store as it is now (LIB-40), worked out once for
    /// each version of the store, loading it first if it isn't. Off the caller's thread.
    public func healthFindings(_ check: HealthCheck) async throws -> HealthFindings {
        if await loadedSnapshot() == nil {
            try await load()
        }
        guard let (store, _, generation) = snapshot() else { return HealthFindings(check: check) }
        return try await healthFindings(check, in: store, generation: generation)
    }

    func healthFindings(_ check: HealthCheck, in store: ColumnStore, generation: Int) async throws -> HealthFindings {
        if let kept = state.withLock({ $0.generation == generation ? $0.health[check] : nil }) {
            return kept
        }
        let found = try await Task.detached(priority: .userInitiated) { [source] in
            try await source.healthFindings(check, store: store)
        }.value
        state.withLock { state in
            if state.generation == generation {
                state.health[check] = found
            }
        }
        return found
    }

    /// Replaces the facets in progress with `task`, cancelling them.
    func startFacets(_ task: Task<Void, Never>) {
        state.withLock { state in
            state.facets?.cancel()
            state.facets = task
        }
    }

    // MARK: - Kept for the filter bar's columns

    func countedColumn(_ key: ColumnKey) -> FacetColumnCounts? {
        state.withLock { $0.generation == key.generation ? $0.columnCounts[key] : nil }
    }

    func keepColumn(_ counts: FacetColumnCounts, for key: ColumnKey) {
        state.withLock { state in
            guard state.generation == key.generation else { return }
            if state.columnCounts.count >= Self.kept {
                state.columnCounts.removeAll()
            }
            state.columnCounts[key] = counts
        }
    }

    /// Each photo's keywords or collections: read from the index the first time, then only those of
    /// the photos changed since.
    func postings(_ kind: PostingKind) async throws -> KeywordPostings {
        let (kept, stale) = state.withLock { state in
            state.readingPostings[kind, default: 0] += 1
            return (state.postings[kind], state.stalePostings[kind] ?? [])
        }
        defer { state.withLock { $0.readingPostings[kind, default: 0] -= 1 } }
        func read(_ ids: [Int64]?) async throws -> [PhotoKeyword] {
            switch kind {
            case .keywords: try await source.photoKeywords(of: ids)
            case .collections: try await source.photoCollections(of: ids)
            }
        }
        var postings = kept ?? KeywordPostings()
        if kept == nil {
            postings = try await KeywordPostings(read(nil))
        } else if !stale.isEmpty {
            try await postings.replace(photos: stale, with: read(Array(stale)))
        } else {
            return postings
        }
        state.withLock { state in
            state.postings[kind] = postings
            state.stalePostings[kind]?.subtract(stale)
        }
        return postings
    }
}
