import AppKit
import Foundation
import Observation
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary

/// How the photos changed, for views that update row by row (the filmstrip): rows removed
/// (indices before the change), rows inserted and rows whose badges changed (indices after it).
/// `reset` replaces everything, as when another folder opens.
public struct LibraryDiff: Sendable, Equatable {
    public var reset = false
    public var removed = IndexSet()
    public var inserted = IndexSet()
    public var updated = IndexSet()

    public init(reset: Bool = false, removed: IndexSet = [], inserted: IndexSet = [], updated: IndexSet = []) {
        self.reset = reset
        self.removed = removed
        self.inserted = inserted
        self.updated = updated
    }

    public var isEmpty: Bool {
        !reset && removed.isEmpty && inserted.isEmpty && updated.isEmpty
    }
}

extension IndexSet {
    /// `rows`, in any order, inserted a run of consecutive rows at a time: a selection's 20,000 rows are one
    /// insert, where one each takes most of a millisecond.
    init(rows: [Int]) {
        self.init()
        let sorted = zip(rows, rows.dropFirst()).allSatisfy { $0 <= $1 } ? rows : rows.sorted()
        var start = sorted.startIndex
        while start < sorted.endIndex {
            var end = start + 1
            while end < sorted.endIndex, sorted[end] <= sorted[end - 1] + 1 {
                end += 1
            }
            insert(integersIn: sorted[start] ... sorted[end - 1])
            start = end
        }
    }
}

/// A folder as the tree shows it: the photos directly in it and its subfolders, in Finder's order.
public struct FolderNode: Sendable, Equatable {
    public var count: Int
    public var subfolders: [URL]

    public init(count: Int, subfolders: [URL]) {
        self.count = count
        self.subfolders = subfolders
    }
}

/// The working set of folders, and the photos of the one that's open.
///
/// - Roots are the folders the user added (see `FolderLibrary+WorkingSet`), remembered by bookmark.
/// - Opening a folder lists it without reading sidecars; with Show Photos in Subfolders, every
///   folder beneath it is listed in parallel and streamed in in order. The badges of photos with a
///   sidecar follow from light probes of their `edit.json`, visible photos first.
/// - With the library on, a folder it has indexed is shown from its photo list instead, and one it
///   hasn't switches over once it has (see `FolderLibrary+Library`). The Library panel's entries and
///   the collections can be shown in place of a folder, from their photo lists (see
///   `FolderLibrary+Collections`), and so can Recently Trashed, the photos its batches moved to the
///   Trash (see `FolderLibrary+Trash`).
/// - `items` isn't observed (a badge mustn't re-render SwiftUI views); views observe `count`,
///   `revision` or `openFolder`, and the filmstrip applies `LibraryDiff`s row by row.
@MainActor
@Observable
public final class FolderLibrary {
    /// The folders the user added, in the order they were added.
    public internal(set) var roots: [WorkingFolder] = []
    /// `roots` are the working set a launch kept, not one made afresh: the library may take out what they lost.
    @ObservationIgnored var hasSavedRoots = false
    /// Roots that can't be found now (deleted, or on a volume that isn't mounted).
    public internal(set) var missing: Set<UUID> = []
    public internal(set) var openFolder: URL?
    /// Show Photos in Subfolders: on, as in Lightroom Classic, unless the user turned it off.
    public internal(set) var includesSubfolders = true
    /// The folder tree's expanded rows (paths). Not observed, like `tree`: the Folders panel
    /// changes only the rows a change touches.
    @ObservationIgnored public internal(set) var expandedFolders: Set<String> = []
    /// Folders listed for the tree, by path: how many photos each holds and its subfolders.
    /// Changes are announced to `observeTree` handlers.
    @ObservationIgnored public internal(set) var tree: [String: FolderNode] = [:]
    @ObservationIgnored var listingTree: Set<String> = []
    @ObservationIgnored var treeObservers: [UUID: @MainActor (Set<String>) -> Void] = [:]
    /// The library's counts of the folders it has indexed, for the tree (see `FolderLibrary+Library`).
    @ObservationIgnored var counting = Counting()
    /// Recently Trashed as the library last listed it (see `FolderLibrary+Trash`).
    @ObservationIgnored var trash = TrashFollowing()
    /// The open folder (and with subfolders, its tree) is still being listed.
    public internal(set) var isListing = false
    /// The open folder can't be listed (its volume went away).
    public internal(set) var isOpenFolderUnavailable = false
    /// Recently Trashed is the source shown, in place of a folder (LIB-26, `FolderLibrary+Trash`).
    public internal(set) var showsRecentlyTrashed = false
    /// The Library panel's entry or the collection shown in place of a folder, from the library's list of its
    /// photos (LIB-23, `FolderLibrary+Collections`).
    public internal(set) var shownSource: LibrarySource?
    /// Keeps the view of the entry or collection shown as another opening replaces it, while its photos are
    /// still the ones shown.
    @ObservationIgnored var leavingSource: (@MainActor (LibrarySource) -> Void)?
    /// How many photos Recently Trashed holds; nil until the library has looked, and with it off.
    public internal(set) var trashedCount: Int?
    /// The number of photos shown.
    public private(set) var count = 0
    /// Bumped by every change to `items`.
    public private(set) var revision = 0

