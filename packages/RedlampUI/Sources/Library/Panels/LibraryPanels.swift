import Foundation
import Observation
import RedlampDesign
import RedlampDocument
import RedlampLibrary
import Synchronization

/// What the Library's panels show of the photos selected (LIB-21, LIB-22).
public struct PanelSelection: Sendable, Equatable {
    /// The photos selected, or the active photo alone when nothing else is.
    public var count = 0
    /// Those the library has, by their IDs in its index, in order.
    public var ids: [Int64] = []
    /// The active photo's ID, when the library has it.
    public var activeID: Int64?
    /// How many of them have each keyword.
    public var keywords: [KeywordPath: Int] = [:]
    public var fields = SelectionFields()
    /// The photos are shown from the library, which the panels need: until then they offer nothing.
    public var isAvailable = false

    public init() {}

    /// The keywords every photo has, then those only some have, each in the keyword list's order.
    public var orderedKeywords: [(path: KeywordPath, count: Int)] {
        keywords.filter { $0.value > 0 }.sorted { lhs, rhs in
            let (left, right) = (lhs.value >= ids.count, rhs.value >= ids.count)
            if left != right {
                return left
            }
            return lhs.key.names.lexicographicallyPrecedes(rhs.key.names) {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
        }.map { ($0.key, $0.value) }
    }

    /// Whether every photo has `keyword`; nil when only some do.
    public func hasEverywhere(_ keyword: KeywordPath) -> Bool? {
        let count = keywords[keyword] ?? 0
        return count == 0 ? false : count >= ids.count ? true : nil
    }
}

/// A change being made, and how far it has got.
public struct PanelProgress: Sendable, Equatable {
    public var title: String
    public var done: Int
    public var total: Int
}

/// The Library module's right-hand panels (LIB-13, LIB-21, LIB-22): Photo, Keywording, Keyword List and
/// Metadata, each collapsible, which are open kept between launches; and what they show of the photos
/// selected, worked out off the main thread from the query engine's keywords and column store each time
/// the selection or its photos change, one read at a time, the latest winning.
///
/// Their changes are the library's batches (`LibraryKeywords`, `LibraryMetadata`), made one after another
/// off the main thread, each on Library's Undo with culling's changes, in the order they were made
/// (`LibraryPanels+Changes`).
@MainActor
@Observable
public final class LibraryPanels {
    public enum Panel: String, CaseIterable, Sendable {
        case photo, keywording, keywordList, metadata

        public var title: String {
            switch self {
            case .photo: "Photo"
            case .keywording: "Keywording"
            case .keywordList: "Keyword List"
            case .metadata: "Metadata"
            }
        }

        public var symbol: String {
            switch self {
            case .photo: "info.circle"
            case .keywording: "tag"
            case .keywordList: "list.bullet.indent"
            case .metadata: "text.document"
            }
        }
    }

    static let expandedKey = "library.panels.expanded"

    @ObservationIgnored weak var model: EditorModel?
    @ObservationIgnored private let defaults: UserDefaults?
    /// The panels open, as last left.
    public private(set) var expanded: Set<Panel>
    public internal(set) var selection = PanelSelection()
    /// The keyword list with its counts, completion over it and the keyword sets, once read.
    var keywords: PanelKeywords?
    public internal(set) var presets: [MetadataPreset] = []
    /// The library's code replacements as their file is written, and their codes, which the fields typed and
    /// the presets applied expand.
    public internal(set) var codeReplacementsText = ""
    public internal(set) var codes = CodeReplacements()
    public internal(set) var progress: PanelProgress?
    /// What went wrong with the last change, in words, until the next one.
    public internal(set) var problem: String?
    /// The panels' changes, newest last, for Undo; and those Undo took back, for Redo.
    var undoSteps: [PanelStep] = []
    var redoSteps: [PanelStep] = []
    /// What the changes in flight show before the library has them, oldest first: each until its own batch
    /// is made, as one finishing while those after it wait would otherwise show them undone.
    @ObservationIgnored var overlays: [(step: PanelStep, overlay: PanelOverlay)] = []
    @ObservationIgnored let photoIDs = PanelPhotoIDs()
    @ObservationIgnored var tail: Task<Void, Never>?
    @ObservationIgnored private var tracker: Tracker?
    @ObservationIgnored private var observation: LibraryObservation?
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var readAgain = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var keywordsReading: Task<Void, Never>?
    @ObservationIgnored private var keywordsStale = false
    @ObservationIgnored private var presetsRead = false
    @ObservationIgnored private var changedAt: ContinuousClock.Instant?
    /// How long each selection change took to reach the panels, for the budgets (`--library-perf`).
    @ObservationIgnored @_spi(Harness) public private(set) var followed: [Duration] = []

