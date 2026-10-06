import Foundation
import Synchronization

/// Launches the library again with nothing changed, as the app does, twice. Each launch opens the
/// index, loads its column store and answers the first page of All Photographs and a search: the
/// library is visible and searchable within the design's launch budget, 1 s. Behind that the change
/// tracker reconciles the index with the disk through the simulated volume, its deepest folder on
/// screen, while searches are typed: the first launch, with no event history recorded, compares
/// every folder by signature and records the volume's history; the second replays that history,
/// listing only the folders it names. Nothing is read again, no row changes, and the searches typed
/// meanwhile keep the search budget.
///
/// The index is built for the run, or kept in `indexFolder` and built there only the first time;
/// each run launches a copy of it, so it starts with no history.
public struct IndexLaunchScenario: BenchScenario {
    public let name = "warm-launch"
    static let budget = 1000.0
    let indexFolder: URL?

    public init() {
        indexFolder = nil
    }

    /// Keeps the fixture's index in `indexFolder`, built there the first time.
    public init(indexFolder: URL?) {
        self.indexFolder = indexFolder
    }

    public func run(_ context: BenchContext) async throws -> [BenchResult] {
        let folder = try IndexingScenario.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Index.sqlite")
        try await prepare(url, for: context)
        let shown = Self.shownFolder(context)
        let first = try await Self.launch(url, context, showing: shown)
        let again = try await Self.launch(url, context, showing: shown)
        return results(first, again, context)
    }

