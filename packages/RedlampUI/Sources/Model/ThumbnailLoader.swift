import CoreGraphics
import Dispatch
import Foundation
import RedlampDocument
import RedlampLibrary
import Synchronization

/// Filmstrip thumbnails: decoded in parallel by priority, kept in memory within a byte budget,
/// and cached on disk in per-folder packs, or for the library's photos in its store.
///
/// A request is answered from memory; for a photo the library shows, from the store's grid tier
/// (made there first when the indexer hasn't yet), or its render of the photo's edit once `renders`
/// has made it (LIB-17); else from the folder's pack, else by decoding the photo's embedded preview
/// at the cell's pixel size, which then goes into the pack. Thumbnails are kept by the edit they
/// show, and requests for one photo and edit share a decode. A request can be promoted (its cell
/// scrolled into view) or
/// cancelled (it scrolled away), and photos iCloud Drive hasn't downloaded are never read. Warming
/// decodes a folder's thumbnails into its pack on the background lane, without keeping them in
/// memory; the library's photos are left to the indexer.
@MainActor
public final class ThumbnailLoader {
    /// The long edge thumbnails are decoded at: a filmstrip cell's image at 2x.
    public nonisolated static let pixelSize = 192
    /// Photos per warming job.
    static let warmBatch = 8

    /// The pixel bytes held at most. They're purgeable (see `load`), so about a third of this counts
    /// in the app's footprint.
    public let budget: Int
    /// The photos on screen, which trimming keeps.
    public var protected: Set<URL> = []
    /// The store and content key of a photo the library shows; nil for any other.
    public var library: (@MainActor (LibraryItem) -> (StoreThumbnails, ContentKey)?)?
    /// Which edit each photo's thumbnail shows.
    weak var renders: EditRenders?

    private let scheduler: WorkScheduler
    /// Starts every key this loader gives `scheduler`, which other loaders share (the harness's
    /// scenes', each test's): a job with another's key would replace it, or be cancelled with it.
    private let keyPrefix = "thumbnails \(UUID().uuidString) "
    let packs: ThumbnailPacks
    let decode: @Sendable (URL, Int) -> CGImage?
    private var cache: [Key: Entry] = [:]
    private var used = 0
    private var tick: UInt64 = 0
    private var waiting: [Key: [UInt64: (CGImage?) -> Void]] = [:]
    private var requested: [UInt64: Key] = [:]
    private var lanes: [Key: WorkScheduler.Lane] = [:]
    private var nextID: UInt64 = 0
    private var warmQueue: [LibraryItem] = []
    private var warmHead = 0
    private var warming = 0
    private var warmGeneration = 0
    private var pressure: (any DispatchSourceMemoryPressure)?

    /// A photo's thumbnail showing `edit`'s render, or with none its embedded preview.
    private struct Key: Hashable {
        let url: URL
        let edit: EditDigest?
    }

    private struct Entry {
        let image: CGImage
        let cost: Int
        let size: Int64
        let modified: Date
        var used: UInt64
    }