    init(model: EditorModel) {
        self.model = model
        defaults = model.library.defaults
        let saved = defaults?.stringArray(forKey: Self.expandedKey)
        expanded = saved.map { Set($0.compactMap(Panel.init(rawValue:))) } ?? Set(Panel.allCases)
    }

    // MARK: - The panels

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
        defaults?.set(expanded.map(\.rawValue).sorted(), forKey: Self.expandedKey)
        if panel == .keywordList || panel == .keywording, expanded.contains(panel), keywords == nil {
            refreshKeywords()
        }
    }

    // MARK: - Following the selection

    /// Follows the selection, its photos and the library, from now on: when the panels are first shown.
    public func follow() {
        guard tracker == nil, let model else { return }
        observation = model.library.observe { [weak self] diff in
            if diff.reset || !diff.inserted.isEmpty || !diff.removed.isEmpty {
                self?.photoIDs.forget()
            }
        }
        tracker = Tracker { [weak self] in
            guard let self, let model = self.model else { return }
            _ = model.photoSelection
            _ = model.selection
            _ = model.library.revision
            _ = model.module
            _ = model.library.service?.state
            selectionChanged()
        }
    }

    private func selectionChanged() {
        guard let model, model.module == .library else { return }
        if changedAt == nil {
            changedAt = .now
        }
        refresh()
        if keywords == nil || keywordsStale {
            refreshKeywords()
        }
        if !presetsRead, model.library.service?.isReady == true {
            refreshPresets()
        }
    }

    /// Reads what the panels show of the photos selected, off the main thread, once the read under way is
    /// done; that one, made of an older selection, isn't shown.
    func refresh() {
        generation += 1
        guard reading == nil else {
            readAgain = true
            return
        }
        let generation = generation
        guard let model, let service = model.library.service, service.isReady, let core = service.core,
              model.library.isShownFromLibrary
        else {
            var empty = PanelSelection()
            empty.count = model
                .map { $0.photoSelection.isEmpty ? ($0.selection == nil ? 0 : 1) : $0.photoSelection.count }
                ?? 0
            selection = empty
            changedAt = nil
            return
        }
        let library = model.library
        let snapshot = SelectionSnapshot(
            selection: model.photoSelection, list: library.photoList, items: library.items,
            active: model.selection.flatMap(library.index(of:)),
        )
        let ids = photoIDs
        reading = Task { [weak self] in
            let read = await Task.detached(priority: .userInitiated) {
                await Self.read(snapshot, core: core, ids: ids)
            }.value
            guard let self else { return }
            reading = nil
            if generation == self.generation {
                show(read)
            }
            if readAgain {
                readAgain = false
                refresh()
            }
        }
    }

    /// Returns once the reads asked for so far are shown.
    @_spi(Harness) public func refreshed() async {
        while let reading {
            await reading.value
        }
    }

    private func show(_ read: PanelSelection) {
        var shown = read
        for (_, overlay) in overlays {
            overlay.apply(to: &shown)
        }
        if shown != selection {
            selection = shown
        }
        if let changedAt {
            followed.append(.now - changedAt)
            self.changedAt = nil
        }
    }