    @ObservationIgnored public internal(set) var items: [LibraryItem] = []
    /// Each photo's ID, beside `items`: given as it's listed and kept while it's shown, never reused, so
    /// a selection over them (`photoList`) outlives any change.
    @ObservationIgnored public internal(set) var photoIDs: ContiguousArray<Int64> = []
    @ObservationIgnored var nextPhotoID: Int64 = 0
    @ObservationIgnored private var madeList: PhotoList?
    @ObservationIgnored var positions: [URL: Int] = [:]
    @ObservationIgnored let scheduler: WorkScheduler
    /// Starts every key this library gives `scheduler`, which other libraries share (the harness's
    /// scenes', each test's): a job with another's key would replace it, or be cancelled with it.
    @ObservationIgnored let keyPrefix = "library \(UUID().uuidString) "
    @ObservationIgnored let defaults: UserDefaults?
    /// Puts the badges of a change's rows right before anyone is told of it (culling's, which the library's
    /// lists can be a change behind).
    @ObservationIgnored var adjust: (@MainActor (LibraryDiff) -> Void)?
    /// Where each photo's sidecar is read and written: beside it, or where the library keeps it.
    @ObservationIgnored public let sidecars = SidecarPlacement()
    /// The library, when it's on (`attach`).
    @ObservationIgnored public internal(set) var service: LibraryService?
    @ObservationIgnored var fromLibrary = FromLibrary()
    /// The time the settle rule (`isSettling(_:at:)`) reads.
    @ObservationIgnored var clock: () -> Date = { Date() }
    @ObservationIgnored var generation = 0
    @ObservationIgnored private var observers: [UUID: @MainActor (LibraryDiff) -> Void] = [:]
    /// The first rows of probe batches still waiting, for `prioritize`.
    @ObservationIgnored private var probeStarts: Set<Int> = []
    @ObservationIgnored private var probedGeneration = 0
    /// The last photo shown in each folder (paths), most recent last.
    @ObservationIgnored var lastPhotos: [String: String] = [:]
    @ObservationIgnored var lastPhotoOrder: [String] = []
    /// Roots whose access was started (security-scoped once sandboxed).
    @ObservationIgnored var accessing: Set<String> = []
    /// The directories whose photos are shown (the open folder, and its subtree with subfolders).
    @ObservationIgnored var listedDirectories: Set<String> = []
    /// File-system watching (see `FolderLibrary+Watching`).
    @ObservationIgnored var watching = Watching()
    /// The open folder was listed again after its volume came back.
    @ObservationIgnored var onReopened: (@MainActor ([LibraryItem]) -> Void)?
    /// Focus stacks found in the shown directories.
    @ObservationIgnored var onStacks: (@MainActor ([StackSuggestion]) -> Void)?
    /// Called once a folder has left the library, from Folders or as the library opened (`LibraryService.removed`).
    @ObservationIgnored var onRemoved: (@MainActor () -> Void)?
    /// Finishes a move of a root's edits and metadata a quit interrupted, once the library is open
    /// (`followUnfinishedSidecarMove`).
    @ObservationIgnored var unfinishedSidecarMove: (@MainActor (SidecarMoveRecord) -> Void)?
    @ObservationIgnored var lookedForSidecarMove = false
    /// What stacks are found from: the engine's reader, which in the Mac app reads in the decode
    /// service. Until it is set, no stacks are found.
    @ObservationIgnored var files: any FileInspecting = UnreadableFiles()
    /// Focus stacks found per directory, kept while its listing is unchanged.
    @ObservationIgnored var stackCache: [String: (signature: Int, suggestions: [StackSuggestion])] = [:]

    /// Photos per probe job: big enough that scheduling is noise, small enough that the visible
    /// ones' badges come first.
    static let probeBatch = 32

    /// `defaults` keeps the working set across launches; nil keeps it in memory only.
    public init(scheduler: WorkScheduler = .shared, defaults: UserDefaults? = nil) {
        self.scheduler = scheduler
        self.defaults = defaults
        loadSettings()
    }

