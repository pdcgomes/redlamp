import CoreGraphics
import Darwin
import Foundation
import OSLog
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
    /// Renames, moves and the Trash (LIB-26): the batches a forced quit cut short are settled at launch.
    let files: FileOperations
    /// Other apps' metadata (LIB-24).
    let xmp: LibraryXMP
    /// The locator when it opened.
    let locator: SidecarLocator
    private let state = Mutex(State())

    private struct State {
        /// Redlamp's own writes to rows, one at a time in the order they're asked for.
        var lastWrite: Task<Void, Never>?
        /// The library's changes, one at a time in the order they're asked for: its batches, and the XMP
        /// syncs between them.
        var lastChange: Task<Void, Never>?
        /// Settling at launch what a forced quit cut short, which change tracking waits for.
        var recovery: Task<Void, Never>?
        var lastSnapshot: ContinuousClock.Instant?
        var snapshotting = false
        var xmp = XMPQueue()
    }

    /// The photos whose XMP waits to be synced, in the order they were asked for.
    private struct XMPQueue {
        /// The library's choices, as it opened and as Settings changes them.
        var settings = XMPSettings()
        var waiting: [Int64] = []
        var queued = Set<Int64>()
        var syncing = false
        var idle: [CheckedContinuation<Void, Never>] = []
    }

    /// Snapshots of the index are taken at most this often while it changes.
    static let snapshotInterval = Duration.seconds(30 * 60)
    /// The file descriptors the process asks for: the store keeps up to 256 shards open, and the
    /// index, the decoder and the folders' packs need theirs.
    static let fileLimit: rlim_t = 4096
    /// Photos an XMP sync takes at a time, so the library's batches asked for meanwhile go between them.
    static let xmpBatch = 500
    /// The version of the index's schema this build opens: `LibraryIndex`'s count of migrations, which it
    /// doesn't make public.
    static let indexVersion = 7

    private static let log = Logger(subsystem: "app.redlamp.mac", category: "library")

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
        files = FileOperations(index: index, paths: paths, live: live)
        xmp = LibraryXMP(index: index, paths: paths)
    }

    /// Opens the index (restoring its newest good snapshot when it's damaged, checking it first when
    /// `check`), loads the column store and opens the thumbnail store. `thumbnail` is the engine's
    /// `decodeThumbnail(for:maxPixelSize:)`, which the store's thumbnails of raws come from; `migrating`
    /// hears, before the index opens, that opening it brings its schema up to date first.
    static func open(
        paths: LibraryPaths, check: Bool, thumbnail: @escaping @Sendable (URL, Int) -> CGImage?,
        migrating: @Sendable () async -> Void = {},
    ) async throws -> (core: LibraryCore, outcome: LibraryIndex.OpenOutcome) {
        raiseFileLimit()
        if needsMigrating(paths.index) {
            await migrating()
        }
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
        core.xmpSettings = await (try? core.xmp.settings()) ?? XMPSettings()
        return (core, outcome)
    }

    /// Whether the index at `url` was made by an earlier Redlamp, so opening it migrates its schema: version
    /// 7 builds the text index again, 5.7 to 9.6 s at a million photos, with nothing searchable meanwhile.
    /// A new index, or one that can't be read, isn't.
    static func needsMigrating(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let database = try? SQLiteDatabase(path: url.path, flags: .readWrite),
              let version = try? database.userVersion
        else { return false }
        return version > 0 && version < indexVersion
    }

    /// Raises the soft limit on open files towards `fileLimit`, never past the hard limit.
    static func raiseFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < fileLimit else { return }
        limit.rlim_cur = min(fileLimit, limit.rlim_max)
        setrlimit(RLIMIT_NOFILE, &limit)
    }

    // MARK: - Redlamp's own writes

    /// Brings `photo`'s row in step with its sidecar as `store` reads it now, and tells the open lists:
    /// FSEvents doesn't report Redlamp's own writes on this Mac. A photo the index doesn't hold is left
    /// to the indexer. A change to its rating, flag, label or mark reaches its `.xmp` when they're written.
    func sidecarSaved(_ photo: URL, store: SidecarStore) {
        serially { [self, index, live] in
            let summary = store.summary(for: photo)
            let sidecar = store.locator.readURL(for: photo)
            // A sidecar there that can't be read says nothing of the photo: its row stays as it is.
            guard summary != nil || !FileManager.default.fileExists(atPath: sidecar.path) else { return }
            let modified = summary == nil ? nil : (try? URL(fileURLWithPath: sidecar.path)
                .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let saved = try? await index.write { writer -> (id: Int64, culled: Bool)? in
                guard var row = try LibraryService.photo(at: photo, in: writer) else { return nil }
                let before = row
                row.rating = summary?.metadata.rating ?? 0
                row.flag = summary?.metadata.flag
                row.label = summary?.metadata.label
                row.customLabel = row.label == nil ? summary?.metadata.customLabel : nil
                row.marked = summary?.metadata.mark ?? false
                row.edited = summary?.hasEdits ?? false
                row.sidecarModified = summary == nil ? nil : modified ?? Date()
                try writer.upsertPhotos([row])
                let culled = row.rating != before.rating || row.flag != before.flag || row.label != before.label
                    || row.customLabel != before.customLabel || row.marked != before.marked
                return (row.id, culled)
            }
            if let saved = saved ?? nil {
                live.photosChanged([saved.id])
                if saved.culled {
                    changed([saved.id])
                }
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

    // MARK: - The library's changes

    /// Runs `body` once the changes asked for before it are made, and returns what it returns: the
    /// library's batches, and the XMP syncs between them, so a sync never reads a sidecar or a row a batch
    /// is writing. Recovery at launch goes first.
    func change<T: Sendable>(
        priority: TaskPriority = .userInitiated, _ body: @escaping @Sendable () async -> T,
    ) async -> T {
        await enqueue(priority: priority, body).value
    }

    /// `body` in the changes' turn, asked for now.
    @discardableResult
    private func enqueue<T: Sendable>(
        priority: TaskPriority, _ body: @escaping @Sendable () async -> T,
    ) -> Task<T, Never> {
        state.withLock { state in
            let previous = state.lastChange
            let task = Task.detached(priority: priority) {
                await previous?.value
                return await body()
            }
            state.lastChange = Task.detached(priority: priority) { _ = await task.value }
            return task
        }
    }

    /// Finishes or rolls back the file operations, then the metadata batches, a forced quit cut short, and
    /// sweeps the health rows and hashes of photos no batch can bring back: before any other change.
    func recover(_ metadata: LibraryMetadata) {
        let recovery = enqueue(priority: .userInitiated) { [files] in
            do {
                for outcome in try await files.recover() {
                    let done = outcome.state == .rolledBack ? "rolled back" : "finished"
                    Self.log.notice("A file operation a forced quit cut short was \(done, privacy: .public)")
                }
            } catch {
                Self.log.error("File operations couldn't recover: \(String(describing: error), privacy: .public)")
            }
            do {
                _ = try await metadata.recover()
            } catch {
                Self.log.error("Metadata batches couldn't recover: \(String(describing: error), privacy: .public)")
            }
        }
        state.withLock { $0.recovery = recovery }
    }

    /// Returns once what a forced quit cut short is settled: the indexer would otherwise list a folder
    /// whose renames are half done.
    func recovered() async {
        await state.withLock { $0.recovery }?.value
    }

    // MARK: - Other apps' metadata (LIB-24)

    /// The library's choices for other apps' metadata, as it opened and as Settings changes them: the
    /// index keeps them (`LibraryXMP.setSettings`).
    var xmpSettings: XMPSettings {
        get { state.withLock { $0.xmp.settings } }
        set { state.withLock { $0.xmp.settings = newValue } }
    }

    /// The library changed `ids` (a batch, its Undo or Redo, or a save of its own): their `.xmp` sidecars
    /// follow when they're written.
    func changed(_ ids: [Int64]) {
        guard xmpSettings.writes else { return }
        syncXMP(ids)
    }

    /// Syncs the XMP of `ids` through `LibraryXMP` once the changes asked for before them are made, a batch
    /// at a time in the background: other apps' changes are merged into each `.redlamp`, field by field,
    /// and the `.xmp` written when the setting is on. Photos asked for while they wait are synced once.
    func syncXMP(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let starts = state.withLock { state -> Bool in
            for id in ids where state.xmp.queued.insert(id).inserted {
                state.xmp.waiting.append(id)
            }
            guard !state.xmp.syncing else { return false }
            state.xmp.syncing = true
            return true
        }
        if starts {
            Task.detached(priority: .utility) { [self] in await syncWaitingXMP() }
        }
    }

    /// Change tracking read `ids` again: their files, their sidecars or other apps' `.xmp` changed. Those
    /// with a `.redlamp` take other apps' changes; the others have nothing to take them into, and the
    /// index shows other apps' fields for them as it reads them.
    func readAgain(_ ids: [Int64]) async {
        let synced = await (try? index.read { reader in
            try ids.filter { try reader.photo(id: $0)?.sidecarModified != nil }
        }) ?? []
        syncXMP(synced)
    }

    /// The photos waiting for an XMP sync, oldest first: those the app quits before syncing are kept for
    /// the next launch.
    var waitingXMP: [Int64] {
        state.withLock { $0.xmp.waiting }
    }

    /// Returns once every sync asked for before it is done.
    func xmpSynced() async {
        await withCheckedContinuation { continuation in
            let idle = state.withLock { state -> Bool in
                guard state.xmp.syncing else { return true }
                state.xmp.idle.append(continuation)
                return false
            }
            if idle {
                continuation.resume()
            }
        }
    }

    /// Syncs `ids` now, in the library's changes' turn; nil when the sync failed.
    @discardableResult
    func syncXMPNow(_ ids: [Int64]) async -> XMPReport? {
        let report = await change(priority: .utility) { [xmp] () -> Result<XMPReport, any Error> in
            do {
                return try await .success(xmp.sync(ids))
            } catch {
                return .failure(error)
            }
        }
        switch report {
        case let .success(report):
            live.photosChanged(LibraryXMP.changedPhotos(report))
            for photo in report.photos where photo.problem != nil {
                Self.log.error(
                    "\(photo.path, privacy: .private) wasn't synced with other apps: \(photo.problem ?? "", privacy: .public)",
                )
            }
            return report
        case let .failure(error):
            Self.log.error("Other apps' metadata wasn't synced: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func syncWaitingXMP() async {
        while let batch = nextXMPBatch() {
            await syncXMPNow(batch)
        }
    }

    private func nextXMPBatch() -> [Int64]? {
        let (batch, idle) = state.withLock { state -> ([Int64]?, [CheckedContinuation<Void, Never>]) in
            guard !state.xmp.waiting.isEmpty else {
                state.xmp.syncing = false
                defer { state.xmp.idle = [] }
                return (nil, state.xmp.idle)
            }
            let batch = Array(state.xmp.waiting.prefix(Self.xmpBatch))
            state.xmp.waiting.removeFirst(batch.count)
            state.xmp.queued.subtract(batch)
            return (batch, [])
        }
        for continuation in idle {
            continuation.resume()
        }
        return batch
    }

    /// Every photo in the index, by ID.
    func allPhotoIDs() async -> [Int64] {
        await (try? index.read { reader in
            try reader.database.prepare("SELECT id FROM photos ORDER BY folder, name").map { $0.int64(at: 0) }
        }) ?? []
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
