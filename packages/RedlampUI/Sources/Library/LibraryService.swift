import AppKit
import CoreGraphics
import Foundation
import Observation
import OSLog
import RedlampDocument
import RedlampLibrary
import Synchronization

/// The library in the app (LIB-10, LIB-11, LIB-09): its index, search, thumbnail store, indexer and
/// change tracking, over the folders in Folders.
///
/// It opens at launch off the main thread: the index (from its newest good snapshot when it's
/// damaged, migrating its schema first when an earlier Redlamp made it), the column store and the
/// thumbnail store. Then, before any other change, it finishes or rolls back the file operations and
/// metadata batches a forced quit cut short, and it finishes a sidecar move a quit interrupted. It
/// indexes the folders in Folders and keeps them current, and `FolderLibrary` shows a folder it has
/// indexed from a photo list. Until it's open, and for a folder it hasn't indexed, `FolderLibrary`
/// lists folders itself, as it does with the library off
/// (`defaults write app.redlamp.mac LibraryEnabled -bool NO`) or when the index can't open.
///
/// A folder is shown from the library once it's indexed as its last listing found it and that
/// listing is current: made in this session, or in a root change tracking has caught up with since
/// launch (`ChangeTracker.Event.caughtUp`) and not lost since.
///
/// Other apps' metadata (LIB-24): with the library's setting on, each batch it runs (and its Undo and
/// Redo) and each save of a photo's rating, flag, label or mark writes the photos' `.xmp` sidecars
/// through `LibraryXMP` afterwards, in the background; and the photos change tracking finds changed,
/// other apps' `.xmp` among them, have those changes merged into their `.redlamp`, setting or not.
@MainActor
@Observable
public final class LibraryService {
    public enum State: Equatable, Sendable {
        case opening
        case ready
        /// The index couldn't open, for this reason: Folders works without the library.
        case unavailable(String)
    }

    /// The defaults key that turns the library off.
    public static let enabledKey = "LibraryEnabled"