    isolated deinit {
        fromLibrary.list?.close()
        fromLibrary.sourceList?.close()
        trash.following?.cancel()
        if let activation = trash.activation {
            NotificationCenter.default.removeObserver(activation)
        }
        watching.watcher?.stop()
        watching.poll?.invalidate()
        for observer in watching.mountObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Reading

    public func index(of url: URL) -> Int? {
        positions[url]
    }

    public func item(for url: URL) -> LibraryItem? {
        positions[url].map { items[$0] }
    }

    /// The photos shown, by ID in their order, for selections; made again after photos come or go.
    public var photoList: PhotoList {
        if let madeList {
            return madeList
        }
        let source = openFolder.map { PhotoSource.folder($0, includingSubfolders: includesSubfolders) }
            ?? fromLibrary.sourcePhotos
        let list = PhotoList(source: source ?? .allPhotographs, ids: photoIDs)
        madeList = list
        return list
    }

    public func photoID(of url: URL) -> Int64? {
        positions[url].map { photoIDs[$0] }
    }

    public func url(ofPhoto id: Int64) -> URL? {
        photoList.index(of: id).map { items[$0].url }
    }

    /// IDs for `count` photos just listed.
    func newPhotoIDs(_ count: Int) -> Range<Int64> {
        defer { nextPhotoID += Int64(count) }
        return nextPhotoID ..< nextPhotoID + Int64(count)
    }

    /// Photos came or went: `photoList` is made again when it's next asked for.
    func photosMoved() {
        madeList = nil
    }

    /// Calls `handler` after every change, until the returned token is released.
    public func observe(_ handler: @escaping @MainActor (LibraryDiff) -> Void) -> LibraryObservation {
        let id = UUID()
        observers[id] = handler
        return LibraryObservation { [weak self] in self?.observers.removeValue(forKey: id) }
    }

    // MARK: - Opening

    /// Lists `folder` (and, with Show Photos in Subfolders, every folder beneath it) and shows its
    /// photos, then calls `opened` with them once the first ones are in (once, unless another
    /// folder opens first). `nil` closes the open folder.
    public func open(_ folder: URL?, opened: @escaping @MainActor ([LibraryItem]) -> Void = { _ in }) {
        if let shownSource {
            leavingSource?(shownSource)
            self.shownSource = nil
        }
        generation += 1
        let generation = generation
        scheduler.cancel(prefix: probeKeyPrefix(generation - 1))
        closeLibraryList()
        showsRecentlyTrashed = false
        trash.opened = nil
        trash.folderBefore = nil
        trash.keys = [:]
        openFolder = folder
        isOpenFolderUnavailable = false
        listedDirectories = []
        replace(with: [])
        saveSettings()
        isListing = folder != nil
        guard let folder else { return }
        guard let service else { return list(folder, generation: generation, opened: opened) }
        service.show([folder])
        Task {
            guard await !openFromLibrary(folder, generation: generation, opened: opened),
                  self.generation == generation
            else { return }
            list(folder, generation: generation, opened: opened)
        }
    }

    /// Lists `folder`, and with Show Photos in Subfolders every folder beneath it, then has the
    /// library show it once it can.
    func list(_ folder: URL, generation: Int, opened: @escaping @MainActor ([LibraryItem]) -> Void) {
        let includesSubfolders = includesSubfolders
        Task {
            if includesSubfolders {
                var announced = false
                var listed = false
                for await listing in FolderScanner.walk(folder, scheduler: scheduler) {
                    guard self.generation == generation else { return }
                    listed = true
                    remember(listing)
                    append(LibraryItem.items(listing))
                    if !announced, !items.isEmpty {
                        announced = true
                        opened(items)
                    }
                }
                guard self.generation == generation else { return }
                isListing = false
                isOpenFolderUnavailable = !listed
                if !announced {
                    opened(items)
                }
                refreshStacks()
                awaitLibrary(generation)
                let directories = listedDirectories
                _ = try? await scheduler.run(.background) {
                    for directory in directories {
                        SidecarStore.removeLeftovers(in: URL(fileURLWithPath: directory))
                    }
                }
            } else {
                let found = try? await scheduler.run(.onScreen) {
                    try LibraryItem.items(FolderScanner.list(folder))
                }
                guard self.generation == generation else { return }
                isListing = false
                isOpenFolderUnavailable = found == nil
                if found != nil {
                    listedDirectories = [folder.path]
                }
                replace(with: found ?? [])
                probeSidecars(in: 0 ..< items.count, generation: generation)
                opened(items)
                refreshStacks()
                awaitLibrary(generation)
                _ = try? await scheduler.run(.background) { SidecarStore.removeLeftovers(in: folder) }
            }
        }
    }

    /// Shows or hides the photos of the open folder's subfolders, and counts them in the folder tree or
    /// not: the user's choice, kept across launches.
    public func setIncludesSubfolders(
        _ include: Bool, opened: @escaping @MainActor ([LibraryItem]) -> Void = { _ in },
    ) {
        guard include != includesSubfolders else { return }
        includesSubfolders = include
        defaults?.set(include, forKey: Key.subfolders)
        if let openFolder {
            open(openFolder, opened: opened)
        }
    }

    func replace(with items: [LibraryItem]) {
        replace(with: items, positions: Dictionary(items.enumerated().map { ($1.url, $0) }) { first, _ in first })
    }

    /// `positions` being each item's index, as made off the main thread.
    func replace(with items: [LibraryItem], positions: [URL: Int]) {
        self.items = items
        self.positions = positions
        photoIDs = ContiguousArray(newPhotoIDs(items.count))
        photosMoved()
        publish(LibraryDiff(reset: true))
    }

    private func remember(_ listing: FolderListing) {
        listedDirectories.insert(listing.folder.path)
    }

    /// Adds photos after the last (a subfolder's, in walk order).
    private func append(_ new: [LibraryItem]) {
        guard !new.isEmpty else { return }
        let start = items.count
        items += new
        photoIDs += newPhotoIDs(new.count)
        photosMoved()
        reindex(from: start)
        publish(LibraryDiff(inserted: IndexSet(integersIn: start ..< items.count)))
        probeSidecars(in: start ..< items.count, generation: generation)
    }

    /// Adds a photo in name order (a stack document just saved).
    func insert(_ item: LibraryItem) {
        guard positions[item.url] == nil else { return }
        let index = items.firstIndex { FileOrder.precedes(item.name, $0.name) } ?? items.count
        items.insert(item, at: index)
        photoIDs.insert(newPhotoIDs(1).lowerBound, at: index)
        photosMoved()
        reindex(from: index)
        publish(LibraryDiff(inserted: [index]))
    }

    /// Changes one photo's badges.
    func update(_ url: URL, _ change: (inout LibraryItem) -> Void) {
        guard let index = positions[url] else { return }
        var item = items[index]
        change(&item)
        guard item != items[index] else { return }
        items[index] = item
        publish(LibraryDiff(updated: [index]))
    }

    func reindex(from start: Int) {
        for index in start ..< items.count {
            positions[items[index].url] = index
        }
    }

    func publish(_ diff: LibraryDiff) {
        adjust?(diff)
        count = items.count
        revision += 1
        for observer in observers.values {
            observer(diff)
        }
    }

    // MARK: - Badges

    private func probeKeyPrefix(_ generation: Int) -> String {
        keyPrefix + "probe:\(generation):"
    }

    /// Reads the badges of the photos in `rows` with a local sidecar, a batch per job, in order.
    /// A batch is keyed by its first row, so `prioritize` can find the visible ones.
    func probeSidecars(in rows: Range<Int>, generation: Int) {
        let sidecars = sidecars
        if generation != probedGeneration {
            probedGeneration = generation
            probeStarts = []
        }
        for start in stride(from: rows.lowerBound, to: rows.upperBound, by: Self.probeBatch) {
            let urls = items[start ..< min(start + Self.probeBatch, rows.upperBound)].filter(\.needsSummary).map(\.url)
            guard !urls.isEmpty else { continue }
            probeStarts.insert(start)
            scheduler.submit(.lookAhead, key: probeKeyPrefix(generation) + "\(start)") {
                let summaries = urls.map { ($0, sidecars.store(for: $0).summary(for: $0)) }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    probeStarts.remove(start)
                    apply(summaries)
                }
            }
        }
    }