    public init(
        scheduler: WorkScheduler = .shared,
        packs: ThumbnailPacks = ThumbnailPacks(),
        budget: Int = 128 << 20,
        decode: @escaping @Sendable (URL, Int) -> CGImage?,
    ) {
        self.scheduler = scheduler
        self.packs = packs
        self.budget = budget
        self.decode = decode
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.trim(to: 0) }
        }
        source.resume()
        pressure = source
    }

    isolated deinit {
        pressure?.cancel()
    }

    /// Bytes of decoded thumbnails held.
    public var memoryUsed: Int {
        used
    }

    /// Decoded thumbnails held.
    public var cachedCount: Int {
        cache.count
    }

    // MARK: - Requests

    /// The thumbnail if it is in memory, still matches the file, and shows the edit it's to show.
    public func cached(_ item: LibraryItem) -> CGImage? {
        let key = key(item)
        guard var entry = cache[key], entry.size == item.size, entry.modified == item.modified else { return nil }
        tick += 1
        entry.used = tick
        cache[key] = entry
        return entry.image
    }

    private func key(_ item: LibraryItem) -> Key {
        Key(url: item.url, edit: renders?.shownEdit(for: item))
    }

    /// Asks for `item`'s thumbnail; `completion` gets it on the main thread (nil if it can't be
    /// made, the photo isn't downloaded, or the request is cancelled). Returns an id for `cancel`.
    @discardableResult
    public func request(
        _ item: LibraryItem, lane: WorkScheduler.Lane = .onScreen, completion: @escaping (CGImage?) -> Void,
    ) -> UInt64 {
        nextID += 1
        let id = nextID
        if let image = cached(item) {
            completion(image)
            return id
        }
        guard item.isLocal, !item.isSettling else {
            completion(nil)
            return id
        }
        let key = key(item)
        requested[id] = key
        if waiting[key] != nil {
            waiting[key]?[id] = completion
            promote(key, to: lane)
            return id
        }
        waiting[key] = [id: completion]
        lanes[key] = lane
        let (packs, decode, store) = (packs, decode, library?(item))
        scheduler.submit(lane, key: job(key)) {
            let image = Self.load(item, store: store, edit: key.edit, packs: packs, decode: decode)
            Task { @MainActor [weak self] in self?.finish(key, item, image) }
        }
        return id
    }

    /// The thumbnail, waiting for it if needed. Cancelling the calling task cancels the request.
    public func image(for item: LibraryItem, lane: WorkScheduler.Lane = .onScreen) async -> CGImage? {
        if let image = cached(item) {
            return image
        }
        let ticket = RequestTicket()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let id = request(item, lane: lane) { continuation.resume(returning: $0) }
                ticket.id.withLock { $0 = id }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if let id = ticket.id.withLock({ $0 }) {
                    self?.cancel(id)
                }
            }
        }
    }

    /// A request's id, for cancelling it from the task's cancellation handler.
    private final class RequestTicket: Sendable {
        let id = Mutex<UInt64?>(nil)
    }

    /// Cancels one request, which completes with nil. The decode is dropped if nobody else waits.
    public func cancel(_ id: UInt64) {
        guard let key = requested.removeValue(forKey: id),
              let completion = waiting[key]?.removeValue(forKey: id) else { return }
        if waiting[key]?.isEmpty == true {
            waiting[key] = nil
            lanes[key] = nil
            scheduler.cancel(job(key))
        }
        completion(nil)
    }

    /// Moves a waiting decode to a sooner lane.
    public func promote(_ url: URL, to lane: WorkScheduler.Lane) {
        for key in lanes.keys where key.url == url {
            promote(key, to: lane)
        }
    }

    private func promote(_ key: Key, to lane: WorkScheduler.Lane) {
        guard let current = lanes[key], lane < current else { return }
        lanes[key] = lane
        scheduler.promote(job(key), to: lane)
    }

    private func job(_ key: Key) -> String {
        keyPrefix + "thumb:" + (key.edit.map { "\($0):" } ?? "") + key.url.path
    }

    private func finish(_ key: Key, _ item: LibraryItem, _ image: CGImage?) {
        lanes[key] = nil
        let completions = waiting.removeValue(forKey: key) ?? [:]
        for id in completions.keys {
            requested.removeValue(forKey: id)
        }
        if let image {
            insert(image, for: key, item)
        } else if let edit = key.edit {
            renders?.missing(item.url, edit)
        }
        for completion in completions.values {
            completion(image)
        }
    }

    /// From the library's store, else from the pack, else decoded from the photo and added to the
    /// pack; with `edit`, the store's render of it, or nil when it has none. A thumbnail to keep is
    /// always one decoded from a JPEG, the store's or the pack's: ImageIO holds those pixels in
    /// purgeable memory, which the system can take back (ImageIO decodes them again when drawn) and
    /// doesn't count against the app, so a thumbnail costs about 33 KB of footprint rather than its
    /// 96 KB bitmap.
    nonisolated static func load(
        _ item: LibraryItem, store: (StoreThumbnails, ContentKey)? = nil, edit: EditDigest? = nil,
        packs: ThumbnailPacks, decode: (URL, Int) -> CGImage?, keep: Bool = true,
    ) -> CGImage? {
        if let edit {
            guard let (thumbnails, key) = store else { return nil }
            return thumbnails.image(
                for: key, tier: .grid, edit: edit, size: item.size, modified: item.modified, pixelSize: pixelSize,
            )
        }
        if let (thumbnails, key) = store, let image = thumbnails.image(
            for: item.url, key: key, size: item.size, modified: item.modified, pixelSize: pixelSize,
        ) {
            return image
        }
        if let jpeg = packs.jpeg(for: item.url, size: item.size, modified: item.modified),
           let image = ThumbnailPacks.decode(jpeg) {
            return image
        }
        guard let image = decode(item.url, pixelSize) else { return nil }
        guard let jpeg = ThumbnailPacks.encode(image) else { return image }
        packs.store(jpeg, for: item.url, size: item.size, modified: item.modified)
        return keep ? ThumbnailPacks.decode(jpeg) ?? image : image
    }

    // MARK: - Memory

    private func insert(_ image: CGImage, for key: Key, _ item: LibraryItem) {
        if let old = cache[key] {
            used -= old.cost
        }
        tick += 1
        let cost = image.bytesPerRow * image.height
        cache[key] = Entry(image: image, cost: cost, size: item.size, modified: item.modified, used: tick)
        used += cost
        if used > budget {
            trim(to: budget * 3 / 4)
        }
    }

    /// Drops the least recently used thumbnails, except those on screen, until `bytes` are held.
    public func trim(to bytes: Int) {
        guard used > bytes else { return }
        let candidates = cache.filter { !protected.contains($0.key.url) }.sorted { $0.value.used < $1.value.used }
        for (key, entry) in candidates {
            guard used > bytes else { break }
            cache.removeValue(forKey: key)
            used -= entry.cost
        }
    }

    /// Forgets every thumbnail held in memory (another folder opened).
    public func removeAll() {
        cache = [:]
        used = 0
    }

    // MARK: - Warming

    /// Decodes these photos' thumbnails into their packs on the background lane, replacing what
    /// was queued. Nothing is kept in memory.
    public func warm(_ items: [LibraryItem]) {
        warmGeneration += 1
        scheduler.cancel(prefix: keyPrefix + "warm:")
        warmQueue = items.filter { $0.isLocal && library?($0) == nil }
        warmHead = 0
        warming = 0
        pumpWarming()
    }

    public func stopWarming() {
        warm([])
    }

    /// Photos still queued for warming.
    public var warmingRemaining: Int {
        warmQueue.count - warmHead
    }

    /// Warming jobs queued or running.
    public var isWarming: Bool {
        warmingRemaining > 0 || warming > 0
    }

    private func pumpWarming() {
        let generation = warmGeneration
        let (packs, decode) = (packs, decode)
        while warming < scheduler.widths.background, warmHead < warmQueue.count {
            let batch = Array(warmQueue[warmHead ..< min(warmHead + Self.warmBatch, warmQueue.count)])
            warmHead += batch.count
            warming += 1
            scheduler.submit(
                .background, key: keyPrefix + "warm:\(generation):\(warmHead)",
                onCancel: { Task { @MainActor [weak self] in self?.warmed(generation) } },
                {
                    for item in batch where !packs.contains(item.url, size: item.size, modified: item.modified) {
                        _ = Self.load(item, packs: packs, decode: decode, keep: false)
                    }
                    Task { @MainActor [weak self] in self?.warmed(generation) }
                },
            )
        }
        if warmHead >= warmQueue.count, warming == 0, !warmQueue.isEmpty {
            warmQueue = []
            warmHead = 0
        }
    }

    private func warmed(_ generation: Int) {
        guard generation == warmGeneration else { return }
        warming -= 1
        pumpWarming()
    }
}
