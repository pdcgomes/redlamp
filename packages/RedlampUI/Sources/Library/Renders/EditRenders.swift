import Foundation
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary

/// Thumbnails and previews that show the edit (LIB-17). An edited photo the library shows is rendered
/// with its edit by Redlamp's own engine, in an engine of the library's own (`makeEngine`), at the
/// store's preview size, and its preview and grid tiers are stored under its content key and its edit's
/// digest (`EditDigest(rendering:)`). Until they're there, its embedded preview shows, marked so it's
/// clear which is showing: the loaders ask `shownEdit(for:)` which to load, and the views `renders(_:)`
/// whether to mark it.
///
/// - Order: the photos on screen first (the grid's, the filmstrip's and the active photo), then those
///   within a screen of them, nearest first, then the rest of the source in its order. A photo's sidecar
///   is read off the main thread for its edit's digest, up to `readAhead` photos ahead of the renders.
/// - Relaunching: the index records each photo's edit once its render is stored, with the date its sidecar had
///   (`PhotoEdit`), and the photo comes from the index with it (`LibraryItem.renderedEdit`) while its sidecar's
///   date is the same, so its render shows from the start, before its sidecar is read again.
/// - Changes: a photo whose sidecar or file changed (the editor's saves, and other apps' changes that
///   LibraryLive reports) is read again, showing what it showed until then. When its edit changed, it
///   shows its embedded preview until the new edit is rendered, never the old edit's, whose renders leave
///   the store unless another copy of the photo shows them. A photo given its first edit is read and rendered
///   in its turn, as the others are, wherever it is in the source.
/// - Develop first: a render starts, and goes from one step to the next (opening the photo, rendering
///   it), only while no export runs and no dialog is open, Develop isn't shown or has asked for no frame
///   for `developQuiet` and isn't opening a photo, no thumbnail on screen waits, and the Mac isn't hot or
///   saving power. The photo open in Develop waits until it's left. `statistics` counts the waits, and Develop's frames
/// asked for
///   while a step ran.
/// - Bounded: one render at a time, cancelled when its photo leaves the source or its edit changes. The
///   engine is let go once the photos it opened would hold more than `engineBudget` on the GPU, and after
///   `engineIdle` with nothing to render.
@MainActor
public final class EditRenders {
    /// Where the views report the rows on screen from.
    public enum Place: Hashable, Sendable {
        case grid, filmstrip
    }

    public struct Statistics: Sendable, Equatable {
        /// Photos rendered and stored, and those that couldn't be (a file that doesn't open, say).
        public var rendered = 0
        public var failed = 0
        /// Renders that waited for Develop, the thumbnails on screen or a cool Mac, and how long in all.
        public var waits = 0
        public var waited: Duration = .zero
        /// Frames Develop asked for while a render's step ran.
        public var overlaps = 0
        /// Engines made, one again after each was let go.
        public var engines = 0
        /// Each render's photo and steps.
        public var steps: [Step] = []

        public struct Step: Sendable, Equatable {
            public var pixels: Int
            /// In seconds: the photo opened, the edit rendered, the tiers stored.
            public var opening: Double
            public var rendering: Double
            public var storing: Double
        }
    }

    /// Names how the library renders edits, in every digest: a change to it makes every render again.
    nonisolated static let renderVersion = "app.redlamp.library.edit-render \(renderer)\n"
    /// Its number, which the index keeps with each photo's rendered edit (`PhotoEdit`): a render made before a
    /// change to it never shows as current.
    nonisolated static let renderer = 1
    /// How long Develop must have asked for no frame before a render goes on.
    static let developQuiet = Duration.milliseconds(1000)
    /// The GPU memory the pyramids of the engine's opened photos may take before it's let go: their
    /// sessions stay cached in it, each taking about twice its pyramid. And how long it's kept with
    /// nothing to render.
    static let engineBudget = 256 << 20
    static let engineIdle = Duration.seconds(10)
    /// Sidecars read in a job, jobs at once, and photos read but not yet rendered, at most, beyond
    /// those on screen and their neighbours.
    static let readBatch = 16
    static let readJobs = 2
    static let readAhead = 48
    /// Rows of the rest of the source looked at in one turn, and how long a change to what's on screen
    /// waits for others before the next is chosen.
    static let scanLimit = 1024
    static let onScreenDelay = Duration.milliseconds(50)

