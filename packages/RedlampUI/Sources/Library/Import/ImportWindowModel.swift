import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

/// The import window's state (LIB-27), which the window and the tests drive alike.
///
/// - **From:** the cards on this Mac as they come and go (`ImportCards`), and the folders added, each
///   browsed in an `ImportSession` of its own from its embedded previews before anything is copied, and
///   each counted, the photos the library has already apart: they're left out. Several go at once.
/// - **The photos:** the source shown, newest first, listed at once and filled in as their heads and
///   previews are read. The choices (which go, the rating, flag and label each gets) are kept in its
///   session, and written in each photo's `.redlamp` at the destination.
///
/// Events from the sessions reach the main thread in batches.
@MainActor
final class ImportWindowModel {
    /// A card or a folder in From.
    struct Source: Identifiable {
        let source: ImportSource
        let session: ImportSession
        /// Its photos go in the import.
        var isIncluded = true
        /// Its photos, newest first by their files' dates, once it's listed.
        var photos: [String] = []
        var isListed = false
        /// Photos the library has already: counted apart and left out.
        var imported = 0
        /// Photos whose first bytes couldn't be read.
        var unreadable = 0
        var isBrowsed = false
        /// Why it can't be imported from: it couldn't be listed, or its card was taken out.
        var problem: String?

        var id: String {
            source.id
        }

        var isCard: Bool {
            source.kind == .card
        }
    }

    enum Phase: Equatable {
        /// Browsing and choosing: nothing is being copied.
        case choosing
        case planning
        case copying
        /// The import is over, or stopped; `outcome` says what it did.
        case finished
    }

    /// What the window shows that changed.
    enum Change: Equatable {
        case sources
        /// Photos shown: every one when `ids` is nil.
        case photos(ids: Set<String>?)
        /// The settings, the example and the templates' errors.
        case settings
        /// The summary, the phase and the progress.
        case status
    }

    let library: ImportLibrary
    let preferences: ImportPreferences
    let cards: ImportCards
    let fileSystem: any LibraryFileSystem
    let destinationFileSystem: any LibraryFileSystem
    /// Readers shared by every session, so a volume is read by one set of them.
    let volumes: VolumeIORegistry
    var onChange: ((Change) -> Void)?

    var sources: [Source] = []
    /// The source whose photos are shown.
    private(set) var shown: String?
    /// The shown source's photos, in its listing's order.
    private(set) var photos: [ImportPhoto] = []
    private var positions: [String: Int] = [:]

    /// The import.
    var phase = Phase.choosing

    private var browsing: [String: Task<Void, Never>] = [:]
    private var counted: (photos: Int, bytes: Int64)?
    private var countsDue = false
    private var cardsObservation: LibraryObservation?
    /// Previews made while browsing go to the library's store; without a library, to one of the window's own,
    /// removed as it closes.
    private let ownStore: (store: PhotoStore, root: URL)?

    /// How long events wait to reach the main thread, so a card read fast costs it a turn a batch.
    static let batching = Duration.milliseconds(30)
    /// How often the counts browsing changes reach the window.
    static let countsInterval = Duration.milliseconds(250)