    /// The photos selected, their IDs in the index, how many have each keyword and what they share of
    /// IPTC Core's fields: a pass over the list's selection, then the engine's keywords and store.
    private nonisolated static func read(
        _ snapshot: SelectionSnapshot, core: LibraryCore, ids: PanelPhotoIDs,
    ) async -> PanelSelection {
        var photos: [(list: Int64, url: URL)] = []
        let list = snapshot.list
        let active = snapshot.active.flatMap { list.indices.contains($0) ? list[$0] : nil }
        if snapshot.selection.isEmpty {
            if let active = snapshot.active, list.indices.contains(active), snapshot.items.indices.contains(active) {
                photos = [(list[active], snapshot.items[active].url)]
            }
        } else {
            photos.reserveCapacity(snapshot.selection.count)
            for place in list.indices where snapshot.items.indices.contains(place)
                && snapshot.selection.contains(list[place]) {
                photos.append((list[place], snapshot.items[place].url))
            }
        }
        var read = PanelSelection()
        read.count = photos.count
        read.isAvailable = true
        let found = await ids.ids(of: photos, in: core.index)
        read.ids = found.values.sorted()
        read.activeID = active.flatMap { found[$0] }
        guard !read.ids.isEmpty, !Task.isCancelled else { return read }
        let photoIDs = read.ids
        async let keywords = try? core.engine.keywordCounts(ofPhotos: photoIDs)
        if let store = core.engine.store {
            let metadata = LibraryMetadata(index: core.index, paths: core.paths)
            read.fields = await (try? metadata.fields(ofPhotos: photoIDs, in: store)) ?? SelectionFields()
        }
        read.keywords = await keywords ?? [:]
        return read
    }

    // MARK: - The keyword list and presets

    /// Reads the keyword list, its completion and the keyword sets again, once the read under way is done.
    @_spi(Harness) public func refreshKeywords() {
        guard let service = model?.library.service, service.isReady else {
            keywordsStale = true
            return
        }
        guard keywordsReading == nil else {
            keywordsStale = true
            return
        }
        keywordsStale = false
        keywordsReading = Task { [weak self] in
            let read = await service.panelKeywords()
            guard let self else { return }
            keywordsReading = nil
            if let read {
                keywords = read
            }
            if keywordsStale {
                refreshKeywords()
            }
        }
    }

    /// Returns once the keyword list read under way is shown.
    @_spi(Harness) public func keywordsRead() async {
        while let keywordsReading {
            await keywordsReading.value
        }
    }

    func refreshPresets() {
        guard let service = model?.library.service, service.isReady else { return }
        presetsRead = true
        Task { [weak self] in
            let presets = await service.metadataPresets()
            let codes = await service.codeReplacementsText()
            self?.presets = presets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self?.showCodeReplacements(codes)
        }
    }

    func showCodeReplacements(_ text: String) {
        codeReplacementsText = text
        codes = CodeReplacements(text: text)
    }

    /// The keyword list, once read.
    public var keywordList: KeywordList? {
        keywords?.list
    }

    /// The keyword sets: Recent Keywords, then the user's (or Redlamp's, until there are any).
    public var keywordSets: [KeywordSet] {
        keywords?.sets ?? []
    }

    /// The set ⌥1 to ⌥9 apply.
    public var activeSet: KeywordSet? {
        keywords?.active
    }

    /// The keywords `text` completes to, best first.
    public func completions(_ text: String, limit: Int = 8) -> [KeywordCompletion.Match] {
        let term = text.split(separator: ",", omittingEmptySubsequences: false).last.map(String.init) ?? text
        return keywords?.completion.matches(term.trimmingCharacters(in: .whitespaces), limit: limit) ?? []
    }
}

/// What a read of the selection starts from, taken on the main thread: the list's selection, its photos and
/// their places, each a copy that costs nothing until either side changes.
struct SelectionSnapshot: Sendable {
    let selection: PhotoSelection
    let list: PhotoList
    let items: [LibraryItem]
    /// The active photo's place in the list.
    let active: Int?
}

/// What a change shows before the library has it: the keywords added and taken off, and the fields given, to
/// the photos it was made on.
struct PanelOverlay {
    let ids: [Int64]
    var adding: [KeywordPath] = []
    var removing: [KeywordPath] = []
    var fields: [MetadataPreset.Field: SharedValue] = [:]

    func apply(to selection: inout PanelSelection) {
        guard selection.ids == ids else { return }
        for keyword in adding {
            selection.keywords[keyword] = ids.count
        }
        for keyword in removing {
            selection.keywords[keyword] = nil
        }
        for (field, value) in fields {
            selection.fields.values[field] = value
        }
    }
}
