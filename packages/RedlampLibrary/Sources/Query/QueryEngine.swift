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

/// Searches the library (LIB-06). Queries run over the column store, loaded by `load`: mapped from its
/// snapshot beside the index when that reflects the index, or built from the index in the background
/// (LIB-44). Text, keyword and collection terms are looked up in the index, folder, camera and lens
/// terms in its small tables, then one pass over the columns finds the photos and one in the sort's
/// order lists them. Until the store is ready, a query is compiled to SQL and the index answers it.
///
/// A search cancels the one before it, and its facets; nothing runs on the caller's thread. What the
/// index looked up for a term, and what a query found, is kept until the store changes, so typing a
/// character at a time looks up only what changed.
///
/// The store's snapshot is saved again once the store and the index have been quiet for a while
/// after they change (`Saving`), and when `saveSnapshot` is called, as the app does at quit; each is
/// brought up to the index's generation first, through what this process's writes changed.
public final class QueryEngine: Sendable {
    let source: any QuerySource
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date
    private let saving: Saving?
    private let state = Mutex(State())

    /// When the store's snapshot is saved after a change: once the store and the index have been
    /// quiet for `quiet`, or `longest` after the first change not saved, whichever comes first.
    struct Saving: Sendable {
        var quiet: Duration
        var longest: Duration

        static let standard = Saving(quiet: .seconds(10), longest: .seconds(300))
    }

    private struct State {
        var store: ColumnStore?
        var vocabulary = QueryVocabulary()
        /// Changes with the store, so what was kept for another store isn't used.
        var generation = 0
        /// The index generation the store and its names reflect, when that's known.
        var reflects: IndexGeneration?
        /// The generation of the snapshot beside the index this store was loaded from or saved as,
        /// and whether the store has changed since.
        var saved: IndexGeneration?
        var changedSinceSaved = false
        /// Whether the store was mapped from its snapshot, when it was loaded or last saved.
        var mapped = false
        /// When the store or the index first changed since the snapshot was saved, and last.
        var unsavedSince: ContinuousClock.Instant?
        var lastChange: ContinuousClock.Instant?
        var saveTimer: Task<Void, Never>?
        var observer: (journal: IndexJournal, id: UUID)?
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
        /// What Library Health's checks found in this store, and the photos kept anyway (LIB-40).
        var health: [HealthCheck: HealthFindings] = [:]
        var keptAnyway: [Int64]?
        /// The photos that can be in a pair, kept with the store once the pairs check is asked for.
        var pairs: HealthPairs?
    }

    /// What a change to the store does to the photos kept for the pairs check: keeps them, drops
    /// them, or updates those of the photos the change read again.
    private enum PairsChange {
        case keep
        case drop
        case update
    }

    /// What a change makes.
    private struct Changed: Sendable {
        enum Kind {
            /// Loaded, mapped from the snapshot or built from the index.
            case mapped, built
            case changed
        }

        var store: ColumnStore
        var names: QueryNames
        /// The photos it read again.
        var photos: [Int64] = []
        /// The index generation the store and names reflect, when that's known.
        var generation: IndexGeneration?
        var kind = Kind.changed
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
        self.init(index: index, timeZone: timeZone, now: now, saving: .standard)
    }

    /// `saving` says when the store's snapshot is saved after changes; nil only when asked.
    convenience init(
        index: LibraryIndex, timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = Date.init,
        saving: Saving?,
    ) {
        self.init(source: IndexQuerySource(index: index), timeZone: timeZone, now: now, saving: saving)
        let id = index.journal.observe { [weak self] in
            self?.indexChanged()
        }
        state.withLock { $0.observer = (index.journal, id) }
    }

    init(
        source: any QuerySource, timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = Date.init,
        saving: Saving? = .standard,
    ) {
        self.source = source
        self.timeZone = timeZone
        self.now = now
        self.saving = saving
    }

    deinit {
        let (observer, timer) = state.withLock { ($0.observer, $0.saveTimer) }
        if let observer {
            observer.journal.removeObserver(observer.id)
        }
        timer?.cancel()
    }

    /// Whether the column store is built: until it is, searches go to SQLite.
    public var isLoaded: Bool {
        state.withLock { $0.store != nil }
    }

    /// The column store as it is now, once it's built.
    public var store: ColumnStore? {
        state.withLock { $0.store }
    }

    /// Whether the store was mapped from its snapshot when it was loaded or last saved, rather than
    /// built from the index and held in memory.
    var isMapped: Bool {
        state.withLock { $0.mapped }
    }

    /// The index generation the store reflects, when that's known.
    var reflects: IndexGeneration? {
        state.withLock { $0.reflects }
    }

    /// Loads the column store and the small tables beside it: mapped from the store's snapshot when
    /// it reflects the index as it is now, built from the index otherwise.
    public func load() async throws {
        state.withLock { $0.postings = [:] }
        try await change(pairs: .drop) { [source] _, _, _ in
            let loaded = try await source.loadStore()
            return Changed(
                store: loaded.store, names: loaded.names, generation: loaded.generation,
                kind: loaded.mapped ? .mapped : .built,
            )
        }
    }