    init(
        library: ImportLibrary, preferences: ImportPreferences = .shared, cards: ImportCards = .shared,
        fileSystem: any LibraryFileSystem = LocalFileSystem(),
        destinationFileSystem: any LibraryFileSystem = LocalFileSystem(),
    ) {
        if library.store == nil {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "Redlamp Import Previews \(UUID().uuidString)", directoryHint: .isDirectory)
            let store = PhotoStore(root: root)
            ownStore = (store, root)
            self.library = ImportLibrary(
                paths: library.paths, index: library.index, store: store, indexer: library.indexer,
                live: library.live,
            )
        } else {
            ownStore = nil
            self.library = library
        }
        self.preferences = preferences
        self.cards = cards
        self.fileSystem = fileSystem
        self.destinationFileSystem = destinationFileSystem
        volumes = VolumeIORegistry(fileSystem: fileSystem)
    }

    /// Lists the cards in and follows them.
    func start() {
        cardsObservation = cards.observe { [weak self] cards in self?.cardsChanged(cards) }
        cardsChanged(cards.cards)
    }

    /// Stops browsing and lets the sessions go.
    func close() {
        cardsObservation?.invalidate()
        cardsObservation = nil
        for task in browsing.values {
            task.cancel()
        }
        browsing = [:]
        for source in sources {
            source.session.close()
        }
        if let (store, root) = ownStore {
            Task.detached(priority: .utility) {
                store.close()
                try? FileManager.default.removeItem(at: root)
            }
        }
    }

    /// Returns once every source is browsed: listed, and each photo read and previewed.
    func browsed() async {
        for task in browsing.values {
            await task.value
        }
    }

    // MARK: - Sources

    /// Adds `source` to From and starts browsing it; a source already there is left as it is.
    func add(_ source: ImportSource) {
        guard !sources.contains(where: { $0.id == source.id }) else { return }
        let session = ImportSession(
            sources: [source], library: library, fileSystem: fileSystem, volumes: volumes,
            makesPreviews: library.store != nil,
        )
        sources.append(Source(source: source, session: session))
        browse(session, id: source.id)
        if shown == nil {
            show(source.id)
        }
        notify(.sources)
        notify(.status)
    }

    /// Add Folder…: the folder at `url`, and every folder below it, as a source.
    func addFolder(_ url: URL) async throws {
        let fileSystem = fileSystem
        let source = try await Task.detached(priority: .userInitiated) {
            try ImportSource.at(url, fileSystem: fileSystem)
        }.value
        add(source)
        show(source.id)
    }

    /// Takes the source out of From: its photos aren't imported, and its choices go.
    func remove(_ id: String) {
        guard phase != .copying, phase != .planning, let index = sources.firstIndex(where: { $0.id == id }) else {
            return
        }
        browsing.removeValue(forKey: id)?.cancel()
        sources.remove(at: index).session.close()
        if shown == id {
            shown = nil
            show(sources.first?.id)
        }
        notify(.sources)
        notify(.status)
    }

    func setIncluded(_ id: String, _ included: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }), sources[index].isIncluded != included else {
            return
        }
        sources[index].isIncluded = included
        notify(.sources)
        notify(.status)
    }

    /// Shows `id`'s photos.
    func show(_ id: String?) {
        guard shown != id || id == nil else { return }
        shown = id
        loadShownPhotos()
    }

    func source(_ id: String) -> Source? {
        sources.first { $0.id == id }
    }

    private func cardsChanged(_ cards: [ImportSource]) {
        let busy = phase == .copying || phase == .planning
        for card in cards {
            if let index = sources.firstIndex(where: { $0.id == card.id }) {
                // A card taken out and put back is browsed afresh.
                guard sources[index].problem != nil, !busy else { continue }
                remove(card.id)
            }
            add(card)
        }
        let present = Set(cards.map(\.id))
        for index in sources.indices where sources[index].isCard && !present.contains(sources[index].id) {
            guard sources[index].problem == nil else { continue }
            sources[index].problem = "The card was taken out."
            sources[index].isIncluded = false
            browsing.removeValue(forKey: sources[index].id)?.cancel()
        }
        notify(.sources)
        notify(.status)
    }

    // MARK: - Browsing

    private func browse(_ session: ImportSession, id: String) {
        let buffer = ImportEventBuffer()
        let batching = Self.batching
        browsing[id] = Task.detached(priority: .userInitiated) { [weak self] in
            for await event in session.browse() {
                if buffer.append(event) {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: batching)
                        self?.received(buffer.take(), from: id)
                    }
                }
            }
            await self?.received(buffer.take(), from: id)
        }
    }

    private func received(_ events: [ImportEvent], from id: String) {
        guard !events.isEmpty, let index = sources.firstIndex(where: { $0.id == id }) else { return }
        counted = nil
        var changed = Set<String>()
        var listed = false
        for event in events {
            switch event {
            case let .listed(_, photos):
                sources[index].photos = photos
                sources[index].isListed = true
                listed = true
            case let .read(ids), let .previewed(ids):
                changed.formUnion(ids)
            case let .imported(ids):
                sources[index].imported += ids.count
                changed.formUnion(ids)
            case let .failed(photo, _):
                sources[index].unreadable += 1
                changed.insert(photo)
            case let .sourceFailed(_, message):
                sources[index].problem = sources[index].problem ?? message
            case .browsed:
                sources[index].isBrowsed = true
            }
        }
        if shown == id {
            if listed {
                loadShownPhotos()
            } else {
                refresh(changed)
            }
        }
        countsChanged()
    }

    /// Tells the window its counts changed, at most every `countsInterval`: browsing changes them a batch
    /// at a time.
    private func countsChanged() {
        guard !countsDue else { return }
        countsDue = true
        let interval = Self.countsInterval
        Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard let self else { return }
            countsDue = false
            notify(.sources)
            notify(.status)
        }
    }

    private func loadShownPhotos() {
        let session = shown.flatMap(source)?.session
        let ids = shown.flatMap(source)?.photos ?? []
        photos = session.map { session in ids.compactMap(session.photo) } ?? []
        positions = Dictionary(photos.enumerated().map { ($1.id, $0) }) { first, _ in first }
        notify(.photos(ids: nil))
    }

    /// Takes `ids`' photos again from their session.
    private func refresh(_ ids: Set<String>) {
        guard let session = shown.flatMap(source)?.session, !ids.isEmpty else { return }
        var shownChanged = Set<String>()
        for id in ids {
            if let place = positions[id], let photo = session.photo(id) {
                photos[place] = photo
                shownChanged.insert(id)
            }
        }
        if !shownChanged.isEmpty {
            notify(.photos(ids: shownChanged))
        }
    }

    /// Reads these photos first: the cells on screen.
    func prioritise(_ ids: [String]) {
        shown.flatMap(source)?.session.prioritise(ids)
    }

    func photo(at index: Int) -> ImportPhoto? {
        photos.indices.contains(index) ? photos[index] : nil
    }

    func index(of id: String) -> Int? {
        positions[id]
    }

    /// The photo's files are all in the library already: it's left out.
    func isLeftOut(_ photo: ImportPhoto) -> Bool {
        photo.isImported
    }

    // MARK: - Choices

    /// Which photos go: those left out can't be chosen.
    func choose(_ ids: [String], _ chosen: Bool) {
        let choosable = ids.filter { id in photo(id: id).map { !isLeftOut($0) } ?? false }
        change(choosable) { $0.choose($1, chosen) }
    }

    /// Space, or a click on a cell's box: chooses them all, unless they all are already.
    func toggleChosen(_ ids: [String]) {
        let all = ids.compactMap(photo(id:)).filter { !isLeftOut($0) }.allSatisfy(\.choices.isChosen)
        choose(ids, !all)
    }

    /// 0 to 5.
    func rate(_ ids: [String], _ stars: Int) {
        change(ids) { $0.rate($1, stars) }
    }

    func flag(_ ids: [String], _ flag: PhotoFlag?) {
        change(ids) { $0.flag($1, flag) }
    }

    func label(_ ids: [String], _ label: ColorLabel?) {
        change(ids) { $0.label($1, label) }
    }

    func photo(id: String) -> ImportPhoto? {
        positions[id].map { photos[$0] } ?? sources.lazy.compactMap { $0.session.photo(id) }.first
    }

    private func change(_ ids: [String], _ body: (ImportSession, [String]) -> Void) {
        guard phase != .copying, phase != .planning, !ids.isEmpty else { return }
        for source in sources {
            let mine = ids.filter { source.session.photo($0) != nil }
            if !mine.isEmpty {
                body(source.session, mine)
            }
        }
        refresh(Set(ids))
        notify(.status)
    }

    // MARK: - Counts

    /// Photos chosen from the sources included, those the library has left out, and their bytes, as raw
    /// only counts them; counted once between changes.
    var chosen: (photos: Int, bytes: Int64) {
        if let counted {
            return counted
        }
        var count = 0
        var bytes: Int64 = 0
        let rawOnly = preferences.settings.rawOnly
        for source in sources where source.isIncluded && source.problem == nil {
            for id in source.photos {
                guard let photo = source.session.photo(id), photo.choices.isChosen, !isLeftOut(photo) else { continue }
                let files = photo.photoFiles.filter { !rawOnly || $0.isRaw }
                guard !files.isEmpty else { continue }
                count += 1
                bytes += files.reduce(0) { $0 + $1.size }
            }
        }
        counted = (count, bytes)
        return (count, bytes)
    }

    /// The photos the library has already, of the sources included.
    var alreadyImported: Int {
        sources.filter(\.isIncluded).reduce(0) { $0 + $1.imported }
    }

    // MARK: - What the window says

    /// The line under the photos: what's chosen, and what's left out.
    var summary: String {
        let (photos, bytes) = chosen
        var text = "\(Self.count(photos, "photo")) chosen, \(ImportFormat.size(bytes))"
        let imported = alreadyImported
        if imported > 0 {
            text += "; \(Self.count(imported, "photo")) already in the library, left out"
        }
        return text + "."
    }

    /// What a source's row says under its name.
    func detail(of source: Source) -> String {
        if let problem = source.problem {
            return problem
        }
        guard source.isListed else { return "Listing…" }
        var text = Self.count(source.photos.count, "photo")
        if source.imported > 0 {
            text += ", \(source.imported) already in the library"
        }
        if source.unreadable > 0 {
            text += ", \(source.unreadable) unreadable"
        }
        return text
    }

    static func count(_ value: Int, _ noun: String) -> String {
        "\(value.formatted()) \(noun)\(value == 1 ? "" : "s")"
    }

    func notify(_ change: Change) {
        if change != .settings {
            counted = nil
        }
        onChange?(change)
    }
}

/// Sizes as the window writes them.
enum ImportFormat {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Events gathered off the main thread and taken in batches.
final class ImportEventBuffer: Sendable {
    private let state = Mutex<(events: [ImportEvent], waiting: Bool)>(([], false))

    /// Adds `event`; true when no batch waits to be taken yet, so one is to be.
    func append(_ event: ImportEvent) -> Bool {
        state.withLock { state in
            state.events.append(event)
            defer { state.waiting = true }
            return !state.waiting
        }
    }

    func take() -> [ImportEvent] {
        state.withLock { state in
            defer { state = ([], false) }
            return state.events
        }
    }
}