    /// Makes the engine edits are rendered in, off the main thread; the app sets it. Nil renders nothing.
    public var makeEngine: (@Sendable () -> (any EditingEngine)?)?
    public internal(set) var statistics = Statistics()
    /// While false, renders wait before their next step (the measurements' baselines).
    public var isRunning = true {
        didSet {
            if isRunning, !oldValue {
                schedulePump()
            }
        }
    }

    /// False while the editor window is closed: renders wait, without an engine, until it's back.
    private(set) var isWindowOpen = true

    /// The editor, for what Develop is doing and its Base Looks.
    weak var editor: EditorModel?
    let library: FolderLibrary
    let scheduler: WorkScheduler
    var known: [URL: Known] = [:]
    /// Photos whose edits are read but not rendered: those still to render.
    private(set) var waiting = 0
    private var reading: Set<URL> = []
    private var readJobs = 0
    private var onScreen: [Place: Range<Int>] = [:]
    /// The rows of the rest of the source before these need no reading, and no rendering.
    private var readCursor = 0
    private var renderCursor = 0
    /// A large source's photos with an edit, by their rows in order, which the rest of the source is looked at in:
    /// nil until they're found, and again once photos come, go or change (`findEdited`).
    private var editedRows: [Int]?
    private var findingEdited = false
    /// Photos changed while their edits were being found, so they're found again.
    private var findAgain = false
    /// Counts the changes that move the source's photos, which `editedRows` are rows of.
    private var layout = 0
    /// Whether a photo whose sidecar isn't read shows the render the index records for it; not once
    /// `renderAgain()` removed the renders.
    private var showsRecords = true
    /// The index's records of rendered edits being written, one write after another.
    private var recording: Task<Void, Never>?
    var current: (url: URL, task: Task<Void, Never>)?
    var engine: (any EditingEngine)?
    var engineBytes = 0
    var idleRelease: Task<Void, Never>?
    /// When Develop last asked for a frame or got one, and whether a render's step is running.
    var developActive: ContinuousClock.Instant?
    var stepRunning = false
    private var observers: [UUID: @MainActor ([URL]) -> Void] = [:]
    private var windowClosing: [UUID: @MainActor () -> Void] = [:]
    private var observation: LibraryObservation?
    private var pumping = false

    /// A photo's edit as last read.
    struct Known {
        var key: ContentKey
        /// The photo's file and sidecar when it was read: either changing reads it again.
        var size: Int64
        var modified: Date
        var sidecarModified: Date?
        /// Nil: its sidecar holds no edit to render.
        var digest: EditDigest?
        var state: State

        enum State {
            case unrendered, rendered, failed
        }
    }

    /// What a row needs next.
    private enum Need {
        case nothing, read, render
    }

    init(library: FolderLibrary, scheduler: WorkScheduler) {
        self.library = library
        self.scheduler = scheduler
        observation = library.observe { [weak self] diff in self?.changed(diff) }
    }

    isolated deinit {
        current?.task.cancel()
        idleRelease?.cancel()
    }

    // MARK: - What's shown

    /// The edit `item`'s thumbnails and previews show: its edit's digest once that's rendered, else nil
    /// for its embedded preview. Until its sidecar is read, the edit the index records as rendered for the sidecar
    /// as it is.
    func shownEdit(for item: LibraryItem) -> EditDigest? {
        guard item.hasEdits else { return nil }
        guard let known = known[item.url] else { return showsRecords ? item.renderedEdit : nil }
        return known.state == .rendered ? known.digest : nil
    }

    func shownEdit(at url: URL) -> EditDigest? {
        library.item(for: url).flatMap(shownEdit(for:))
    }

    /// Whether the library renders `item`'s edit, so its embedded preview is marked until then.
    public func renders(_ item: LibraryItem) -> Bool {
        item.hasEdits && item.isLocal && library.storeThumbnail(for: item) != nil
    }

    /// Calls `handler` with the photos whose thumbnails and previews show another edit, until the
    /// returned token is released.
    func observe(_ handler: @escaping @MainActor ([URL]) -> Void) -> LibraryObservation {
        let id = UUID()
        observers[id] = handler
        return LibraryObservation { [weak self] in self?.observers.removeValue(forKey: id) }
    }

    /// Calls `handler` when the editor window closes, for what keeps thumbnails beside the renders to let
    /// go of them.
    func observeWindowClosing(_ handler: @escaping @MainActor () -> Void) -> LibraryObservation {
        let id = UUID()
        windowClosing[id] = handler
        return LibraryObservation { [weak self] in self?.windowClosing.removeValue(forKey: id) }
    }