    /// Puts at `url` the index the launches start from: a copy of the one kept in `indexFolder`,
    /// built there unless it holds the fixture's photos, or else one built for this run.
    private func prepare(_ url: URL, for context: BenchContext) async throws {
        guard let indexFolder else {
            return try await IndexingScenario.build([context.fixture], at: url)
        }
        let kept = indexFolder.appending(path: "Index.sqlite")
        if try await !Self.holds(context, kept) {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: kept.path + suffix))
            }
            try await IndexingScenario.build([context.fixture], at: kept)
        }
        try FileManager.default.copyItem(at: kept, to: url)
    }

    /// Whether the index at `url` is of the fixture alone, with every photo of its manifest.
    private static func holds(_ context: BenchContext, _ url: URL) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let index = try await LibraryIndex.open(at: url)
        let root = LibraryIndexer.path(context.fixture)
        let (roots, photos) = try await index.read { try ($0.roots().map(\.path), $0.photoCount()) }
        await index.close()
        return roots == [root] && photos == context.manifest.totals.photos
    }

    /// The fixture's deepest folder that holds photos, as the one on screen.
    static func shownFolder(_ context: BenchContext) -> URL? {
        let deepest = context.manifest.folders.filter { $0.photos > 0 }
            .max { ($0.path.split(separator: "/").count, $1.path) < ($1.path.split(separator: "/").count, $0.path) }
        return deepest.map { context.fixture.appending(path: $0.path, directoryHint: .isDirectory) }
    }

    // MARK: - Launching

    /// What a launch measured, each time from when it started.
    struct Launch {
        var opened = Duration.zero
        var loaded = Duration.zero
        /// All Photographs' first page and count.
        var shown = Duration.zero
        /// A search's first page and count, after All Photographs': visible and searchable.
        var searchable = Duration.zero
        /// What the search found.
        var found = 0
        /// The change tracker's first comparison of the volume over.
        var reconciled = Duration.zero
        /// The folder on screen listed.
        var shownCompared: Duration?
        /// Its history replayed, rather than its folders compared by signature.
        var replayed = false
        /// Why its folders were compared by signature.
        var reason: ChangeTracker.Reason?
        var summary = LibraryIndexerSummary()
        /// The searches typed while it reconciled: each one's first page and count.
        var searches: [Duration] = []
    }

    /// The query the launch searches for, typed whole: one of the manifest's.
    static let query = "rating>=3"

    static func launch(_ url: URL, _ context: BenchContext, showing shown: URL?) async throws -> Launch {
        let clock = ContinuousClock()
        var launch = Launch()
        let started = clock.now
        let index = try await LibraryIndex.open(at: url)
        launch.opened = clock.now - started
        let engine = QueryEngine(index: index)
        try await engine.load()
        launch.loaded = clock.now - started
        _ = try await first(engine.search(.all, sort: QuerySort(.captured, ascending: false)))
        launch.shown = clock.now - started
        launch.found = try await first(engine.search(LibraryQuery(parsing: query))).count ?? 0
        launch.searchable = clock.now - started

        let watch = ListingWatch(context.fileSystem(), watching: shown.map(LibraryIndexer.path))
        let tracker = ChangeTracker(indexer: LibraryIndexer(index: index, fileSystem: watch))
        tracker.show(shown.map { [$0] } ?? [])
        let typing = Task { await type(into: engine) }
        let reconciled = await reconcile(tracker.start([context.fixture]))
        launch.reconciled = clock.now - started
        if !reconciled.replayed, context.profile.isLocal != false {
            await recorded(in: index)
        }
        tracker.stop()
        typing.cancel()
        launch.searches = await typing.value
        launch.shownCompared = watch.listed.map { $0 - started }
        launch.replayed = reconciled.replayed
        launch.reason = reconciled.reason
        launch.summary = reconciled.summary
        await index.close()
        return launch
    }

    /// The first result `search` gives: its first page and the count.
    private static func first(_ search: AsyncThrowingStream<QueryResult, any Error>) async throws -> QueryResult {
        for try await result in search {
            return result
        }
        throw CancellationError()
    }

    /// Follows the tracker until its first comparison of the volume is over: a replayed history that
    /// named nothing, or the indexer's run, whose summary it returns.
    private static func reconcile(
        _ events: AsyncStream<ChangeTracker.Event>,
    ) async -> (replayed: Bool, reason: ChangeTracker.Reason?, summary: LibraryIndexerSummary) {
        var replayed = false
        var reason: ChangeTracker.Reason?
        for await event in events {
            switch event {
            case let .replayed(_, folders):
                replayed = true
                if folders == 0 {
                    return (true, nil, LibraryIndexerSummary())
                }
            case let .reconciled(_, why):
                reason = why
            case let .indexer(.finished(summary)):
                return (replayed, reason, summary)
            default:
                break
            }
        }
        return (replayed, reason, LibraryIndexerSummary())
    }

    /// Returns once the tracker has recorded a local volume's event history in the index, as it does
    /// after its run, or after 5 s for a volume that keeps none.
    private static func recorded(in index: LibraryIndex) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let volumes = await (try? index.read { try $0.volumes() }) ?? []
            if volumes.contains(where: { $0.eventDatabase != nil }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Types the manifest's queries a character at a time, a keystroke every 50 ms, until cancelled:
    /// how soon each keystroke's first page and count came.
    private static func type(into engine: QueryEngine) async -> [Duration] {
        let clock = ContinuousClock()
        var times: [Duration] = []
        while !Task.isCancelled {
            for query in FixtureQuery.corpus {
                let characters = Array(query.text)
                for length in 1 ... characters.count {
                    guard !Task.isCancelled,
                          let parsed = try? LibraryQuery(parsing: String(characters[..<length]), asYouType: true)
                    else { continue }
                    let started = clock.now
                    if await (try? first(engine.search(parsed))) != nil {
                        times.append(clock.now - started)
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        return times
    }

    // MARK: - Results

    private func results(_ first: Launch, _ again: Launch, _ context: BenchContext) -> [BenchResult] {
        let folders = Double(context.manifest.totals.folders + 1)
        let searches = first.searches + again.searches
        var results = [
            BenchResult(
                scenario: name, id: "library-launch", name: "Visible and searchable, nothing changed",
                value: first.searchable.seconds * 1000, unit: "ms", budget: .below(Self.budget, "ms"),
            ),
            BenchResult(
                scenario: name, id: "library-launch-open", name: "Index opened", value: first.opened.seconds * 1000,
                unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-launch-store", name: "Column store loaded",
                value: first.loaded.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-launch-shown", name: "All Photographs' first page and count",
                value: first.shown.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-launch-found", name: "Photos for \(Self.query)",
                value: Double(first.found), unit: "photos",
                budget: .exactly(Double(context.manifest.count(of: Self.query) ?? -1), "photos"),
            ),
            BenchResult(
                scenario: name, id: "library-launch-reconciled",
                name: "Reconciled behind it, every folder compared by signature",
                value: first.reconciled.seconds, unit: "s",
            ),
        ]
        if let compared = first.shownCompared {
            results.append(BenchResult(
                scenario: name, id: "library-launch-onscreen", name: "The folder on screen compared",
                value: compared.seconds * 1000, unit: "ms",
            ))
        }
        results += [
            BenchResult(
                scenario: name, id: "library-launch-listed", name: "Folders listed",
                value: Double(first.summary.foldersListed), unit: "folders", budget: .exactly(folders, "folders"),
            ),
            BenchResult(
                scenario: name, id: "library-launch-read", name: "Photos read again",
                value: Double(first.summary.headsRead + again.summary.headsRead), unit: "photos",
                budget: .exactly(0, "photos"),
            ),
            BenchResult(
                scenario: name, id: "library-launch-changed", name: "Photos whose rows changed",
                value: Double(Self.changed(first.summary) + Self.changed(again.summary)), unit: "photos",
                budget: .exactly(0, "photos"),
            ),
            BenchResult(
                scenario: name, id: "library-launch-typed",
                name: "First page and count while reconciling, p95 of \(searches.count) keystrokes",
                value: QueryScenario.percentile(searches, 0.95), unit: "ms",
                budget: .below(SearchScenario.budget, "ms"),
            ),
            BenchResult(
                scenario: name, id: "library-launch-again", name: "Launched again: visible and searchable",
                value: again.searchable.seconds * 1000, unit: "ms", budget: .below(Self.budget, "ms"),
            ),
        ]
        if again.replayed {
            results += [
                BenchResult(
                    scenario: name, id: "library-launch-replayed",
                    name: "Reconciled behind it, the volume's history replayed",
                    value: again.reconciled.seconds * 1000, unit: "ms",
                ),
                BenchResult(
                    scenario: name, id: "library-launch-replayed-listed", name: "Folders listed replaying it",
                    value: Double(again.summary.foldersListed), unit: "folders", budget: .exactly(0, "folders"),
                ),
            ]
        } else {
            results.append(BenchResult(
                scenario: name, id: "library-launch-replayed",
                name: "Reconciled behind it again, every folder compared by signature: \(Self.why(again.reason))",
                value: again.reconciled.seconds * 1000, unit: "ms",
            ))
        }
        return results
    }

    /// Why a launch compared every folder by signature instead of replaying the volume's history.
    private static func why(_ reason: ChangeTracker.Reason?) -> String {
        switch reason {
        case .historyGone?: "no history recorded"
        case .mustScan?: "the volume's history dropped events since"
        case .network?: "a network volume, which has none"
        case .reconnected?: "the volume came back"
        case nil: "no history to replay"
        }
    }

    private static func changed(_ summary: LibraryIndexerSummary) -> Int {
        summary.photosInserted + summary.photosUpdated + summary.photosMoved + summary.photosRemoved
    }
}

/// Another file system that notes when a folder is first listed.
final class ListingWatch: LibraryFileSystem {
    let base: any LibraryFileSystem
    private let watched: String?
    private let firstListed = Mutex<ContinuousClock.Instant?>(nil)

    init(_ base: any LibraryFileSystem, watching path: String?) {
        self.base = base
        watched = path
    }

    /// When the folder watched was first listed.
    var listed: ContinuousClock.Instant? {
        firstListed.withLock { $0 }
    }

    func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        let entries = try base.contentsOfDirectory(at: url)
        if let watched, LibraryIndexer.path(url) == watched {
            firstListed.withLock { $0 = $0 ?? .now }
        }
        return entries
    }

    func attributes(of url: URL) throws -> FileEntry {
        try base.attributes(of: url)
    }

    func read(_ url: URL, range: Range<Int>) throws -> Data {
        try base.read(url, range: range)
    }

    func volume(of url: URL) throws -> VolumeInfo {
        try base.volume(of: url)
    }
}