    /// Brings the column store up to date with photos `ids` as the index has them now: added,
    /// changed or removed. Call it once their writes are committed; until the store is loaded there's
    /// nothing to do, since loading reads them. Anything else this process's writes changed since the
    /// store was last brought up to the index is read again with them.
    public func update(photos ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        state.withLock { state in
            for kind in [PostingKind.keywords, .collections]
                where state.postings[kind] != nil || state.readingPostings[kind, default: 0] > 0 {
                state.stalePostings[kind, default: []].formUnion(ids)
            }
        }
        try await change(pairs: .update) { [source] store, names, generation in
            guard let store else { return nil }
            let caught = try await source.catchingUp(
                ids, in: store, names: names, since: generation, readingNames: false,
            )
            return Changed(
                store: caught.store,
                names: caught.names,
                photos: caught.photos,
                generation: caught.generation,
            )
        }
    }

    /// Reads the small tables again: after folders are renamed or moved, or keywords or collections
    /// change without their photos.
    public func updateNames() async throws {
        try await change(pairs: .update) { [source] store, names, generation in
            guard let store else { return nil }
            let caught = try await source.catchingUp([], in: store, names: names, since: generation, readingNames: true)
            return Changed(
                store: caught.store,
                names: caught.names,
                photos: caught.photos,
                generation: caught.generation,
            )
        }
    }

    /// Saves the store's snapshot beside the index (LIB-44), brought up to the index's generation
    /// first: what the app does at quit. Nothing is written when the snapshot there already reflects
    /// the index, and only its header when the store hasn't changed since it was saved; afterwards
    /// the store is mapped from what was written. Nothing is saved when the store reflects no
    /// generation it can say: another process wrote to the index since it was loaded.
    public func saveSnapshot() async throws {
        state.withLock { state in
            state.unsavedSince = nil
            state.lastChange = nil
        }
        try await serially { [self, source] in
            guard let (store, names, reflects) = state.withLock({ state in
                state.store.map { ($0, state.vocabulary.names, state.reflects) }
            }), let reflects
            else { return }
            let caught = try await source.catchingUp([], in: store, names: names, since: reflects, readingNames: false)
            guard let generation = caught.generation else {
                state.withLock { $0.reflects = nil }
                return
            }
            if caught.photos.isEmpty, caught.names.hasSameTables(as: names) {
                state.withLock { $0.reflects = generation }
            } else {
                try await install(
                    Changed(store: caught.store, names: caught.names, photos: caught.photos, generation: generation),
                    replacing: names, pairs: .update,
                )
            }
            let (current, saved, unchanged, version) = state.withLock { state in
                (state.store, state.saved, !state.changedSinceSaved, state.generation)
            }
            guard let current, generation != saved else { return }
            let mapped = try await source.save(
                current, names: caught.names, generation: generation, unchangedSince: unchanged ? saved : nil,
            )
            state.withLock { state in
                state.saved = generation
                state.changedSinceSaved = false
                if let mapped, state.generation == version {
                    state.store = mapped
                    state.mapped = true
                }
            }
        }
    }

