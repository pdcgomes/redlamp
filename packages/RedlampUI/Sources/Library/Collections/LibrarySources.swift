import AppKit
import Foundation
import Observation
import RedlampDesign
import RedlampDocument
import RedlampLibrary

/// The left panel's Library and Collections sections (LIB-23): the Library section's entries (All Photographs,
/// Previous Import, Marked, Rejected) and Library Health's checks (LIB-40), each offered once it holds photos,
/// with its count; the collection list, with its sets, collections and smart collections, their counts and the
/// target collection; and which of them the grid and the filmstrip show.
///
/// - **Counts** are read off the main thread (`LibraryCounts`) while the panel is in the window, at most once a
///   second while the library changes. A list of every photo, which LibraryLive hands over whenever photos come,
///   go or change, says when; so does the definitions' folder, which collections made, renamed, moved and
///   deleted rewrite. Only the rows whose counts changed are drawn again (`observeCounts`).
/// - **A source shown** takes the open folder's place (`FolderLibrary+Collections`), its list kept current by
///   LibraryLive and filtered as the filter bar has it (`LibrarySourceList`), its view kept as it's left and shown
///   again with it; opening a folder, or Recently Trashed, ends it.
/// - **Collections changed** are the library's batches (`LibraryCollections`), each on Library's Undo with the
///   panels' and culling's changes (`LibraryPanels`).
@MainActor
@Observable
public final class LibrarySources {
    /// The left panel's sections these fill.
    public enum Panel: String, CaseIterable, Sendable {
        case library, collections

        public var title: String {
            switch self {
            case .library: "Library"
            case .collections: "Collections"
            }
        }

        public var symbol: String {
            switch self {
            case .library: "photo.stack"
            case .collections: "rectangle.stack"
            }
        }
    }

    static let pairRuleKey = "library.health.pairs"
    static let expandedKey = "library.sources.expanded"
    static let collapsedSetsKey = "library.collections.collapsed"
    /// Counting at most this often while the library keeps changing.
    static let countingInterval = Duration.seconds(1)

    /// The source shown in the grid and the filmstrip, when it's one of these.
    public private(set) var shown: LibrarySource?
    /// Library Health's rule for raw and JPEG pairs; under the default, keep both, the check finds none.
    public private(set) var pairRule: PairRule
    /// Bumped when the panels' rows change: an entry offered or no longer, or a collection made, renamed, moved
    /// or deleted, or the target chosen. A count changing alone is told to `observeCounts`.
    public private(set) var rows = 0
    /// The library has been counted since the panel joined the window.
    public private(set) var isCounted = false
    /// The sections open, as last left.
    public private(set) var expanded: Set<Panel>
    /// The sets closed in the collection list, by path, as last left; every other set is open.
    @ObservationIgnored private var collapsedSets: Set<String>

    @ObservationIgnored weak var model: EditorModel?
    @ObservationIgnored private(set) var counts = LibraryCounts()
    @ObservationIgnored private var observers: [UUID: @MainActor (Set<LibrarySource>) -> Void] = [:]
    /// The source shown's list and its opening's generation.
    @ObservationIgnored private var list: LibrarySourceList?
    @ObservationIgnored private var generation: Int?
    @ObservationIgnored private var awaitingFirst = false
    @ObservationIgnored private var libraryObservation: LibraryObservation?
    @ObservationIgnored private var following: Following?
    @ObservationIgnored private var followers = 0
    /// The module the menu bar's keys were last brought up to date for.
    @ObservationIgnored private var menusModule: AppModule?
    @ObservationIgnored private var counting = false
    @ObservationIgnored private var countAgain = false
    /// The previous import as the journal last had it, and the journal's files then.
    @ObservationIgnored private var previous: (stamp: [String], found: PreviousImport?)?
    /// While Previous Import is shown: the import it shows, and its photos then.
    @ObservationIgnored private var shownImport: (id: UUID, photos: Set<Int64>)?
    /// The photos to select once Previous Import shows the newest import (`showNewestImport`).
    @ObservationIgnored private var importSelection: [URL]?
    /// How long each count took to reach the panel, for the budgets.
    @ObservationIgnored @_spi(Harness) public private(set) var countsTook: [Duration] = []

    /// What follows the library for the counts, once it's open.
    private struct Following {
        var tracker: Tracker?
        var photos: PhotoListUpdates?
        var listening: Task<Void, Never>?
        var definitions: (any DispatchSourceFileSystemObject)?
    }