    /// The editor window closed: the render running stops, the engine lets go of its photos, renders wait
    /// until the window is back, and what keeps thumbnails beside them lets them go.
    func windowClosed() {
        isWindowOpen = false
        letEngineGo()
        for handler in windowClosing.values {
            handler()
        }
    }

    /// The editor window is back: renders go on.
    func windowReopened() {
        guard !isWindowOpen else { return }
        isWindowOpen = true
        schedulePump()
    }

    func notify(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for observer in observers.values {
            observer(urls)
        }
    }

    /// A loader found no render of `edit` in the store, where one was, or where the index recorded one: it's made
    /// again.
    func missing(_ url: URL, _ edit: EditDigest) {
        if var entry = known[url] {
            guard entry.digest == edit, entry.state == .rendered else { return }
            entry.state = .unrendered
            set(url, entry)
        } else {
            guard let item = library.item(for: url), shownEdit(for: item) == edit,
                  let (_, key) = library.storeThumbnail(for: item)
            else { return }
            set(url, Known(
                key: key, size: item.size, modified: item.modified, sidecarModified: item.sidecarModified, digest: edit,
                state: .unrendered,
            ))
        }
        revisit(url)
        notify([url])
        schedulePump()
    }

    /// The photo at `url` needs reading or rendering again: the rest of the source is looked at from it.
    func revisit(_ url: URL) {
        guard let row = library.index(of: url) else { return }
        readCursor = min(readCursor, row)
        renderCursor = min(renderCursor, row)
    }

    /// Forgets every photo's edit and removes the store's renders of them and the index's records of those, so
    /// they're read and rendered again, and starts the statistics again: for measurements. The renders are removed
    /// off the main thread, rewriting the store's shards, with renders paused until they're gone.
    @_spi(Harness) public func renderAgain() async {
        current?.task.cancel()
        let wasRunning = isRunning
        isRunning = false
        if let store = library.service?.thumbnails?.store {
            let keys = Set(known.values.map(\.key))
            _ = try? await scheduler.run(.background) {
                for key in keys {
                    store.removeEdits(of: key)
                }
            }
        }
        record(known.keys.map { Record(url: $0, sidecarModified: nil, digest: nil) })
        showsRecords = false
        known = [:]
        waiting = 0
        (readCursor, renderCursor) = (0, 0)
        statistics = Statistics()
        isRunning = wasRunning
        schedulePump()
    }

    /// Whether `item`'s edit, as its file and sidecar are now, is rendered: true once it is, false once it's found
    /// it can't be, nil until then. For measurements.
    @_spi(Harness) public func isRendered(_ item: LibraryItem) -> Bool? {
        guard let entry = known[item.url], Self.isCurrent(entry, for: item), entry.state != .unrendered else {
            return nil
        }
        return entry.state == .rendered
    }

    /// Stops the render running and lets the engine go: for measurements.
    @_spi(Harness) public func letEngineGo() {
        current?.task.cancel()
        idleRelease?.cancel()
        idleRelease = nil
        releaseEngine()
    }

    // MARK: - What's on screen

    /// The rows `place` shows, which go first.
    public func show(_ rows: Range<Int>, in place: Place) {
        guard onScreen[place] != rows else { return }
        onScreen[place] = rows
        schedulePump(after: Self.onScreenDelay)
    }

    /// Develop asked for a frame.
    func developAsked() {
        developActive = .now
        if stepRunning {
            statistics.overlaps += 1
        }
    }

    /// Develop's frame came.
    func developRendered() {
        developActive = .now
    }

    // MARK: - The source's changes

    private func changed(_ diff: LibraryDiff) {
        if diff.reset || !diff.removed.isEmpty || !diff.inserted.isEmpty {
            layout += 1
            (readCursor, renderCursor) = (0, 0)
            editedRows = nil
            if diff.reset {
                onScreen = [:]
                for url in known.keys where library.index(of: url) == nil {
                    set(url, nil)
                }
            }
            if let current, library.index(of: current.url) == nil {
                current.task.cancel()
            }
        } else if let first = diff.updated.first {
            // A photo may have been given its first edit, on screen or off it (Sync, Paste, another Mac): the rest of
            // the source is looked at again from the first photo that changed, and a large source's photos with an
            // edit are found again.
            readCursor = min(readCursor, first)
            renderCursor = min(renderCursor, first)
            if library.items.readsOnRequest {
                editedRows = nil
                findAgain = findingEdited
            }
        }
        var gone: [URL] = []
        let items = library.items
        // A change to thousands of rows (culling a whole selection) reaches the photos known here alone.
        let rows = diff.updated.count > known.count
            ? known.keys.compactMap { library.index(of: $0) }.filter(diff.updated.contains).sorted()
            : Array(diff.updated)
        for row in rows where items.indices.contains(row) {
            guard let item = items.row(row), let entry = known[item.url] else { continue }
            if !item.hasEdits {
                set(item.url, nil)
                drop(entry.digest, of: entry.key, unlessShownBy: item.url)
                gone.append(item.url)
                if current?.url == item.url {
                    current?.task.cancel()
                }
            } else if !Self.isCurrent(entry, for: item) {
                readCursor = min(readCursor, row)
                renderCursor = min(renderCursor, row)
            }
        }
        notify(gone)
        schedulePump()
    }

