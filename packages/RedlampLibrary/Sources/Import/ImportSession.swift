import CoreGraphics
import Foundation
import RedlampDocument
import Synchronization

/// What an import session reports as it browses its sources, each once the session holds it.
public enum ImportEvent: Sendable, Hashable {
    /// A source's photos are listed, newest first by their files' dates.
    case listed(source: String, photos: [String])
    /// Photos whose first bytes are read: their content keys, metadata and the ratings they carry.
    case read([String])
    /// Photos whose grid thumbnails are in the store.
    case previewed([String])
    /// Photos the library has already, every photo file of them, so their previews aren't read.
    case imported([String])
    case failed(photo: String, message: String)
    /// A source that couldn't be listed: gone, or not answering.
    case sourceFailed(source: String, message: String)
    /// Every source is listed and every photo read, and previewed unless the library has it.
    case browsed
}

/// An import's browsing (LIB-27): its sources, each listed and read through its own volume's readers,
/// and their photos with what the user chooses for them.
///
/// - **At once:** each source is listed, then its photos are read newest first, those on screen
///   (`prioritise`) before the rest: each photo's first bytes once, for its content keys, metadata and
///   the rating and label it carries, then its embedded preview, made into a grid thumbnail in the
///   store under its content key. Nothing is copied, and nothing written beside the photos.
/// - **Already imported:** a photo's content keys are looked up among the library's, loaded once, as
///   soon as its head is read and before its preview is: a photo the library has is marked, and its
///   preview isn't read.
/// - **While it copies:** previews are read at the volume's high priority and copies at its normal
///   one, through the same readers (`importer`).
/// - **Choices:** which photos go, and the rating, flag and label each is given, are kept here until
///   the import is planned, and written in each photo's `.redlamp` at the destination.
public final class ImportSession: Sendable {
    public let sources: [ImportSource]
    public let library: ImportLibrary
    public let fileSystem: any LibraryFileSystem
    public let volumes: VolumeIORegistry
    public let scheduler: WorkScheduler
    /// Browsing makes grid thumbnails; without, it reads only the photos' heads.
    public let makesPreviews: Bool
    private let state = Mutex(State())

    /// Photos kept in memory whole, at most, when one has no embedded preview to take.
    static let wholeFileLimit = 128 << 20

    private struct State {
        var photos: [String: ImportPhoto] = [:]
        /// Each source's photos, newest first.
        var bySource: [String: [String]] = [:]
        /// Each source's files that aren't photos or sidecars of them, by path.
        var others: [String: [String]] = [:]
        var prioritised: [String] = []
        /// Each source's place in its photos, newest first, for its readers.
        var cursors: [String: Int] = [:]
        /// Photos being read, or read.
        var claimed: Set<String> = []
        /// Sources listed, by ID.
        var listed: Set<String> = []
        var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
        var keys: Task<ImportKeys, Never>?
        var browsing: Task<Void, Never>?
    }

    public init(
        sources: [ImportSource], library: ImportLibrary, fileSystem: any LibraryFileSystem = LocalFileSystem(),
        volumes: VolumeIORegistry? = nil, scheduler: WorkScheduler = LibraryIndexer.scheduler,
        makesPreviews: Bool = true,
    ) {
        self.sources = sources
        self.library = library
        self.fileSystem = fileSystem
        self.volumes = volumes ?? VolumeIORegistry(fileSystem: fileSystem)
        self.scheduler = scheduler
        self.makesPreviews = makesPreviews
    }

    /// The readers `source` is read through: its volume's.
    public func io(for source: ImportSource) -> VolumeIO {
        volumes.io(for: source.volume, probe: source.url)
    }

    // MARK: - Photos and choices

    /// Every source's photos, newest first.
    public var photos: [ImportPhoto] {
        state.withLock { Array($0.photos.values) }.sorted { first, second in
            first.captured != second.captured ? first.captured > second.captured : first.id < second.id
        }
    }

    public func photo(_ id: String) -> ImportPhoto? {
        state.withLock { $0.photos[id] }
    }

    /// The files on `source` that aren't photos or their sidecars, by path: videos, a camera's own.
    public func otherFiles(on source: ImportSource) -> [String] {
        state.withLock { $0.others[source.id] ?? [] }
    }

    /// Reads these photos before the others: the cells on screen, first first.
    public func prioritise(_ ids: [String]) {
        state.withLock { $0.prioritised = ids }
    }

    public func choose(_ ids: [String], _ chosen: Bool) {
        change(ids) { $0.isChosen = chosen }
    }

    public func rate(_ ids: [String], _ stars: Int) {
        change(ids) { $0.rate(stars) }
    }

    public func flag(_ ids: [String], _ flag: PhotoFlag?) {
        change(ids) { $0.setFlag(flag) }
    }