    init(model: EditorModel) {
        self.model = model
        let defaults = model.library.defaults
        pairRule = defaults?.string(forKey: Self.pairRuleKey).flatMap(PairRule.init(rawValue:)) ?? .keepBoth
        expanded = defaults?.stringArray(forKey: Self.expandedKey).map { Set($0.compactMap(Panel.init(rawValue:))) }
            ?? Set(Panel.allCases)
        collapsedSets = Set(defaults?.stringArray(forKey: Self.collapsedSetsKey) ?? [])
        model.library.leavingSource = { [weak model] source in model?.rememberView(of: source) }
    }

    /// Whether the set at `path` shows what's inside it in the collection list.
    public func isOpen(_ path: CollectionPath) -> Bool {
        !collapsedSets.contains(path.text)
    }

    /// Opens or closes the set at `path` in the collection list, kept between launches.
    public func setOpen(_ path: CollectionPath, _ open: Bool) {
        guard open == collapsedSets.contains(path.text) else { return }
        if open {
            collapsedSets.remove(path.text)
        } else {
            collapsedSets.insert(path.text)
        }
        model?.library.defaults?.set(collapsedSets.sorted(), forKey: Self.collapsedSetsKey)
    }

    public func isExpanded(_ panel: Panel) -> Bool {
        expanded.contains(panel)
    }

    /// Opens or closes `panel`; with `solo`, it alone stays open, as Option-click does in Develop.
    public func toggle(_ panel: Panel, solo: Bool = false) {
        if solo {
            expanded = expanded == [panel] ? [] : [panel]
        } else if expanded.contains(panel) {
            expanded.remove(panel)
        } else {
            expanded.insert(panel)
        }
        model?.library.defaults?.set(expanded.map(\.rawValue).sorted(), forKey: Self.expandedKey)
    }

    // MARK: - Following the library