    /// Whether `entry` was read from the file and sidecar `item` has now.
    static func isCurrent(_ entry: Known, for item: LibraryItem) -> Bool {
        entry.size == item.size && entry.modified == item.modified && entry.sidecarModified == item.sidecarModified
    }

    func set(_ url: URL, _ entry: Known?) {
        let before = known[url]?.state == .unrendered
        known[url] = entry
        waiting += (entry?.state == .unrendered ? 1 : 0) - (before ? 1 : 0)
    }

    /// Removes the store's renders of `edit` of the photo `key` names, unless another photo with that
    /// key shows them (a copy of it).
    func drop(_ edit: EditDigest?, of key: ContentKey, unlessShownBy url: URL) {
        guard let edit, let store = library.service?.thumbnails?.store else { return }
        let keeping = claims(of: key, except: url)
        guard !keeping.contains(edit) else { return }
        scheduler.submit(.background) { _ = store.removeEdits(of: key, keeping: keeping) }
    }

    /// The edits other photos with `key` show, or will once rendered.
    func claims(of key: ContentKey, except url: URL) -> Set<EditDigest> {
        Set(known.compactMap { $0.key != url && $0.value.key == key ? $0.value.digest : nil })
    }
}

extension EditRenders {
    // MARK: - Choosing what's next