    /// `saveSnapshot`, blocking: for the app's quit, from the main thread or a thread of its own,
    /// never from a task.
    public func saveSnapshotAndWait() {
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) { [self] in
            try? await saveSnapshot()
            done.signal()
        }
        done.wait()
    }

    /// After a write to the index commits: its snapshot no longer reflects it.
    private func indexChanged() {
        guard state.withLock({ $0.store != nil && $0.reflects != nil }) else { return }
        scheduleSave()
    }

    /// Saves the snapshot once the store and the index have been quiet for a while (`Saving`).
    private func scheduleSave() {
        guard let saving else { return }
        state.withLock { state in
            let now = ContinuousClock.now
            state.lastChange = now
            if state.unsavedSince == nil {
                state.unsavedSince = now
            }
            guard state.saveTimer == nil else { return }
            state.saveTimer = Task.detached(priority: .utility) { [weak self] in
                while let wait = self?.untilSaving(saving) {
                    if wait > .zero {
                        try? await Task.sleep(for: wait)
                    } else {
                        try? await self?.saveSnapshot()
                    }
                }
            }
        }
    }

    /// How long until the snapshot is due, zero when it is; nil, ending the timer, when there's
    /// nothing to save.
    private func untilSaving(_ saving: Saving) -> Duration? {
        state.withLock { state in
            guard let since = state.unsavedSince, let last = state.lastChange else {
                state.saveTimer = nil
                return nil
            }
            let now = ContinuousClock.now
            let due = min(last + saving.quiet, since + saving.longest)
            return due <= now ? .zero : due - now
        }
    }

    /// Drops what the engine keeps to answer the same questions again quickly, keeping the store:
    /// compiled queries, the rows terms found, results, the filter bar's columns, keywords' and
    /// collections' photos, Library Health's findings and pairs, and the small tables' matches. For a
    /// memory-pressure trim: each comes back the next time it's asked for.
    public func trim() {
        let (names, generation) = state.withLock { ($0.vocabulary.names, $0.generation) }
        let vocabulary = QueryVocabulary(names)
        state.withLock { state in
            state.plans.removeAll()
            state.rowSets.removeAll()
            state.matches.removeAll()
            state.columnCounts.removeAll()
            state.health.removeAll()
            state.keptAnyway = nil
            state.postings.removeAll()
            state.pairs = nil
            if state.generation == generation {
                state.vocabulary = vocabulary
            }
        }
    }

    /// Keeps `key`'s order in the store from now on, sorting it once, unless it's kept already.
    func prepareOrder(_ key: QuerySort.Key) async throws {
        guard state.withLock({ $0.store.map { !$0.keepsOrder(key) } ?? false }) else { return }
        try await change { store, names, generation in
            guard var store, !store.keepsOrder(key) else { return nil }
            store.prepareOrder(key)
            return Changed(store: store, names: names, generation: generation)
        }
    }

    /// Runs `body` with the store, its names and the generation they reflect, after the changes asked
    /// for before, and installs what it returns.
    private func change(
        pairs change: PairsChange = .keep,
        _ body: @escaping @Sendable (ColumnStore?, QueryNames, IndexGeneration?) async throws -> Changed?,
    ) async throws {
        try await serially { [self] in
            let (store, names, generation) = state.withLock { ($0.store, $0.vocabulary.names, $0.reflects) }
            guard let changed = try await body(store, names, generation) else { return }
            try await install(changed, replacing: names, pairs: change)
        }
    }

    /// Replaces the store and the names with `changed`'s, and the photos kept for the pairs check as
    /// `pairs` says, in the serial lane; `names` were the names before. Saves the snapshot later when
    /// the store now reflects a generation it wasn't saved as.
    private func install(_ changed: Changed, replacing names: QueryNames, pairs change: PairsChange) async throws {
        let vocabulary = QueryVocabulary(changed.names)
        var pairs = state.withLock { $0.pairs.take() }
        switch change {
        case .keep:
            break
        case .drop:
            pairs = nil
        case .update:
            if var kept = pairs.take() {
                if !changed.photos.isEmpty {
                    do {
                        try await kept.update(changed.photos, to: source.pairPhotos(of: changed.photos))
                    } catch {
                        state.withLock { $0.pairs = kept }
                        throw error
                    }
                }
                pairs = kept
            }
        }
        let due = state.withLock { [pairs] state -> Bool in
            state.pairs = pairs
            state.store = changed.store
            state.vocabulary = vocabulary
            state.generation += 1
            state.plans.removeAll()
            state.rowSets.removeAll()
            state.matches.removeAll()
            state.columnCounts.removeAll()
            state.health.removeAll()
            state.keptAnyway = nil
            for kind in [PostingKind.keywords, .collections]
                where !changed.photos.isEmpty
                && (state.postings[kind] != nil || state.readingPostings[kind, default: 0] > 0) {
                state.stalePostings[kind, default: []].formUnion(changed.photos)
            }
            state.reflects = changed.generation
            switch changed.kind {
            case .mapped:
                state.saved = changed.generation
                state.changedSinceSaved = false
                state.mapped = true
            case .built:
                state.saved = nil
                state.changedSinceSaved = true
                state.mapped = false
            case .changed:
                if !changed.photos.isEmpty || !changed.names.hasSameTables(as: names) {
                    state.changedSinceSaved = true
                }
            }
            return changed.generation != nil && changed.generation != state.saved
        }
        if due {
            scheduleSave()
        }
    }

    /// Runs `body` after the changes asked for before, and before those asked for after: the store
    /// and the photos kept for the pairs check change only there.
    private func serially<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = state.withLock { state in
            let previous = state.changing
            let task = Task {
                _ = await previous?.result
                return try await body()
            }
            state.changing = Task { _ = try await task.value }
            return task
        }
        return try await task.value
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
        if case let .pairs(rule) = check, rule != .keepBoth {
            return try await pairFindings(rule, generation: generation)
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

    /// What the pairs check finds under `rule` in the store as it is once the changes asked for are
    /// made, judging only the pairs whose photos changed since it was last asked; kept for
    /// `generation` if that's still the store's.
    private func pairFindings(_ rule: PairRule, generation: Int) async throws -> HealthFindings {
        try await serially { [self, source] in
            guard let store = state.withLock({ $0.store }) else { return HealthFindings(check: .pairs(rule)) }
            var pairs: HealthPairs = if let kept = state.withLock({ $0.pairs.take() }) {
                kept
            } else {
                try await HealthPairs(source.pairPhotos(of: nil))
            }
            let found: HealthFindings
            do {
                found = try await source.pairFindings(rule, store: store, pairs: &pairs)
            } catch {
                state.withLock { $0.pairs = pairs }
                throw error
            }
            state.withLock { [pairs] state in
                state.pairs = pairs
                if state.generation == generation {
                    state.health[.pairs(rule)] = found
                }
            }
            return found
        }
    }

    func keptAnyway(generation: Int) async throws -> [Int64] {
        if let kept = state.withLock({ $0.generation == generation ? $0.keptAnyway : nil }) {
            return kept
        }
        let found = try await source.keptAnyway()
        state.withLock { state in
            if state.generation == generation {
                state.keptAnyway = found
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