    /// Counts the library and keeps counting it as it changes, from now on, while Library is shown: while a
    /// section's list is in the window. Each call is matched by a call to `stopFollowing`.
    public func follow() {
        followers += 1
        guard following == nil, model != nil else { return }
        following = Following()
        followShown()
        let tracker = Tracker { [weak self] in
            guard let self, let model else { return }
            if model.module != menusModule {
                menusModule = model.module
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { ModuleMenuKeys.refresh() }
                }
            }
            if model.module == .library, model.library.service?.state == .ready {
                startCounting()
            } else {
                pauseCounting()
            }
        }
        following?.tracker = tracker
    }

    /// Stops counting once every section's list has left the window. A source shown stays current.
    public func stopFollowing() {
        followers = max(followers - 1, 0)
        guard followers == 0, let following else { return }
        following.tracker?.cancel()
        pauseCounting()
        self.following = nil
        isCounted = false
    }

    /// Follows every photo, and the definitions' folder, for the counts; counts once now.
    private func startCounting() {
        guard let core = model?.library.service?.core, following != nil, following?.photos == nil else { return }
        let photos = core.live.open(.allPhotographs, sort: QuerySort(.captured))
        following?.photos = photos
        following?.listening = Task.detached(priority: .utility) { [weak self] in
            for await _ in photos {
                await self?.recount()
            }
        }
        following?.definitions = Self.watch(core.paths.definitions) { [weak self] in self?.recount() }
        recount()
    }

    /// Stops following the library for the counts, in Develop, until Library is shown again.
    private func pauseCounting() {
        following?.photos?.close()
        following?.listening?.cancel()
        following?.definitions?.cancel()
        following?.photos = nil
        following?.listening = nil
        following?.definitions = nil
    }

    /// Calls `changed` on the main thread whenever the folder at `url` gains, loses or replaces a file.
    private static func watch(
        _ url: URL, changed: @escaping @MainActor @Sendable () -> Void,
    ) -> (any DispatchSourceFileSystemObject)? {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .link], queue: .main,
        )
        source.setEventHandler { MainActor.assumeIsolated { changed() } }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        return source
    }

    /// Counts again off the main thread, once the count under way is in, at most once every `countingInterval`.
    @_spi(Harness) public func recount() {
        guard let core = model?.library.service?.core else { return }
        guard !counting else {
            countAgain = true
            return
        }
        counting = true
        let (rule, kept) = (pairRule, previous)
        let started = ContinuousClock.now
        Task { [weak self] in
            let read = await Task.detached(priority: .utility) { () -> (LibraryCounts, ([String], PreviousImport?))? in
                await core.live.settle()
                let journal = ImportJournal(paths: core.paths)
                let stamp = Self.stamp(of: journal.folder)
                let previous = if let kept, kept.stamp == stamp {
                    kept.found
                } else {
                    try? journal.previousImport()
                }
                guard let counts = try? await LibraryCounts.read(core: core, pairs: rule, previous: previous) else {
                    return nil
                }
                return (counts, (stamp, previous))
            }.value
            guard let self else { return }
            if let (counts, previous) = read {
                self.previous = previous
                apply(counts)
                countsTook = countsTook.suffix(999) + [.now - started]
            }
            guard countAgain else {
                counting = false
                return
            }
            countAgain = false
            try? await Task.sleep(for: max(Self.countingInterval - (.now - started), .zero))
            counting = false
            recount()
        }
    }

    /// The journal's files with their sizes and dates: the previous import is read again only when they change.
    private nonisolated static func stamp(of folder: URL) -> [String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.map { file in
            let values = try? file.resourceValues(forKeys: Set(keys))
            return "\(file.lastPathComponent) \(values?.fileSize ?? 0) "
                + "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.sorted()
    }

    private func apply(_ read: LibraryCounts) {
        let before = counts
        counts = read
        isCounted = true
        followNewestImport()
        model?.healthProposals.confirmDuplicates(unconfirmed: read.unconfirmedDuplicates)
        if !read.hasSameRows(as: before) {
            rows += 1
            return
        }
        let changed = read.changed(from: before)
        guard !changed.isEmpty else { return }
        for observer in observers.values {
            observer(changed)
        }
    }

    /// Calls `handler` with the sources whose counts changed while the rows stayed the same.
    func observeCounts(_ handler: @escaping @MainActor (Set<LibrarySource>) -> Void) -> LibraryObservation {
        let id = UUID()
        observers[id] = handler
        return LibraryObservation { [weak self] in self?.observers.removeValue(forKey: id) }
    }

    /// Returns once the counts asked for so far are in.
    @_spi(Harness) public func counted() async {
        while counting {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - What the panels show

    /// The photos `source` holds; nil for a set, and for an entry that isn't offered.
    public func count(of source: LibrarySource) -> Int? {
        counts.count(of: source)
    }

    /// The Library section's entries offered, in its order.
    public var libraryEntries: [LibrarySource] {
        LibrarySource.library.filter { counts.entries[$0] != nil }
    }

    /// Library Health's checks offered, in its order.
    public var healthEntries: [LibrarySource] {
        LibrarySource.healthChecks.filter { counts.entries[$0] != nil }
    }

    /// The collection list's places, by path.
    public var collections: [CollectionPath: CollectionList.Collection] {
        counts.collections
    }

    /// The places at the top of the collection list, or inside `set`, in the Finder's order of names.
    public func collections(inside set: CollectionPath?) -> [CollectionList.Collection] {
        counts.collections.values.filter { $0.path.parent == set }
            .sorted { FileOrder.precedes($0.path.name, $1.path.name) }
    }

    /// Every set, top level first, each before the sets inside it.
    public var sets: [CollectionPath] {
        counts.collections.values.filter { $0.kind == .set }.map(\.path).sorted { lhs, rhs in
            for (left, right) in zip(lhs.names, rhs.names) where left != right {
                return FileOrder.precedes(left, right)
            }
            return lhs.names.count < rhs.names.count
        }
    }

    /// The collection Add to Target Collection puts photos in; nil for the quick collection, Marked.
    public var target: CollectionPath? {
        counts.target
    }

    /// Chooses the rule for raw and JPEG pairs, kept between launches, and counts again.
    public func setPairRule(_ rule: PairRule) {
        guard rule != pairRule else { return }
        pairRule = rule
        model?.library.defaults?.set(rule.rawValue, forKey: Self.pairRuleKey)
        if shown == .health(.pairs) {
            show(.health(.pairs))
        }
        recount()
    }

    // MARK: - Showing a source

    /// Whether `show` would show `source`: the library is open, and once it's counted, `source` holds photos.
    public func canShow(_ source: LibrarySource) -> Bool {
        guard model?.library.service?.isReady == true else { return false }
        guard isCounted else { return true }
        if case let .collection(path) = source {
            return counts.collections[path] != nil
        }
        return counts.entries[source] != nil
    }

    /// Shows `source` in the grid and the filmstrip in place of the open folder, Library shown once its photos are
    /// in; false while the library isn't open, and for Previous Import while there's none.
    @discardableResult
    public func show(_ source: LibrarySource) -> Bool {
        guard let model, model.library.service?.core != nil, model.library.service?.isReady == true else {
            return false
        }
        guard let listed = photos(of: source) else {
            guard source == .previousImport, previous == nil else { return false }
            // Not counted yet: shown once it is, if there's a previous import.
            recount()
            Task { [weak self] in
                await self?.counted()
                guard let self, previous != nil else { return }
                show(.previousImport)
            }
            return true
        }
        model.rememberSourceView()
        model.stackSuggestions = []
        followShown()
        close()
        let (generation, list) = model.library.openSource(
            source, photos: listed, wanted: model.libraryViews.keptPhotos(of: source.key),
        ) { [weak self] in
            self?.received($0, generation: $1)
        }
        self.generation = generation
        shown = source
        awaitingFirst = true
        self.list = list
        if source == .previousImport, let found = previous?.found {
            shownImport = (found.id, Set(counts.previousImport))
        }
        return true
    }

    /// Previous Import, shown, shows the newest import's photos once the library is counted again, with `photos`
    /// selected: as an import finishes while it's shown, as Lightroom Classic's Previous Import does.
    func showNewestImport(selecting photos: [URL]) {
        importSelection = photos
        recount()
    }

    /// Previous Import, shown, shows the newest import once a count finds one newer than it shows, or photos of it
    /// the library hadn't indexed yet.
    private func followNewestImport() {
        guard shown == .previousImport, let found = previous?.found, !counts.previousImport.isEmpty else { return }
        if let shownImport, shownImport.id == found.id, Set(counts.previousImport).isSubset(of: shownImport.photos) {
            return
        }
        let selection = importSelection
        importSelection = nil
        guard show(.previousImport), let model, let selection, let active = selection.first else { return }
        model.libraryViews.remember(LibrarySource.previousImport.key, selection: selection, active: active)
    }

    /// `source`'s photos as the library lists them: for Previous Import, its own, which its folders may hold others
    /// beside; nil for Previous Import while it isn't known.
    func photos(of source: LibrarySource) -> PhotoSource? {
        guard source == .previousImport else { return source.photoSource(pairs: pairRule) }
        guard previous?.found != nil, !counts.previousImport.isEmpty else { return nil }
        return .photos(Set(counts.previousImport))
    }

    /// Shows `source`'s summary beside `view`: its days, cameras, lenses, settings, pairs and stacks.
    public func showSummary(of source: LibrarySource, relativeTo view: NSView) {
        guard let service = model?.library.service, let listed = photos(of: source) else { return }
        let title = if case let .collection(path) = source {
            path.displayName
        } else {
            source.title
        }
        SourceSummaryPopover.show(title, relativeTo: view) { await service.summary(of: listed) }
    }

    private func received(_ change: LibrarySourceList.Change, generation: Int) {
        guard let model, generation == self.generation, model.library.showSource(change, generation: generation)
        else { return }
        model.healthProposals.follow(shown)
        if awaitingFirst, let shown {
            awaitingFirst = false
            // Only after the photos are in: a filmstrip out of sight doesn't take them, and one placing itself
            // as it goes out of sight would look for a photo it doesn't have.
            model.showModule(.library)
            // A large source's first change brings these rows (`LibrarySourceList.firstRead`).
            let items = model.library.items
            model.didList(shown, items.indices.prefix(Self.warmedAsShown).compactMap(items.row))
        }
    }

    /// The photos a source warms the thumbnails of as it's shown, its first screens; the grid and the filmstrip
    /// load the others' as they come into view. Asking the store for ten thousand at once holds the main thread
    /// for milliseconds.
    static let warmedAsShown = 1000

    /// Ends the source shown when another opening replaces it: a folder, Recently Trashed, or another source.
    private func followShown() {
        guard libraryObservation == nil, let library = model?.library else { return }
        libraryObservation = library.observe { [weak self] diff in
            guard diff.reset, let self, let generation, !library.showsSource(generation) else { return }
            close()
        }
    }

    private func close() {
        list?.close()
        list = nil
        generation = nil
        shown = nil
        shownImport = nil
        awaitingFirst = false
        model?.healthProposals.follow(nil)
    }

    /// Whether the photos of the source shown have all arrived.
    @_spi(Harness) public var isListing: Bool {
        awaitingFirst
    }

    /// The index's ID of the photo at `url`, while it's one of the source shown's.
    func indexID(ofShown url: URL) -> Int64? {
        model?.library.sourcePhotoID(of: url)
    }

    /// The index's IDs of `photos`, from the source shown when they're among its photos, else from the index.
    func indexIDs(of photos: [URL]) async -> [Int64] {
        let known = photos.compactMap(indexID(ofShown:))
        if known.count == photos.count {
            return known
        }
        guard let index = model?.library.service?.core?.index else { return [] }
        let found = await LibraryService.indexIDs(of: photos, in: index)
        return photos.compactMap { found[$0] }
    }
}