    private func apply(_ summaries: [(URL, SidecarSummary?)]) {
        var updated = IndexSet()
        for (url, summary) in summaries {
            guard let index = positions[url] else { continue }
            let summary = summary ?? SidecarSummary()
            guard items[index].hasEdits != summary.hasEdits || items[index].metadata != summary.metadata else {
                continue
            }
            items[index].hasEdits = summary.hasEdits
            items[index].metadata = summary.metadata
            updated.insert(index)
        }
        if !updated.isEmpty {
            publish(LibraryDiff(updated: updated))
        }
    }

    /// Reads the badges of these rows before any others still waiting.
    public func prioritize(_ rows: Range<Int>) {
        guard !rows.isEmpty, probedGeneration == generation else { return }
        let prefix = probeKeyPrefix(generation)
        for start in max(rows.lowerBound - Self.probeBatch + 1, 0) ..< rows.upperBound
            where probeStarts.contains(start) {
            scheduler.promote(prefix + "\(start)", to: .onScreen)
        }
    }
}

/// Keeps a `FolderLibrary.observe` handler registered while it lives.
@MainActor
public final class LibraryObservation {
    private var cancel: (() -> Void)?

    init(_ cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    public func invalidate() {
        cancel?()
        cancel = nil
    }

    isolated deinit {
        cancel?()
    }
}
