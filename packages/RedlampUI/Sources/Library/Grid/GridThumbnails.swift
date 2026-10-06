import CoreGraphics
import Foundation
import RedlampDocument
import RedlampLibrary

/// The grid's thumbnails, at the size its cells need (LIB-14): for a photo the library shows, the store's
/// grid tier up to its 384 pixels and its preview tier beyond, made there first when it has none; for any
/// other, the filmstrip's pack at the smallest size and the photo's embedded preview beyond. Each is
/// decoded off the main thread and drawn there in the window's colour space, so Core Animation shows it
/// as it is rather than converting it on the main thread as it commits. An edited photo's, once `renders`
/// has rendered its edit, is that render's tier (LIB-17). Kept in memory by the edit they show, within a
/// byte budget, the photos on screen last to go.
@MainActor
final class GridThumbnails {
    /// The long edges thumbnails are decoded at; a cell takes the smallest at least as large as its image.
    nonisolated static let edges = [256, 384, 512, 768]

    static func edge(forPixels pixels: CGFloat) -> Int {
        edges.first { CGFloat($0) >= pixels } ?? edges[edges.count - 1]
    }

    /// A photo's thumbnail at `edge`, showing `edit`'s render, or with none its embedded preview.
    struct Key: Hashable {
        let url: URL
        let edge: Int
        let edit: EditDigest?
    }

    private struct Entry {
        let image: CGImage
        let cost: Int
        let size: Int64
        let modified: Date
        var used: UInt64
    }

    let budget: Int
    /// The photos on screen, which trimming keeps.
    var protected: Set<URL> = []
    /// The window's colour space; thumbnails drawn for another are dropped.
    var colorSpace: CGColorSpace? {
        didSet {
            if colorSpace != oldValue {
                removeAll()
            }
        }
    }

    private let scheduler: WorkScheduler
    private let decode: @Sendable (URL, Int) -> CGImage?
    private let store: @MainActor (LibraryItem) -> (StoreThumbnails, ContentKey)?
    private weak var renders: EditRenders?
    private let packs: ThumbnailPacks
    private var cache: [Key: Entry] = [:]
    private var used = 0
    private var tick: UInt64 = 0
    private var waiting: [Key: [UInt64: (CGImage?) -> Void]] = [:]
    private var requested: [UInt64: Key] = [:]
    private var lanes: [Key: WorkScheduler.Lane] = [:]
    private var nextID: UInt64 = 0
    /// Bumped when the cache is emptied: decodes started before then are dropped.
    private var generation = 0

    init(
        scheduler: WorkScheduler, packs: ThumbnailPacks, budget: Int = 64 << 20,
        store: @escaping @MainActor (LibraryItem) -> (StoreThumbnails, ContentKey)?, renders: EditRenders? = nil,
        decode: @escaping @Sendable (URL, Int) -> CGImage?,
    ) {
        self.scheduler = scheduler
        self.packs = packs
        self.budget = budget
        self.store = store
        self.renders = renders
        self.decode = decode
    }

    var memoryUsed: Int {
        used
    }

    /// The edit `item`'s thumbnails show: its edit's digest once that's rendered, nil for its embedded
    /// preview.
    func edit(for item: LibraryItem) -> EditDigest? {
        renders?.shownEdit(for: item)
    }

    /// The thumbnail at `edge`, if it's in memory, still matches the file and shows the edit it's to show.
    func cached(_ item: LibraryItem, edge: Int) -> CGImage? {
        entry(Key(url: item.url, edge: edge, edit: edit(for: item)), item)
    }

    /// What's shown while the thumbnail at `edge` decodes, and the edit it shows: the largest in memory
    /// smaller than `edge`, else, until the edit's render is decoded, the embedded preview's at `edge` or
    /// smaller.
    func standIn(_ item: LibraryItem, below edge: Int) -> (image: CGImage, edit: EditDigest?)? {
        let wanted = edit(for: item)
        for smaller in Self.edges.reversed() where smaller < edge {
            if let image = entry(Key(url: item.url, edge: smaller, edit: wanted), item) {
                return (image, wanted)
            }
        }
        guard wanted != nil else { return nil }
        for candidate in Self.edges.reversed() where candidate <= edge {
            if let image = entry(Key(url: item.url, edge: candidate, edit: nil), item) {
                return (image, nil)
            }
        }
        return nil
    }

    private func entry(_ key: Key, _ item: LibraryItem) -> CGImage? {
        guard var entry = cache[key], entry.size == item.size, entry.modified == item.modified else { return nil }
        tick += 1
        entry.used = tick
        cache[key] = entry
        return entry.image
    }