    /// Chooses what to read and render next on a later turn of the main thread, after `delay`, once
    /// for every call made before then.
    func schedulePump(after delay: Duration = .zero) {
        guard !pumping else { return }
        pumping = true
        Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard let self else { return }
            pumping = false
            let focus = focusRows()
            readEdits(focus)
            renderNext(focus)
        }
    }

    private func need(_ item: LibraryItem) -> Need {
        guard item.hasEdits, item.isLocal, !item.isSettling, item.sidecarIsLocal,
              library.storeThumbnail(for: item) != nil
        else { return .nothing }
        guard let entry = known[item.url], Self.isCurrent(entry, for: item) else {
            return reading.contains(item.url) ? .nothing : .read
        }
        return entry.state == .unrendered && !reading.contains(item.url) ? .render : .nothing
    }

    /// The rows on screen, the active photo's first, then those within a screen of them, nearest first.
    private func focusRows() -> [Int] {
        let count = library.items.count
        var ranges = Array(onScreen.values).map { $0.clamped(to: 0 ..< count) }.filter { !$0.isEmpty }
        if let selection = editor?.selection, let row = library.index(of: selection) {
            ranges.insert(row ..< row + 1, at: 0)
        }
        var seen = Set<Int>()
        var rows: [Int] = []
        for range in ranges {
            for row in range where seen.insert(row).inserted {
                rows.append(row)
            }
        }
        let screen = ranges.map(\.count).max() ?? 0
        if screen > 0 {
            for distance in 1 ... screen {
                for range in ranges {
                    for row in [range.lowerBound - distance, range.upperBound - 1 + distance]
                        where (0 ..< count).contains(row) && seen.insert(row).inserted {
                        rows.append(row)
                    }
                }
            }
        }
        return rows
    }

    /// The rows of the rest of the source from `cursor`, `scanLimit` at most, `visit`ed in order until it
    /// returns false. The cursor moves past those `isDone` says need nothing. Of a large source's, those of its
    /// photos with an edit alone (`scanLarge`).
    private func scan(from cursor: inout Int, isDone: (LibraryItem) -> Bool, _ visit: (Int) -> Bool) {
        let items = library.items
        guard !items.readsOnRequest else { return scanLarge(from: &cursor, isDone: isDone, visit) }
        var row = cursor
        let end = min(items.count, cursor + Self.scanLimit)
        while row < end {
            if row == cursor, isDone(items[row]) {
                cursor += 1
            } else if !visit(row) {
                return
            }
            row += 1
        }
        if row == end, end < items.count {
            schedulePump()
        }
    }

    /// `scan` over a large source's photos with an edit, as the engine finds them: those whose rows aren't read are
    /// asked for, a batch at a time, and looked at once they're in.
    private func scanLarge(from cursor: inout Int, isDone: (LibraryItem) -> Bool, _ visit: (Int) -> Bool) {
        guard let edited = editedRows else { return findEdited() }
        let items = library.items
        var (index, high) = (0, edited.count)
        while index < high {
            let middle = (index + high) / 2
            if edited[middle] < cursor {
                index = middle + 1
            } else {
                high = middle
            }
        }
        let end = min(edited.count, index + Self.scanLimit)
        var asking: [Int] = []
        while index < end {
            let row = edited[index]
            guard items.indices.contains(row), let item = items.row(row) else {
                asking.append(row)
                guard asking.count < Self.readBatch * 4 else { break }
                index += 1
                continue
            }
            if asking.isEmpty, isDone(item) {
                cursor = row + 1
            } else if !visit(row) {
                break
            }
            index += 1
        }
        library.askForRows(at: asking)
        if index == end, end < edited.count, asking.isEmpty {
            schedulePump()
        }
    }

    /// Finds the large source's or folder's photos with an edit, and their rows, off the main thread, for
    /// `scanLarge`: again when photos moved or changed meanwhile.
    private func findEdited() {
        guard !findingEdited, let engine = library.service?.core?.engine,
              let query = try? LibraryQuery(parsing: "edited:yes")
        else { return }
        findingEdited = true
        findAgain = false
        let (layout, list) = (layout, library.photoList)
        let source = list.source
        Task { [weak self] in
            let rows = await Task.detached(priority: .utility) { () -> [Int]? in
                guard let found = try? await engine.list(source, matching: query) else { return nil }
                return found.ids.compactMap(list.index(of:)).sorted()
            }.value
            guard let self else { return }
            findingEdited = false
            guard library.items.readsOnRequest else { return }
            guard self.layout == layout, !findAgain else { return findEdited() }
            editedRows = rows ?? []
            schedulePump()
        }
    }

    /// Starts reading the edits of the next photos that need it, a batch to a job: those on screen and
    /// near it, then the rest of the source's, `readAhead` at most ahead of the renders.
    private func readEdits(_ focus: [Int]) {
        let items = library.items
        while readJobs < Self.readJobs {
            var batch: [ReadPhoto] = []
            var urgent = false
            let add = { (row: Int) in
                guard let item = items.row(row), self.need(item) == .read,
                      !batch.contains(where: { $0.item.url == item.url }),
                      let (thumbnails, key) = self.library.storeThumbnail(for: item)
                else { return }
                batch.append(ReadPhoto(item: item, key: key, store: thumbnails.store))
            }
            for row in focus where batch.count < Self.readBatch {
                add(row)
            }
            urgent = !batch.isEmpty
            if batch.count < Self.readBatch, waiting < Self.readAhead {
                scan(from: &readCursor, isDone: { need($0) != .read }) { row in
                    add(row)
                    return batch.count < Self.readBatch && waiting + batch.count < Self.readAhead
                }
            }
            guard !batch.isEmpty else { return }
            readJobs += 1
            reading.formUnion(batch.map(\.item.url))
            let (photos, sidecars) = (batch, library.sidecars)
            scheduler.submit(urgent ? .lookAhead : .background) {
                let read = photos.map { ($0, Self.read($0, sidecars: sidecars)) }
                Task { @MainActor [weak self] in self?.received(read) }
            }
        }
    }

    /// A photo whose edit is to be read: as it was listed, its content key and the store.
    struct ReadPhoto: Sendable {
        let item: LibraryItem
        let key: ContentKey
        let store: PhotoStore
    }

    /// What reading a photo's edit found: its digest (nil for none to render), and whether the store
    /// has both its tiers of the file as it is.
    struct ReadEdit: Sendable {
        let digest: EditDigest?
        let isStored: Bool
    }

    /// An edit made by a newer Redlamp isn't rendered: a render made here would be kept under its
    /// digest after an update that renders it as it was made.
    nonisolated static func read(_ photo: ReadPhoto, sidecars: SidecarPlacement) -> ReadEdit {
        let url = photo.item.url
        guard let recipe = recipe(of: url, in: sidecars.store(for: url)), !recipe.isPristine,
              !recipe.requiresNewerProcess, let digest = EditDigest(rendering: recipe)
        else { return ReadEdit(digest: nil, isStored: false) }
        let stored = PhotoStore.Tier.allCases.allSatisfy { tier in
            photo.store.contains(
                photo.key, tier: tier, edit: digest, size: photo.item.size, modified: photo.item.modified,
            )
        }
        return ReadEdit(digest: digest, isStored: stored)
    }

    /// Takes the edits read. Before a photo's sidecar is read, the edit the index records stands for the one it
    /// showed; a photo whose edit isn't recorded as it's now stored has its record set right.
    private func received(_ read: [(ReadPhoto, ReadEdit)]) {
        readJobs -= 1
        var changed: [URL] = []
        var records: [Record] = []
        for (photo, edit) in read {
            let url = photo.item.url
            reading.remove(url)
            guard let item = library.item(for: url), item.size == photo.item.size,
                  item.modified == photo.item.modified, item.sidecarModified == photo.item.sidecarModified,
                  library.storeThumbnail(for: item)?.1 == photo.key
            else {
                revisit(url)
                continue
            }
            let shown = shownEdit(for: item)
            let before = known[url]
            let previous = before == nil ? shown : before?.digest
            set(url, Known(
                key: photo.key, size: item.size, modified: item.modified, sidecarModified: item.sidecarModified,
                digest: edit.digest,
                state: edit.digest == nil ? .failed : edit.isStored ? .rendered : .unrendered,
            ))
            if let previous, previous != edit.digest {
                drop(previous, of: before?.key ?? photo.key, unlessShownBy: url)
            }
            if edit.digest != item.renderedEdit, edit.isStored || item.renderedEdit != nil {
                records.append(Record(
                    url: url, sidecarModified: item.sidecarModified, digest: edit.isStored ? edit.digest : nil,
                ))
            }
            if shownEdit(for: item) != shown {
                changed.append(url)
            }
        }
        record(records)
        notify(changed)
        schedulePump()
    }

    /// What the index is to record of a photo's rendered edit: the digest whose render the store holds, read from
    /// its sidecar as modified at `sidecarModified`; with no digest, that it has none.
    struct Record: Sendable {
        let url: URL
        let sidecarModified: Date?
        let digest: EditDigest?
    }

    /// Records the edits whose renders the store holds in the index, off the main thread and in the order asked, so
    /// a relaunch shows them before the photos' sidecars are read again (`PhotoEdit`); forgets a photo's for a
    /// record with no digest.
    func record(_ records: [Record]) {
        guard !records.isEmpty, let index = library.service?.core?.index else { return }
        let (renderer, previous) = (Self.renderer, recording)
        recording = Task.detached(priority: .utility) {
            await previous?.value
            _ = try? await index.write { writer in
                for record in records {
                    guard let photo = try LibraryService.photo(at: record.url, in: writer) else { continue }
                    if let digest = record.digest, let modified = record.sidecarModified {
                        try writer.setPhotoEdit(
                            digest,
                            ofPhoto: photo.id,
                            sidecarModified: modified,
                            renderer: renderer,
                        )
                    } else {
                        try writer.removePhotoEdits([photo.id])
                    }
                }
            }
        }
    }

    /// A photo to render: its edit's digest, and the store its tiers go to under its content key.
    struct NextRender {
        let item: LibraryItem
        let key: ContentKey
        let store: PhotoStore
        let digest: EditDigest
    }

    /// The next photo to render: the first of `focus` that needs it, else of the rest of the source,
    /// leaving the one open in Develop until it's left.
    func nextRender(_ focus: [Int]) -> NextRender? {
        let items = library.items
        var found: NextRender?
        let take = { (row: Int) -> Bool in
            guard let item = items.row(row), self.need(item) == .render, !self.isOpenInDevelop(item.url),
                  let digest = self.known[item.url]?.digest,
                  let (thumbnails, key) = self.library.storeThumbnail(for: item)
            else { return false }
            found = NextRender(item: item, key: key, store: thumbnails.store, digest: digest)
            return true
        }
        if focus.contains(where: take) {
            return found
        }
        scan(from: &renderCursor, isDone: { need($0) == .nothing && !reading.contains($0.url) }) { !take($0) }
        return found
    }

    func isOpenInDevelop(_ url: URL) -> Bool {
        guard let editor, editor.module == .develop else { return false }
        return editor.selection == url || editor.info?.url == url
    }
}
