import AppKit
import CoreGraphics
import Foundation
import OSLog
import RedlampDocument
import RedlampLibrary

/// The library in the app (LIB-10, LIB-11, LIB-09): its index, search, thumbnail store, indexer and
/// change tracking, over the folders in Folders.
///
/// It opens at launch off the main thread: the index (from its newest good snapshot when it's
/// damaged), the column store and the thumbnail store, then it finishes a sidecar move a quit
/// interrupted. It indexes the folders in Folders and keeps them current, and `FolderLibrary`
/// shows a folder it has indexed from a photo list. Until it's open, and for a folder it hasn't
/// indexed, `FolderLibrary` lists folders itself, as it does with the library off
/// (`defaults write app.redlamp.mac LibraryEnabled -bool NO`) or when the index can't open.
///
/// A folder is shown from the library once it's indexed as its last listing found it and that
/// listing is current: made in this session, or in a root change tracking has caught up with since
/// launch (its history replayed, or its folders compared).
@MainActor
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

    public let paths: LibraryPaths
    public private(set) var state = State.opening
    /// Where photos' sidecars are read and written: `FolderLibrary`'s, set as placements change.
    let sidecars: SidecarPlacement
    private let defaults: UserDefaults?
    private let thumbnail: @Sendable (URL, Int) -> CGImage?
    private(set) var core: LibraryCore?
    /// The roots followed, as the index keeps their paths.
    private(set) var roots: [String] = []
    private var opening: Task<Void, Never>?
    private var following: Task<Void, Never>?
    /// Roots whose volumes change tracking has caught up with since launch.
    private(set) var currentRoots: Set<String> = []
    /// Folders indexed in this session, as they were listed then.
    private var indexedFolders: Set<String> = []
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var notifying = false
    private var activity: [any NSObjectProtocol] = []

    private nonisolated static let log = Logger(subsystem: "app.redlamp.mac", category: "library")
    /// The defaults key set when the index was found damaged, so the next launch checks it as it opens.
    static let damagedKey = "library.indexDamaged"

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
        if let defaults, let saved = SidecarLocator.saved(in: defaults) {
            sidecars.locator = saved
        }
    }

    isolated deinit {
        opening?.cancel()
        following?.cancel()
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
        opening = Task { [weak self] in
            let opened = await Task.detached(priority: .userInitiated) { () -> Result<LibraryCore, any Error> in
                do {
                    let (core, outcome) = try await LibraryCore.open(paths: paths, check: check, thumbnail: thumbnail)
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

    private func opened(_ result: Result<LibraryCore, any Error>) {
        opening = nil
        switch result {
        case let .failure(error):
            state = .unavailable(String(describing: error))
            Self.log.error(
                "The library's index didn't open, so Folders lists folders itself: \(String(describing: error), privacy: .public)",
            )
        case let .success(core):
            self.core = core
            defaults?.removeObject(forKey: Self.damagedKey)
            placed(core.locator)
            state = .ready
            followActivity(core)
            let roots = roots
            self.roots = []
            follow(roots.map { URL(fileURLWithPath: $0, isDirectory: true) })
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

    /// Stops indexing and writes the store's index files: when the app quits.
    public func close() {
        opening?.cancel()
        following?.cancel()
        guard let core else { return }
        core.tracker.stop()
        core.store.close()
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
    private enum Progress: Sendable {
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
        var running: String?
        for await event in core.tracker.start(roots.map { URL(fileURLWithPath: $0, isDirectory: true) }) {
            switch event {
            case let .reconciled(volume, _), let .changed(volume, _), let .polled(volume, _):
                running = volume
            case let .replayed(volume, folders):
                running = folders == 0 ? nil : volume
                if folders == 0 {
                    await report(.current(rootPaths(onVolume: volume, core: core)))
                }
            case let .indexer(.finished(summary)):
                if let volume = running {
                    await report(.current(rootPaths(onVolume: volume, core: core)))
                }
                running = nil
                if summary.photosInserted + summary.photosUpdated + summary.photosMoved + summary.photosRemoved > 0 {
                    core.snapshotIfDue()
                }
            case let .indexer(.volumeOffline(volume)):
                await report(.offline(rootPaths(onVolume: volume, core: core)))
            default:
                break
            }
            await received(event, core: core, report: report)
        }
    }

    private nonisolated static func received(
        _ event: ChangeTracker.Event, core: LibraryCore, report: @Sendable (Progress) async -> Void,
    ) async {
        core.live.receive(event)
        if case let .indexer(.folderIndexed(folder)) = event {
            await report(.indexed(folder.path))
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
            guard let top = try reader.folder(path: path) else { return nil }
            var folders = [top]
            var next = 0
            while includingSubfolders, next < folders.count {
                folders += try reader.subfolders(of: folders[next].id)
                next += 1
            }
            return folders
        }
        guard let folders = folders ?? nil, folders.allSatisfy(\.isIndexed) else { return false }
        if let listed, listed != Set(folders.map(\.path)) {
            return false
        }
        return rootIsCurrent || folders.allSatisfy { indexed.contains($0.path) }
    }

    /// `folder`'s photos from the library, delivered to `deliver` as they change, until the list is
    /// closed.
    func list(
        _ folder: URL, includingSubfolders: Bool,
        deliver: @escaping @MainActor @Sendable (LibraryFolderList.Change) -> Void,
    ) -> LibraryFolderList? {
        guard let core else { return nil }
        return LibraryFolderList(core: core, folder: folder, includingSubfolders: includingSubfolders, deliver: deliver)
    }

    /// Redlamp wrote `photo`'s sidecar through `store`.
    func sidecarSaved(_ photo: URL, store: SidecarStore) {
        core?.sidecarSaved(at: Self.path(photo), photo: photo, store: store)
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