    /// Asks for `item`'s thumbnail at `edge`; `completion` gets it on the main thread, or nil if it
    /// can't be made or the request is cancelled. Returns an id for `cancel`.
    @discardableResult
    func request(
        _ item: LibraryItem, edge: Int, lane: WorkScheduler.Lane = .onScreen,
        completion: @escaping (CGImage?) -> Void,
    ) -> UInt64 {
        nextID += 1
        let id = nextID
        if let image = cached(item, edge: edge) {
            completion(image)
            return id
        }
        guard item.isLocal, !item.isSettling else {
            completion(nil)
            return id
        }
        let key = Key(url: item.url, edge: edge, edit: edit(for: item))
        requested[id] = key
        if waiting[key] != nil {
            waiting[key]?[id] = completion
            promote(key, to: lane)
            return id
        }
        waiting[key] = [id: completion]
        lanes[key] = lane
        let (store, packs, decode, space, generation) = (store(item), packs, decode, colorSpace, generation)
        scheduler.submit(lane, key: Self.job(key)) {
            let image = Self.load(item, edge: edge, store: store, edit: key.edit, packs: packs, decode: decode)
                .flatMap { Self.drawn($0, in: space) }
            Task { @MainActor [weak self] in self?.finish(key, item, image, generation: generation) }
        }
        return id
    }

    /// Cancels one request, which completes with nil; the decode is dropped if nobody else waits for it.
    func cancel(_ id: UInt64) {
        guard let key = requested.removeValue(forKey: id),
              let completion = waiting[key]?.removeValue(forKey: id) else { return }
        if waiting[key]?.isEmpty == true {
            waiting[key] = nil
            lanes[key] = nil
            scheduler.cancel(Self.job(key))
        }
        completion(nil)
    }

    private func promote(_ key: Key, to lane: WorkScheduler.Lane) {
        guard let current = lanes[key], lane < current else { return }
        lanes[key] = lane
        scheduler.promote(Self.job(key), to: lane)
    }

    private static func job(_ key: Key) -> String {
        "grid:\(key.edge):" + (key.edit.map { "\($0):" } ?? "") + key.url.path
    }

    private func finish(_ key: Key, _ item: LibraryItem, _ image: CGImage?, generation: Int) {
        lanes[key] = nil
        let completions = waiting.removeValue(forKey: key) ?? [:]
        for id in completions.keys {
            requested.removeValue(forKey: id)
        }
        if let image, generation == self.generation {
            insert(image, for: key, item)
        } else if image == nil, let edit = key.edit {
            renders?.missing(item.url, edit)
        }
        for completion in completions.values {
            completion(generation == self.generation ? image : nil)
        }
    }

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
    func trim(to bytes: Int) {
        guard used > bytes else { return }
        let candidates = cache.filter { !protected.contains($0.key.url) }.sorted { $0.value.used < $1.value.used }
        for (key, entry) in candidates {
            guard used > bytes else { break }
            cache.removeValue(forKey: key)
            used -= entry.cost
        }
    }

    func removeAll() {
        cache = [:]
        used = 0
        generation += 1
    }

    // MARK: - Decoding

    /// The photo's thumbnail at most `edge` pixels on its long edge; with `edit`, the store's render of it,
    /// or nil when it has none. It blocks: only ever off the main thread.
    nonisolated static func load(
        _ item: LibraryItem, edge: Int, store: (StoreThumbnails, ContentKey)?, edit: EditDigest? = nil,
        packs: ThumbnailPacks, decode: @escaping @Sendable (URL, Int) -> CGImage?,
    ) -> CGImage? {
        if let edit {
            guard let (thumbnails, key) = store else { return nil }
            let tier: PhotoStore.Tier = edge > PhotoStore.Tier.grid.pixelSize ? .preview : .grid
            return thumbnails.image(
                for: key, tier: tier, edit: edit, size: item.size, modified: item.modified,
                pixelSize: min(edge, tier.pixelSize),
            )
        }
        if let (thumbnails, key) = store {
            let grid = PhotoStore.Tier.grid.pixelSize
            if edge > grid, let preview = preview(item, edge: edge, thumbnails: thumbnails, key: key, decode: decode) {
                return preview
            }
            return thumbnails.image(
                for: item.url, key: key, size: item.size, modified: item.modified, pixelSize: min(edge, grid),
            )
        }
        if edge <= edges[0] {
            if let jpeg = packs.jpeg(for: item.url, size: item.size, modified: item.modified),
               let image = StoreThumbnails.decode(jpeg, pixelSize: edge) {
                return image
            }
            return ThumbnailLoader.load(item, packs: packs, decode: decode)
        }
        return decode(item.url, edge)
    }

    /// From the store's preview tier, made there first when it has none.
    private nonisolated static func preview(
        _ item: LibraryItem, edge: Int, thumbnails: StoreThumbnails, key: ContentKey,
        decode: @escaping @Sendable (URL, Int) -> CGImage?,
    ) -> CGImage? {
        let tier = PhotoStore.Tier.preview
        let stored = { thumbnails.store.data(for: key, tier: tier, size: item.size, modified: item.modified) }
        if let data = stored() {
            return StoreThumbnails.decode(data, pixelSize: edge)
        }
        let maker = StoreThumbnailMaker(store: thumbnails.store, tier: tier, image: StoreThumbnails.source(decode))
        guard maker.make(item.url, key: key, head: Data()), let data = stored() else { return nil }
        return StoreThumbnails.decode(data, pixelSize: edge)
    }

    /// `image` drawn in `space` as Core Animation takes it without converting it: 8-bit BGRA, opaque.
    nonisolated static func drawn(_ image: CGImage, in space: CGColorSpace?) -> CGImage? {
        guard let space, let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) else { return image }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
}
