import CoreGraphics
import Darwin
import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

/// The library once its index is open: everything here is safe from any thread, and nothing here
/// runs on the main thread.
final class LibraryCore: Sendable {
    let paths: LibraryPaths
    let index: LibraryIndex
    let engine: QueryEngine
    let store: PhotoStore
    let thumbnails: StoreThumbnails
    let indexer: LibraryIndexer
    let tracker: ChangeTracker
    let live: LibraryLive
    let sidecars: LibrarySidecars
    /// The locator when it opened.
    let locator: SidecarLocator
    private let state = Mutex(State())

    private struct State {
        /// Redlamp's own writes to rows, one at a time in the order they're asked for.
        var lastWrite: Task<Void, Never>?
        var lastSnapshot: ContinuousClock.Instant?
        var snapshotting = false
    }

    /// Snapshots of the index are taken at most this often while it changes.
    static let snapshotInterval = Duration.seconds(30 * 60)
    /// The file descriptors the process asks for: the store keeps up to 256 shards open, and the
    /// index, the decoder and the folders' packs need theirs.
    static let fileLimit: rlim_t = 4096

    private init(
        paths: LibraryPaths, index: LibraryIndex, engine: QueryEngine, store: PhotoStore,
        thumbnails: StoreThumbnails, locator: SidecarLocator,
    ) {
        self.paths = paths
        self.index = index
        self.engine = engine
        self.store = store
        self.thumbnails = thumbnails
        self.locator = locator
        indexer = LibraryIndexer(index: index, thumbnails: thumbnails.maker.thumbnails)
        tracker = ChangeTracker(indexer: indexer)
        live = LibraryLive(engine: engine)
        sidecars = LibrarySidecars(index: index, paths: paths)
    }

    /// Opens the index (restoring its newest good snapshot when it's damaged, checking it first when
    /// `check`), loads the column store and opens the thumbnail store. `thumbnail` is the engine's
    /// `decodeThumbnail(for:maxPixelSize:)`, which the store's thumbnails of raws come from.
    static func open(
        paths: LibraryPaths, check: Bool, thumbnail: @escaping @Sendable (URL, Int) -> CGImage?,
    ) async throws -> (core: LibraryCore, outcome: LibraryIndex.OpenOutcome) {
        raiseFileLimit()
        let (index, outcome) = try await LibraryIndex.openOrRestore(
            at: paths.index, snapshots: paths.snapshots, check: check,
        )
        let engine = QueryEngine(index: index)
        try await engine.load()
        let store = PhotoStore(root: paths.store)
        let locator = await (try? LibrarySidecars(index: index, paths: paths).locator()) ?? .besidePhotos
        let core = LibraryCore(
            paths: paths, index: index, engine: engine, store: store,
            thumbnails: StoreThumbnails(store: store, thumbnail: thumbnail), locator: locator,
        )
        return (core, outcome)
    }

    /// Raises the soft limit on open files towards `fileLimit`, never past the hard limit.
    static func raiseFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < fileLimit else { return }
        limit.rlim_cur = min(fileLimit, limit.rlim_max)
        setrlimit(RLIMIT_NOFILE, &limit)
    }

    // MARK: - Redlamp's own writes

    /// Brings photo `path`'s row in step with its sidecar as `store` reads it now, and tells the open
    /// lists: FSEvents doesn't report Redlamp's own writes on this Mac. A photo the index doesn't
    /// hold is left to the indexer.
    func sidecarSaved(at path: String, photo: URL, store: SidecarStore) {
        serially { [index, live] in
            let summary = store.summary(for: photo)
            let sidecar = store.locator.readURL(for: photo)
            // A sidecar there that can't be read says nothing of the photo: its row stays as it is.
            guard summary != nil || !FileManager.default.fileExists(atPath: sidecar.path) else { return }
            let modified = summary == nil ? nil : (try? URL(fileURLWithPath: sidecar.path)
                .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let id = try? await index.write { writer -> Int64? in
                guard var row = try writer.photo(path: path) else { return nil }
                row.rating = summary?.metadata.rating ?? 0
                row.flag = summary?.metadata.flag
                row.label = summary?.metadata.label
                row.customLabel = row.label == nil ? summary?.metadata.customLabel : nil
                row.marked = summary?.metadata.mark ?? false
                row.edited = summary?.hasEdits ?? false
                row.sidecarModified = summary == nil ? nil : modified ?? Date()
                try writer.upsertPhotos([row])
                return row.id
            }
            if let id = id ?? nil {
                live.photosChanged([id])
            }
        }
    }

    /// Runs `body` after the steps asked for before it.
    private func serially(_ body: @escaping @Sendable () async -> Void) {
        state.withLock { state in
            let previous = state.lastWrite
            state.lastWrite = Task.detached(priority: .utility) {
                await previous?.value
                await body()
            }
        }
    }

    // MARK: - Snapshots and checks

    /// Takes a snapshot of the index in the background unless one was taken in the last
    /// `snapshotInterval`: called after the index changes.
    func snapshotIfDue() {
        let due = state.withLock { state -> Bool in
            guard !state.snapshotting,
                  state.lastSnapshot.map({ .now - $0 >= Self.snapshotInterval }) ?? true else { return false }
            state.snapshotting = true
            return true
        }
        guard due else { return }
        Task.detached(priority: .background) { [self] in
            _ = try? await index.snapshot(to: paths.snapshots)
            state.withLock { state in
                state.snapshotting = false
                state.lastSnapshot = .now
            }
        }
    }

    /// `PRAGMA quick_check`, at most once a week: false when the index is damaged, which the next
    /// launch repairs from a snapshot. Nil when it isn't due or can't run.
    func weeklyCheck(now: Date = Date()) async -> Bool? {
        let key = "app.quickCheck"
        let last = try? await index.read { try $0.setting(key) }.flatMap { Double($0) }
        if let last, now.timeIntervalSince1970 - last < 7 * 24 * 3600 {
            return nil
        }
        guard let sound = try? await index.quickCheck() else { return nil }
        if sound {
            _ = try? await index.write { try $0.setSetting(String(now.timeIntervalSince1970), for: key) }
        }
        return sound
    }
}