    /// Whether the library is on: unless the defaults say otherwise.
    public static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }

    @ObservationIgnored public let paths: LibraryPaths
    public private(set) var state = State.opening
    /// While opening: the index's schema is being brought up to this version's, which builds its text
    /// index again, so nothing can be searched until it's open.
    public private(set) var isUpdatingIndex = false
    /// The library's choices for other apps' metadata, once it's open.
    public private(set) var xmpSettings: XMPSettings?
    /// Every photo's `.xmp` is being written, as Settings asked.
    public private(set) var isWritingAllXMP = false
    /// Meanwhile, how many photos are left, once they're counted.
    public private(set) var xmpRemaining: Int?
    /// The filter bar: each source's filter and sort, applied to the lists the library makes (LIB-18).
    @ObservationIgnored public let filters: LibraryFilters
    /// Where photos' sidecars are read and written: `FolderLibrary`'s, set as placements change.
    @ObservationIgnored let sidecars: SidecarPlacement
    /// The list made last, which the filter bar filters.
    @ObservationIgnored private weak var currentList: LibraryFolderList?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let thumbnail: @Sendable (URL, Int) -> CGImage?
    @ObservationIgnored private(set) var core: LibraryCore?
    /// Culling's batches (LIB-15), once the library is open. Lists hear of them from culling, which knows
    /// whether a change asked for since will change the same photos again (`CullingQueue`).
    @ObservationIgnored private(set) var metadata: LibraryMetadata?
    /// The roots followed, as the index keeps their paths.
    @ObservationIgnored private(set) var roots: [String] = []
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var writingAllXMP: Task<Void, Never>?
    @ObservationIgnored private var memoryPressure: DispatchSourceMemoryPressure?
    /// Roots whose volumes change tracking has caught up with since launch, and that answer still.
    @ObservationIgnored private(set) var currentRoots: Set<String> = []
    /// Folders indexed in this session, as they were listed then.
    @ObservationIgnored private var indexedFolders: Set<String> = []
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var notifying = false
    @ObservationIgnored private var activity: [any NSObjectProtocol] = []

    private nonisolated static let log = Logger(subsystem: "app.redlamp.mac", category: "library")
    /// The defaults key set when the index was found damaged, so the next launch checks it as it opens.
    static let damagedKey = "library.indexDamaged"
    /// The defaults key keeping the photos whose XMP the app quit before syncing, for the next launch.
    static let xmpWaitingKey = "library.xmpWaiting"

    /// `sidecars` is the placement Folders and the editor read and write sidecars through; `thumbnail`
    /// the engine's `decodeThumbnail(for:maxPixelSize:)`. `defaults` keeps the sidecar locator between
    /// launches, so photos opened before the index is reach their sidecars.
    public init(
        paths: LibraryPaths = .standard, sidecars: SidecarPlacement, defaults: UserDefaults? = nil,
        thumbnail: @escaping @Sendable (URL, Int) -> CGImage?,
    ) {
        self.paths = paths
        self.sidecars = sidecars
        self.defaults = defaults
        self.thumbnail = thumbnail
        filters = LibraryFilters(defaults: defaults, presetsURL: paths.root.appending(path: "Filter Presets.json"))
        if let defaults, let saved = SidecarLocator.saved(in: defaults) {
            sidecars.locator = saved
        }
        filters.service = self
    }

    isolated deinit {
        opening?.cancel()
        following?.cancel()
        writingAllXMP?.cancel()
        for observer in activity {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public var isReady: Bool {
        state == .ready
    }

    /// The store's thumbnails, once the library is open.
    public var thumbnails: StoreThumbnails? {
        core?.thumbnails
    }

    /// The column store and search, once the library is open.
    public var engine: QueryEngine? {
        core?.engine
    }

    // MARK: - Launch and quit

    /// Opens the library off the main thread, then follows `roots`; returns at once.
    public func start(following roots: [URL]) {
        self.roots = Self.paths(roots)
        guard opening == nil, core == nil else { return }
        let (paths, thumbnail) = (paths, thumbnail)
        let check = defaults?.bool(forKey: Self.damagedKey) ?? false
        let migrating: @Sendable () async -> Void = { [weak self] in await self?.indexMigrating() }
        opening = Task { [weak self] in
            let opened = await Task.detached(priority: .userInitiated) { () -> Result<LibraryCore, any Error> in
                do {
                    let (core, outcome) = try await LibraryCore.open(
                        paths: paths, check: check, thumbnail: thumbnail, migrating: migrating,
                    )
                    if outcome != .opened {
                        Self.log
                            .notice("The library's index was damaged: \(String(describing: outcome), privacy: .public)")
                    }
                    return .success(core)
                } catch {
                    return .failure(error)
                }
            }.value
            self?.opened(opened)
        }
    }

    /// Opening the index migrates its schema first.
    private func indexMigrating() {
        guard core == nil else { return }
        isUpdatingIndex = true
        Self.log.notice("The library's index is being updated for this version of Redlamp")
    }

    private func opened(_ result: Result<LibraryCore, any Error>) {
        opening = nil
        isUpdatingIndex = false
        switch result {
        case let .failure(error):
            state = .unavailable(String(describing: error))
            Self.log.error(
                "The library's index didn't open, so Folders lists folders itself: \(String(describing: error), privacy: .public)",
            )
        case let .success(core):
            self.core = core
            trimOnMemoryPressure(core.engine)
            let metadata = LibraryMetadata(index: core.index, paths: core.paths)
            self.metadata = metadata
            core.recover(metadata)
            defaults?.removeObject(forKey: Self.damagedKey)
            placed(core.locator)
            state = .ready
            followActivity(core)
            let roots = roots
            self.roots = []
            follow(roots.map { URL(fileURLWithPath: $0, isDirectory: true) })
            xmpSettings = core.xmpSettings
            core.syncXMP((defaults?.array(forKey: Self.xmpWaitingKey) as? [NSNumber])?.map(\.int64Value) ?? [])
            defaults?.removeObject(forKey: Self.xmpWaitingKey)
            Task.detached(priority: .utility) { [weak self] in
                _ = try? await core.sidecars.resumeMove()
                let locator = try? await core.sidecars.locator()
                await self?.placed(locator)
                try? await Task.sleep(for: .seconds(60))
                if await core.weeklyCheck() == false {
                    await self?.damaged()
                }
            }
            notify()
        }
    }

    /// Stops indexing, saves the query engine's snapshot so the next launch maps it, and writes the
    /// store's index files: when the app quits. The photos whose XMP wasn't synced yet are kept for
    /// the next launch.
    public func close() {
        opening?.cancel()
        following?.cancel()
        writingAllXMP?.cancel()
        memoryPressure?.cancel()
        memoryPressure = nil
        guard let core else { return }
        core.tracker.stop()
        core.engine.saveSnapshotAndWait()
        core.store.close()
        let waiting = core.waitingXMP
        if waiting.isEmpty {
            defaults?.removeObject(forKey: Self.xmpWaitingKey)
        } else {
            defaults?.set(waiting.map { NSNumber(value: $0) }, forKey: Self.xmpWaitingKey)
        }
    }

    /// Lets go of what the query engine keeps only to answer again quickly when the Mac runs short of
    /// memory; the store stays mapped from its snapshot.
    private func trimOnMemoryPressure(_ engine: QueryEngine) {
        memoryPressure?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { engine.trim() }
        source.resume()
        memoryPressure = source
    }

    /// Reads where each root keeps its sidecars again: after a placement changes.
    func placementsChanged() async {
        guard let core else { return }
        await placed(try? core.sidecars.locator())
    }

    private func placed(_ locator: SidecarLocator?) {
        guard let locator else { return }
        sidecars.locator = locator
        if let defaults {
            locator.save(in: defaults)
        }
    }

    private func damaged() {
        Self.log.error("The library's index failed its check: the next launch restores it")
        defaults?.set(true, forKey: Self.damagedKey)
    }

    /// Network volumes are polled only while the app is in the foreground.
    private func followActivity(_ core: LibraryCore) {
        let center = NotificationCenter.default
        let tracker = core.tracker
        activity = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                tracker.setActive(true)
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                tracker.setActive(false)
            },
        ]
    }

    // MARK: - Folders

    /// Follows `roots`, the folders in Folders: those the index doesn't hold are indexed, then change
    /// tracking keeps them all current. Folders in iCloud Drive aren't indexed: reading every photo's
    /// head would download it.
    public func follow(_ roots: [URL]) {
        let paths = Self.paths(roots)
        guard paths != self.roots else { return }
        self.roots = paths
        currentRoots.formIntersection(paths)
        guard let core else { return }
        following?.cancel()
        let report: @Sendable (Progress) async -> Void = { [weak self] progress in
            await self?.progressed(progress)
        }
        following = Task.detached(priority: .utility) {
            await Self.follow(paths, core: core, report: report)
        }
    }

    /// The folders on screen, indexed before the others.
    public func show(_ folders: [URL]) {
        core?.tracker.show(folders)
    }

    /// What following the roots found.
    enum Progress: Sendable, Equatable {
        /// Change tracking caught up with these roots' volume.
        case current([String])
        /// These roots' volume stopped answering.
        case offline([String])
        case indexed(String)
        /// Where the roots keep their sidecars, once new roots' placements are chosen.
        case placed(SidecarLocator)
    }

    private nonisolated static func follow(
        _ paths: [String], core: LibraryCore, report: @escaping @Sendable (Progress) async -> Void,
    ) async {
        await core.recovered()
        let roots = paths.filter { !isInICloudDrive($0) }
        let known = await Set((try? core.index.read { try $0.roots().map(\.path) }) ?? [])
        let added = roots.filter { !known.contains($0) }
        if !added.isEmpty {
            for await event in core.indexer.index(added.map { URL(fileURLWithPath: $0, isDirectory: true) }) {
                await received(.indexer(event), core: core, report: report)
            }
            if await (try? core.sidecars.choosePlacements())?.isEmpty == false,
               let locator = try? await core.sidecars.locator() {
                await report(.placed(locator))
            }
        }
        guard !Task.isCancelled else { return }
        for await event in core.tracker.start(roots.map { URL(fileURLWithPath: $0, isDirectory: true) }) {
            await followed(event, core: core, report: report)
        }
    }

    /// What change tracking's `event` makes of the roots: a volume's roots are current once its first
    /// pass has run to its end (`caughtUp`, again after it's back), and not once it stops answering.
    nonisolated static func followed(
        _ event: ChangeTracker.Event, core: LibraryCore, report: @Sendable (Progress) async -> Void,
    ) async {
        switch event {
        case let .caughtUp(volume):
            await report(.current(rootPaths(onVolume: volume, core: core)))
        case let .indexer(.volumeOffline(volume)):
            await report(.offline(rootPaths(onVolume: volume, core: core)))
        case let .indexer(.finished(summary)):
            if summary.photosInserted + summary.photosUpdated + summary.photosMoved + summary.photosRemoved > 0 {
                core.snapshotIfDue()
            }
        default:
            break
        }
        await received(event, core: core, report: report)
    }

    private nonisolated static func received(
        _ event: ChangeTracker.Event, core: LibraryCore, report: @Sendable (Progress) async -> Void,
    ) async {
        core.live.receive(event)
        switch event {
        case let .indexer(.folderIndexed(folder)):
            await report(.indexed(folder.path))
        case let .indexer(.photosUpdated(ids)):
            await core.readAgain(ids)
        case .indexer(.volumeOffline), .indexer(.volumeOnline):
            // A volume marks all its photos at once, without an event for each.
            if let changed = try? await core.engine.photosWithChangedState(), !changed.isEmpty {
                core.live.photosChanged(changed)
            }
        default:
            break
        }
    }

    /// The roots the index has on the volume it calls `key`.
    private nonisolated static func rootPaths(onVolume key: String, core: LibraryCore) async -> [String] {
        await (try? core.index.read { reader in
            guard let volume = try reader.volumes().first(where: { $0.uuid == key }) else { return [] }
            return try reader.roots().filter { $0.volume == volume.id }.map(\.path)
        }) ?? []
    }

    private nonisolated static func isInICloudDrive(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [.isUbiquitousItemKey]))?
            .isUbiquitousItem == true
    }

    private func progressed(_ progress: Progress) {
        switch progress {
        case let .current(roots):
            currentRoots.formUnion(roots.filter(self.roots.contains))
        case let .offline(roots):
            currentRoots.subtract(roots)
        case let .indexed(path):
            indexedFolders.insert(path)
        case let .placed(locator):
            placed(locator)
        }
        notify()
    }

    /// Calls `handler` when more folders may be shown from the library, until the returned token is
    /// released.
    func observe(_ handler: @escaping @MainActor () -> Void) -> LibraryObservation {
        let id = UUID()
        observers[id] = handler
        return LibraryObservation { [weak self] in self?.observers.removeValue(forKey: id) }
    }

    /// Tells the observers, at most every quarter of a second: indexing reports a folder at a time.
    private func notify() {
        guard !notifying else { return }
        notifying = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            notifying = false
            for observer in observers.values {
                observer()
            }
        }
    }

    // MARK: - Showing folders

    /// Whether `folder` can be shown from the library (with `includingSubfolders`, every folder below
    /// it too): each is indexed as its last listing found it, that listing is current, and with
    /// `listed`, the folders Folders listed itself, the library has those same folders.
    @_spi(Harness) public func canShow(
        _ folder: URL, includingSubfolders: Bool, listed: Set<String>? = nil,
    ) async -> Bool {
        guard let core else { return false }
        let path = Self.path(folder)
        guard let root = roots.filter({ path == $0 || path.hasPrefix($0 == "/" ? $0 : $0 + "/") })
            .max(by: { $0.count < $1.count })
        else { return false }
        let rootIsCurrent = currentRoots.contains(root)
        let indexed = rootIsCurrent ? [] : indexedFolders
        let listed = listed.map { Set($0.map { Self.path(URL(fileURLWithPath: $0, isDirectory: true)) }) }
        let folders = try? await core.index.read { reader -> [FolderRecord]? in
            guard let top = try Self.folder(at: path, in: reader) else { return nil }
            guard includingSubfolders else { return [top] }
            let below = path == "/" ? "/" : path + "/"
            return try reader.folders(inRoot: top.root).filter { $0.path == path || $0.path.hasPrefix(below) }
        }
        guard let folders = folders ?? nil, folders.allSatisfy(\.isIndexed) else { return false }
        if let listed, listed != Set(folders.map(\.path)) {
            return false
        }
        return rootIsCurrent || folders.allSatisfy { indexed.contains($0.path) }
    }

    /// `folder`'s photos from the library, filtered and sorted as the filter bar has the folder,
    /// delivered to `deliver` as they change, until the list is closed.
    func list(
        _ folder: URL, includingSubfolders: Bool,
        deliver: @escaping @MainActor @Sendable (LibraryFolderList.Change) -> Void,
    ) -> LibraryFolderList? {
        guard let core else { return nil }
        filters.follow(folder, includingSubfolders: includingSubfolders)
        let list = LibraryFolderList(
            core: core, folder: folder, includingSubfolders: includingSubfolders,
            filter: filters.request(for: folder, includingSubfolders: includingSubfolders), deliver: deliver,
        )
        currentList = list
        return list
    }

    /// Filters and sorts the list of `folder` the library is showing, if it is; false when it isn't.
    @discardableResult
    func filter(_ folder: URL, includingSubfolders: Bool, by filter: LibraryListFilter) -> Bool {
        guard let list = currentList, list.folder == folder, list.includesSubfolders == includingSubfolders
        else { return false }
        list.setFilter(filter)
        return true
    }

    /// Redlamp wrote `photo`'s sidecar through `store`.
    func sidecarSaved(_ photo: URL, store: SidecarStore) {
        core?.sidecarSaved(photo, store: store)
    }

    // MARK: - Culling (LIB-15)

    /// Gives each of `photos` its own fields (`fields`, by place), as one batch off the main thread, in the
    /// library's changes' turn (`LibraryCore.change`). Lists hear of its photos once the index holds it, as
    /// `queue` allows for change `sequence`; the photos the index doesn't have are left for their own saves,
    /// but for those in the Trash (Recently Trashed's), which are left as they are.
    func cull(
        _ photos: [URL], fields: [[MetadataField]], sequence: UInt64, queue: CullingQueue,
    ) async -> CullingWritten {
        guard let core, let metadata else { return Self.leavingTrash(CullingWritten(unindexed: photos)) }
        return await core.change {
            let ids = await Self.indexIDs(of: photos, in: core.index)
            var written = CullingWritten(ids: Dictionary(ids.map { ($1, $0) }) { first, _ in first })
            var each: [Int64: [MetadataField]] = [:]
            for (place, photo) in photos.enumerated() {
                if let id = ids[photo] {
                    each[id] = fields[place]
                } else {
                    written.unindexed.append(photo)
                }
            }
            written = Self.leavingTrash(written)
            if !each.isEmpty {
                do {
                    let plan = try await metadata.plan(.each(each))
                    await Self.run(
                        plan,
                        metadata: metadata,
                        core: core,
                        sequence: sequence,
                        queue: queue,
                        into: &written,
                    )
                } catch {
                    written.failed(each.keys.compactMap { written.ids[$0] }, error)
                }
            }
            core.live.photosChanged(queue.indexed([], by: sequence))
            return written
        }
    }

    /// Takes back `batches`, newest first, as `cull` makes them; `photos` are their photos by index ID. The
    /// written batches are the Undos, which `redoCulling` takes back.
    func undoCulling(
        _ batches: [UUID], photos: [Int64: URL], sequence: UInt64, queue: CullingQueue,
    ) async -> CullingWritten {
        await runCulling(
            batches.reversed().map { batch -> CullingPlanning in { try await $0.planUndo(batch) } }, photos: photos,
            sequence: sequence, queue: queue,
        )
    }

    /// Makes again the batches Undo took back (`undos`, as `undoCulling` wrote them) as the Undo of each Undo,
    /// oldest batch first; nil, nothing made, when the journal doesn't have every one of them as it was run.
    func redoCulling(
        _ undos: [UUID], photos: [Int64: URL], sequence: UInt64, queue: CullingQueue,
    ) async -> CullingWritten? {
        guard let core, let metadata else { return nil }
        let plans: [MetadataPlan]? = await core.change {
            var plans: [MetadataPlan] = []
            for undo in undos.reversed() {
                guard let plan = try? await metadata.planRedo(undo) else { return nil }
                plans.append(plan)
            }
            return plans
        }
        guard let plans else { return nil }
        return await runCulling(
            plans.map { plan -> CullingPlanning in { _ in plan } }, photos: photos, sequence: sequence, queue: queue,
        )
    }

    /// A batch to run, planned when it's its turn.
    private typealias CullingPlanning = @Sendable (LibraryMetadata) async throws -> MetadataPlan

    /// Runs each of `plans` in turn, off the main thread, in the library's changes' turn.
    private func runCulling(
        _ plans: [CullingPlanning], photos: [Int64: URL], sequence: UInt64, queue: CullingQueue,
    ) async -> CullingWritten {
        guard let core, let metadata else { return CullingWritten() }
        return await core.change {
            var written = CullingWritten(ids: photos)
            for plan in plans {
                do {
                    try await Self.run(
                        plan(metadata), metadata: metadata, core: core, sequence: sequence, queue: queue,
                        into: &written,
                    )
                } catch {
                    written.errors.append(String(describing: error))
                }
            }
            core.live.photosChanged(queue.indexed([], by: sequence))
            return written
        }
    }

    /// Redlamp changed these photos' rows itself: the open lists read them again.
    func photosChanged(_ ids: [Int64]) {
        core?.live.photosChanged(ids)
    }

    /// The badges the library's lists show for the photos at `urls`, from their rows; those it doesn't have
    /// are left out.
    func badges(of urls: [URL]) async -> [URL: PhotoMetadata] {
        guard let core else { return [:] }
        let ids = await Self.indexIDs(of: urls, in: core.index)
        return await (try? core.index.read { reader in
            var found: [URL: PhotoMetadata] = [:]
            for (url, id) in ids {
                if let row = try reader.photo(id: id) {
                    found[url] = LibraryFolderList.Mapping.item(row, url: url).metadata
                }
            }
            return found
        }) ?? [:]
    }

    /// The custom labels the library's photos have, with how many have each.
    func customLabels() async -> [CustomLabelCount] {
        await (try? metadata?.customLabels()) ?? []
    }

    // MARK: - Other apps' metadata (LIB-24)

    /// Keeps `settings` in the index, where `redlamp library xmp` reads them too, and syncs by them from
    /// now on; the photos already in the library are left as they are. Turning writing off stops writing
    /// every photo's `.xmp`. False when they couldn't be kept.
    public func setXMPSettings(_ settings: XMPSettings) async -> Bool {
        guard let core else { return false }
        do {
            try await core.xmp.setSettings(settings)
        } catch {
            Self.log.error(
                "The library's settings for other apps weren't saved: \(String(describing: error), privacy: .public)",
            )
            return false
        }
        core.xmpSettings = settings
        xmpSettings = settings
        if !settings.writes {
            writingAllXMP?.cancel()
        }
        return true
    }

    /// Writes every photo's `.xmp` in the background, a batch at a time between the library's other
    /// changes, merging other apps' changes as each sync does: asked for in Settings, with writing on.
    func writeXMPForAllPhotos() {
        guard let core, writingAllXMP == nil, xmpSettings?.writes == true else { return }
        isWritingAllXMP = true
        writingAllXMP = Task { [weak self] in
            let ids = await core.allPhotoIDs()
            var start = 0
            while start < ids.count, !Task.isCancelled {
                self?.xmpRemaining = ids.count - start
                let batch = Array(ids[start ..< min(start + LibraryCore.xmpBatch, ids.count)])
                await core.syncXMPNow(batch)
                start += batch.count
            }
            self?.xmpRemaining = nil
            self?.isWritingAllXMP = false
            self?.writingAllXMP = nil
        }
    }

    /// Stops writing every photo's `.xmp`: those written stay.
    func stopWritingXMPForAllPhotos() {
        writingAllXMP?.cancel()
    }

    /// How many photos the library has; nil until it's open.
    func photoCount() async -> Int? {
        guard let core else { return nil }
        return try? await core.index.read { try $0.photoCount() }
    }

    /// Returns once the XMP syncs asked for so far are done.
    @_spi(Harness) public func xmpSynced() async {
        await core?.xmpSynced()
    }

    /// Runs `plan`, telling the lists of its photos once the index holds it (when its first sidecar is
    /// written, or when it's done if it writes none); a batch that fails has been rolled back. Its photos'
    /// `.xmp` follow once it's done, when they're written.
    private nonisolated static func run(
        _ plan: MetadataPlan, metadata: LibraryMetadata, core: LibraryCore, sequence: UInt64, queue: CullingQueue,
        into written: inout CullingWritten,
    ) async {
        let photos = plan.photos.map(\.id)
        let told = CullingOnce()
        let tell: @Sendable () -> Void = {
            guard told.first() else { return }
            core.live.photosChanged(queue.indexed(photos, by: sequence))
        }
        do {
            let outcome = try await metadata.run(plan) { _, _ in tell() }
            tell()
            core.changed(photos)
            written.batches.append(outcome.batch)
            for photo in plan.photos {
                guard let reason = outcome.reasons[photo.path], let url = written.ids[photo.id] else { continue }
                written.unwritten.append(url)
                written.reasons[url] = reason
            }
        } catch {
            tell()
            written.failed(photos.compactMap { written.ids[$0] }, error)
        }
    }

    /// The index's IDs of the photos at `urls` it has, a folder's photos read at a time. Folders and names
    /// match in either of Unicode's forms (`Café` composed or decomposed), as the file system's do.
    nonisolated static func indexIDs(of urls: [URL], in index: LibraryIndex) async -> [URL: Int64] {
        var byFolder: [String: [URL]] = [:]
        for url in urls {
            byFolder[path(url.deletingLastPathComponent()), default: []].append(url)
        }
        let folders = byFolder
        return await (try? index.read { reader -> [URL: Int64] in
            var found: [URL: Int64] = [:]
            for (path, photos) in folders {
                guard let folder = try Self.folder(at: path, in: reader) else { continue }
                let named = try Dictionary(reader.photos(inFolder: folder.id).map {
                    ($0.name.precomposedStringWithCanonicalMapping, $0.id)
                }) { first, _ in first }
                for url in photos {
                    if let id = named[url.lastPathComponent.precomposedStringWithCanonicalMapping] {
                        found[url] = id
                    }
                }
            }
            return found
        }) ?? [:]
    }

    /// The index's folder at `path` (as `path(_:)` gives it), in whichever of Unicode's forms the index keeps
    /// its name: Foundation's URLs decompose names, and the index keeps them as listings gave them.
    nonisolated static func folder(at path: String, in reader: some IndexQueries) throws -> FolderRecord? {
        for form in forms(of: path) {
            if let folder = try reader.folder(path: form) {
                return folder
            }
        }
        return nil
    }

    /// The index's row of the photo at `url`, its folder and name found in either of Unicode's forms.
    nonisolated static func photo(at url: URL, in reader: some IndexQueries) throws -> PhotoRecord? {
        guard let folder = try folder(at: path(url.deletingLastPathComponent()), in: reader) else { return nil }
        for name in Self.forms(of: url.lastPathComponent) {
            if let photo = try reader.photo(folder: folder.id, name: name) {
                return photo
            }
        }
        return nil
    }

    /// `text` as given, then composed, then decomposed, each once. Swift's strings compare equal in either
    /// form; the index's SQL compares their bytes.
    private nonisolated static func forms(of text: String) -> [String] {
        var forms = [text]
        for form in [text.precomposedStringWithCanonicalMapping, text.decomposedStringWithCanonicalMapping]
            where !forms.contains(where: { $0.utf8.elementsEqual(form.utf8) }) {
            forms.append(form)
        }
        return forms
    }

    /// The path the index keeps for `url`: standardised, without a trailing slash.
    nonisolated static func path(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private nonisolated static func paths(_ urls: [URL]) -> [String] {
        var seen = Set<String>()
        return urls.map(path).filter { seen.insert($0).inserted }
    }
}

/// What the library made of a culling change.
struct CullingWritten: Sendable {
    /// The batches it ran, for their Undo.
    var batches: [UUID] = []
    /// The photos it has, by index ID.
    var ids: [Int64: URL] = [:]
    /// The photos it leaves to their own saves: those it hasn't indexed.
    var unindexed: [URL] = []
    /// Photos it left as they were: their sidecars can't be read or written here, or their batch failed and
    /// was rolled back.
    var unwritten: [URL] = []
    /// Why each of `unwritten` was left, but for those of a batch that failed, which `errors` says.
    var reasons: [URL: String] = [:]
    var errors: [String] = []

    mutating func failed(_ photos: [URL], _ error: any Error) {
        unwritten += photos
        errors.append(String(describing: error))
    }
}

/// Whether something has happened yet, from any thread.
final class CullingOnce: Sendable {
    private let done = Mutex(false)

    /// True the first time only.
    func first() -> Bool {
        done.withLock { done in
            defer { done = true }
            return !done
        }
    }
}