    public func label(_ ids: [String], _ label: ColorLabel?) {
        change(ids) { $0.setLabel(label) }
    }

    /// Takes `photos` as their sources' only ones, listed elsewhere: the ingest step lists the one it's
    /// given.
    func add(_ photos: [ImportPhoto]) {
        state.withLock { state in
            for photo in photos where state.photos[photo.id] == nil {
                state.photos[photo.id] = photo
                state.bySource[photo.source, default: []].append(photo.id)
                state.listed.insert(photo.source)
            }
        }
    }

    func change(_ ids: [String], _ body: (inout ImportChoices) -> Void) {
        state.withLock { state in
            for id in ids {
                if var choices = state.photos[id]?.choices {
                    body(&choices)
                    state.photos[id]?.choices = choices
                }
            }
        }
    }

    // MARK: - Browsing

    /// Lists every source and reads its photos, as the type describes, reporting each step; cancelling
    /// the task iterating the events stops it.
    public func browse() -> AsyncStream<ImportEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ImportEvent.self)
        let task = Task { [self] in
            await withTaskGroup(of: Void.self) { group in
                for source in sources {
                    group.addTask { await self.browse(source, events: continuation) }
                }
            }
            if !Task.isCancelled {
                continuation.yield(.browsed)
            }
            continuation.finish()
        }
        state.withLock { $0.browsing = task }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Stops browsing.
    public func close() {
        state.withLock { $0.browsing }?.cancel()
    }

    /// Photos read at once on a volume: enough to keep its readers busy while others parse and decode.
    static func readers(_ io: VolumeIO) -> Int {
        min(max(2 * io.width, 4), 2 * CoreCounts.performance)
    }

    private func browse(_ source: ImportSource, events: AsyncStream<ImportEvent>.Continuation) async {
        let io = io(for: source)
        do {
            if !state.withLock({ $0.listed.contains(source.id) }) {
                try await list(source, io: io)
            }
        } catch {
            events.yield(.sourceFailed(source: source.id, message: ImportCopyError.message(error)))
            return
        }
        events.yield(.listed(source: source.id, photos: state.withLock { $0.bySource[source.id] ?? [] }))
        let keys = await knownKeys()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< Self.readers(io) {
                group.addTask {
                    while !Task.isCancelled, let id = self.claimNext(on: source.id) {
                        await self.read(id, io: io, keys: keys, previewing: self.makesPreviews, events: events)
                    }
                }
            }
        }
    }

    /// Lists `source`'s photo folder and every folder below it: a folder that can't be listed below
    /// the first is left out.
    private func list(_ source: ImportSource, io: VolumeIO) async throws {
        let top = LibraryIndexer.path(source.photosFolder)
        var waiting = [top]
        var photos: [ImportPhoto] = []
        var others: [String] = []
        while let folder = waiting.popLast() {
            let entries: [FileEntry]
            do {
                entries = try await io.contentsOfDirectory(at: URL(fileURLWithPath: folder, isDirectory: true))
            } catch where folder != top && VolumeIO.isNotFound(error) {
                continue
            }
            let (found, rest) = ImportPhoto.group(entries, folder: folder, source: source.id)
            photos += found
            others += rest.map { folder + "/" + $0.name }
            waiting += entries.filter(FolderWalk.isFolder).map { folder + "/" + $0.name }
        }
        photos.sort { $0.captured != $1.captured ? $0.captured > $1.captured : $0.id < $1.id }
        state.withLock { state in
            guard state.listed.insert(source.id).inserted else { return }
            for photo in photos where state.photos[photo.id] == nil {
                state.photos[photo.id] = photo
            }
            state.bySource[source.id] = photos.map(\.id)
            state.others[source.id] = others.sorted()
        }
    }

    /// Lists the sources not listed yet; one that can't be is left out.
    private func ensureListed() async {
        let unlisted = state.withLock { state in sources.filter { !state.listed.contains($0.id) } }
        await withTaskGroup(of: Void.self) { group in
            for source in unlisted {
                group.addTask { try? await self.list(source, io: self.io(for: source)) }
            }
        }
    }

    /// The library's content keys, loaded the first time they're asked for.
    private func knownKeys() async -> ImportKeys {
        let task = state.withLock { state in
            if let keys = state.keys {
                return keys
            }
            let library = library
            let keys = Task { await (try? library.contentKeys()) ?? ImportKeys() }
            state.keys = keys
            return keys
        }
        return await task.value
    }

    /// The next photo of `source` to read: one asked for first, else the newest not yet read.
    private func claimNext(on source: String) -> String? {
        state.withLock { state in
            if let index = state.prioritised.firstIndex(where: { id in
                state.photos[id]?.source == source && !state.claimed.contains(id)
            }) {
                let id = state.prioritised.remove(at: index)
                state.claimed.insert(id)
                return id
            }
            let order = state.bySource[source] ?? []
            var cursor = state.cursors[source] ?? 0
            defer { state.cursors[source] = cursor }
            while cursor < order.count {
                let id = order[cursor]
                cursor += 1
                if state.claimed.insert(id).inserted {
                    return id
                }
            }
            return nil
        }
    }

    /// Reads photo `id`'s head and, when `previewing` and the library doesn't have it, its preview.
    private func read(
        _ id: String, io: VolumeIO, keys: ImportKeys, previewing: Bool,
        events: AsyncStream<ImportEvent>.Continuation?,
    ) async {
        guard let photo = state.withLock({ $0.photos[id] }) else { return }
        let priority: VolumeIO.Priority = previewing ? .high : .normal
        let read: ReadHead
        do {
            read = try await readHead(of: photo, io: io, priority: priority)
        } catch is CancellationError {
            state.withLock { _ = $0.claimed.remove(id) }
            finish(id) { _ in }
            return
        } catch {
            let message = ImportCopyError.message(error)
            finish(id) { $0.state = .failed(message) }
            events?.yield(.failed(photo: id, message: message))
            return
        }
        let updated = finish(id) { photo in
            for index in photo.files.indices {
                photo.files[index].contentKey = read.keys[photo.files[index].name]
            }
            photo.metadata = read.metadata
            photo.xmp = read.xmp
            photo.imported = Set(read.keys.filter { keys.contains($0.value) }.keys)
            photo.state = photo.isImported ? .imported : .read
            photo.choices.fill(from: photo.ownChoices)
        }
        guard let updated else { return }
        events?.yield(updated.isImported ? .imported([id]) : .read([id]))
        guard previewing, !updated.isImported, let store = library.store, let key = read.keys[updated.primary.name]
        else { return }
        let made: Bool = if store.contains(
            key,
            tier: .grid,
            size: updated.primary.size,
            modified: updated.primary.modified,
        ) {
            true
        } else {
            await (try? preview(updated, key: key, head: read.head, io: io, store: store)) ?? false
        }
        if made {
            state.withLock { $0.photos[id]?.state = .previewed }
            events?.yield(.previewed([id]))
        }
    }

    /// Changes photo `id` as its head's reading ended, and lets go of what waited for it.
    @discardableResult
    private func finish(_ id: String, _ change: (inout ImportPhoto) -> Void) -> ImportPhoto? {
        let (photo, waiters) = state.withLock { state -> (ImportPhoto?, [CheckedContinuation<Void, Never>]) in
            if var photo = state.photos[id] {
                change(&photo)
                state.photos[id] = photo
            }
            return (state.photos[id], state.waiters.removeValue(forKey: id) ?? [])
        }
        for waiter in waiters {
            waiter.resume()
        }
        return photo
    }

    /// Reads every one of `ids` not read yet, a source's at a time on its own readers, waiting for those
    /// browsing reads now; without previews.
    func ensureRead(_ ids: [String]) async {
        let keys = await knownKeys()
        let bySource = state.withLock { state in
            Dictionary(grouping: ids.filter { state.photos[$0]?.isRead == false }) { state.photos[$0]?.source ?? "" }
        }
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                guard let pending = bySource[source.id], !pending.isEmpty else { continue }
                let io = io(for: source)
                let queue = ImportQueue(pending)
                for _ in 0 ..< Self.readers(io) {
                    group.addTask {
                        while !Task.isCancelled, let id = queue.next() {
                            while !Task.isCancelled, self.photo(id)?.isRead == false {
                                if self.state.withLock({ $0.claimed.insert(id).inserted }) {
                                    await self.read(id, io: io, keys: keys, previewing: false, events: nil)
                                } else {
                                    await self.waitForHead(id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func waitForHead(_ id: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let read = state.withLock { state -> Bool in
                guard state.photos[id]?.isRead == false else { return true }
                state.waiters[id, default: []].append(continuation)
                return false
            }
            if read {
                continuation.resume()
            }
        }
    }

    // MARK: - Heads

    struct ReadHead: Sendable {
        var head: Data
        var metadata: CaptureMetadata?
        var xmp: CaptureMetadata?
        /// Each photo file's content key, by name.
        var keys: [String: ContentKey]
    }

    /// The photo's first photo file's head (its content key and metadata), the content keys of the
    /// others, and other apps' `.xmp` beside it, each read once through the volume's readers.
    private func readHead(of photo: ImportPhoto, io: VolumeIO, priority: VolumeIO.Priority) async throws -> ReadHead {
        let url = photo.url
        let size = Int(photo.primary.size)
        let head = try await io.read(url, range: 0 ..< PhotoMetadataReader.headLength, priority: priority)
        var xmp: Data?
        if let sidecar = photo.files
            .first(where: { $0.role == .otherApp && NamingJob.split($0.name).ext.lowercased() == "xmp" }) {
            let xmpURL = URL(fileURLWithPath: photo.folder + "/" + sidecar.name, isDirectory: false)
            xmp = try? await io.read(xmpURL, range: 0 ..< max(Int(sidecar.size), 1), priority: priority)
        }
        let xmpData = xmp
        let lane: WorkScheduler.Lane = priority == .high ? .onScreen : .lookAhead
        var parsed = try await scheduler.run(lane) {
            LibraryIndexer.Run.parse(head: head, size: size, url: url, xmp: xmpData)
        }
        if parsed.needsFile {
            let headLength = PhotoMetadataReader.headLength
            if size > headLength {
                _ = try await io.read(
                    url, range: headLength ..< min(size, LibraryIndexer.Run.chargedFileRead), priority: priority,
                )
            }
            parsed.metadata = try await scheduler.run(lane) { PhotoMetadataReader.read(url: url) }
        }
        var keys = [photo.primary.name: parsed.key]
        for file in photo.photoFiles.dropFirst() {
            let fileURL = URL(fileURLWithPath: photo.folder + "/" + file.name, isDirectory: false)
            let fileHead = try await io.read(fileURL, range: 0 ..< ContentKey.headLength, priority: priority)
            keys[file.name] = ContentKey(fileSize: Int(file.size), head: fileHead)
        }
        return ReadHead(head: head, metadata: parsed.metadata, xmp: parsed.xmp, keys: keys)
    }

    // MARK: - Previews

    /// Makes the photo's grid thumbnail from the smallest embedded preview that fills a cell, read alone
    /// through the volume's readers, or from the whole photo when it has none; and stores it under
    /// `key`, with the file's size and date.
    private func preview(
        _ photo: ImportPhoto, key: ContentKey, head: Data, io: VolumeIO, store: PhotoStore,
    ) async throws -> Bool {
        let url = photo.url
        let primary = photo.primary
        let size = Int(primary.size)
        let edge = PhotoStore.Tier.grid.pixelSize
        let orientation = photo.metadata?.orientation
        var payload: Data?
        if primary.isRaw {
            var bytes = PreviewBytes(head: head, size: size) { range in
                try await io.read(url, range: range, priority: .high)
            }
            if let embedded = try await EmbeddedPreviews.best(in: &bytes, reaching: edge) {
                let jpeg = embedded.range.upperBound <= head.count
                    ? Data(head.dropFirst(embedded.offset).prefix(embedded.length))
                    : try await io.read(url, range: embedded.range, priority: .high)
                payload = try await scheduler.run(.onScreen) {
                    EmbeddedPreviews.thumbnail(ofJPEG: jpeg, edge: edge, orientation: orientation)
                        .flatMap { StoreImageEncoder().encode($0, for: .grid) }
                }
            }
        }
        if payload == nil, size <= Self.wholeFileLimit {
            var whole = Data(head.prefix(size))
            if whole.count < size {
                try await whole.append(io.read(url, range: whole.count ..< size, priority: .high))
            }
            let file = whole
            payload = try await scheduler.run(.onScreen) {
                StoreThumbnailMaker.imageIO(url, file, edge).flatMap { StoreImageEncoder().encode($0, for: .grid) }
            }
        }
        guard let payload else { return false }
        return store.store(payload, for: key, tier: .grid, size: primary.size, modified: primary.modified)
    }

    // MARK: - Planning and copying

    /// The import of the photos chosen, as `settings` puts them, worked out before anything is copied:
    /// each photo's folders and names, numbered to tell them apart in capture order, at the destination
    /// and the backup, with its files; and what's left and why. Photos not read yet are read first, without
    /// previews; the destinations are listed through `destinationFileSystem`.
    public func plan(
        _ settings: ImportSettings, destinationFileSystem: any LibraryFileSystem = LocalFileSystem(),
        date: Date = Date(),
    ) async throws -> ImportPlan {
        await ensureListed()
        let chosen = state.withLock { $0.photos.values.filter(\.choices.isChosen).map(\.id) }
        await ensureRead(chosen)
        let photos = photos
        let sources = sources
        let others = state.withLock { $0.others.mapValues(\.count) }
        return try await LibraryIndex.offCaller {
            ImportPlanner(settings: settings, fileSystem: destinationFileSystem, date: date)
                .plan(photos, sources: sources, others: others)
        }
    }

    /// What copies this session's plans, reading through the same readers as the browsing.
    public func importer(destinationFileSystem: any LibraryFileSystem = LocalFileSystem()) -> Importer {
        Importer(
            library: library, fileSystem: fileSystem, destinationFileSystem: destinationFileSystem, volumes: volumes,
        )
    }
}
