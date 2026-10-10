import CoreGraphics
import Foundation
import RedlampDocument
import RedlampLibrary

/// Photos' previews at screen size, for the Library loupe and for Develop until a photo's render lands:
/// for a photo the library shows, its store's preview tier (LIB-09), made there first when it has none,
/// or its render of the photo's edit once `renders` has made it (LIB-17); for any other, its embedded
/// preview. They're decoded off the main thread. The last few stay in memory, kept by the edit they show.
/// Asking for one photo's drops what's waiting for another's, and held arrow keys read the next ones ahead
/// (`prefetch`, LIB-16), each step dropping what the one before asked for and hasn't started: decoding is
/// latest-wins, so held keys decode where they're going rather than where they've been.
@MainActor
public final class PhotoPreviews {
    /// The long edge previews are decoded at: the store's preview tier.
    public nonisolated static let pixelSize = PhotoStore.Tier.preview.pixelSize
    /// The previews kept: the photo shown, the two before it and those read ahead.
    static let kept = 5
    /// How many photos ahead of held arrow keys have their previews read.
    static let ahead = 2

    /// The store and content key of a photo the library shows; nil for any other.
    var library: (@MainActor (LibraryItem) -> (StoreThumbnails, ContentKey)?)?
    /// Which edit each photo's preview shows.
    weak var renders: EditRenders?
    private let scheduler: WorkScheduler
    private let decode: @Sendable (URL, Int) -> CGImage?
    /// Starts every key this instance gives `scheduler`, which others share.
    private let keyPrefix = "preview \(UUID().uuidString) "
    private var recent: [Entry] = []
    /// The decodes under way: the one `request` waits for, and those read ahead.
    private var decoding: [Key: Decode] = [:]
    /// The preview `request` waits for.
    private var asked: Key?
    /// The previews the last `prefetch` read ahead.
    private var ahead: Set<Key> = []
    private var generation = 0

    private struct Key: Hashable {
        let url: URL
        let edit: EditDigest?
    }

    private struct Decode {
        let item: LibraryItem
        var completions: [(CGImage?) -> Void]
        let generation: Int
    }

    private struct Entry {
        let url: URL
        let size: Int64
        let modified: Date
        let edit: EditDigest?
        let image: CGImage
    }

    /// `decode` is the engine's `decodeThumbnail(for:maxPixelSize:)`.
    init(scheduler: WorkScheduler, decode: @escaping @Sendable (URL, Int) -> CGImage?) {
        self.scheduler = scheduler
        self.decode = decode
    }

    /// The photo's preview, if it's one of the last decoded: of the edit it's to show, else, until that's
    /// decoded, of its embedded preview.
    public func cached(_ url: URL) -> CGImage? {
        cachedPreview(url)?.image
    }

    /// `cached(_:)`'s preview, and the edit it shows (nil for the embedded preview).
    func cachedPreview(_ url: URL) -> (image: CGImage, edit: EditDigest?)? {
        let edit = renders?.shownEdit(at: url)
        guard let entry = recent.last(where: { $0.url == url }), entry.edit == edit || entry.edit == nil else {
            return nil
        }
        return (entry.image, entry.edit)
    }

    /// Asks for `item`'s preview; `completion` gets it on the main thread, or nil if it can't be made or
    /// another photo's is asked for first. A preview being read ahead is moved up rather than read again.
    public func request(_ item: LibraryItem, completion: @escaping (CGImage?) -> Void) {
        let key = key(item)
        if let image = kept(item, key) {
            completion(image)
            return
        }
        if asked != key {
            cancel()
        }
        guard item.isLocal, !item.isSettling else {
            completion(nil)
            return
        }
        asked = key
        if decoding[key] != nil {
            decoding[key]?.completions.append(completion)
            scheduler.promote(job(key), to: .onScreen)
            return
        }
        start(item, key, lane: .onScreen, completions: [completion])
    }

    /// Drops the preview being waited for, unless it's being read ahead; its requests complete with nil.
    public func cancel() {
        guard let key = asked else { return }
        asked = nil
        guard let waiting = decoding[key] else { return }
        if ahead.contains(key) {
            decoding[key]?.completions = []
        } else {
            decoding[key] = nil
            scheduler.cancel(job(key))
        }
        for completion in waiting.completions {
            completion(nil)
        }
    }

    /// Reads these photos' previews ahead, in order: those held arrow keys reach next, the first `soon` on the
    /// on-screen lane and the rest on the look-ahead lane. What the last call read ahead and these leave out is
    /// dropped unless it has started or is asked for.
    public func prefetch(_ items: [LibraryItem], soon: Int = 0) {
        let keys = items.map(key)
        let wanted = Set(keys)
        for key in ahead.subtracting(wanted) where key != asked && decoding[key]?.completions.isEmpty == true {
            decoding[key] = nil
            scheduler.cancel(job(key))
        }
        ahead = wanted
        for (place, (item, key)) in zip(items, keys).enumerated() where item.isLocal && !item.isSettling {
            let lane: WorkScheduler.Lane = place < soon ? .onScreen : .lookAhead
            if decoding[key] != nil {
                scheduler.promote(job(key), to: lane)
            } else if kept(item, key) == nil {
                start(item, key, lane: lane, completions: [])
            }
        }
    }

    /// Whether a preview of `url` is being decoded, asked for or read ahead, for the tests.
    func isDecoding(_ url: URL) -> Bool {
        decoding.keys.contains { $0.url == url }
    }

    private func key(_ item: LibraryItem) -> Key {
        Key(url: item.url, edit: renders?.shownEdit(for: item))
    }

    /// The preview of `key` in memory, if it still matches the file.
    private func kept(_ item: LibraryItem, _ key: Key) -> CGImage? {
        recent
            .last { $0.url == key.url && $0.edit == key.edit && $0.size == item.size && $0.modified == item.modified }?
            .image
    }

    private func job(_ key: Key) -> String {
        keyPrefix + (key.edit.map { "\($0):" } ?? "") + key.url.path
    }

    private func start(
        _ item: LibraryItem, _ key: Key, lane: WorkScheduler.Lane, completions: [(CGImage?) -> Void],
    ) {
        generation += 1
        let generation = generation
        decoding[key] = Decode(item: item, completions: completions, generation: generation)
        let (decode, store) = (decode, library?(item))
        scheduler.submit(lane, key: job(key)) {
            let image = Self.load(item, store: store, edit: key.edit, decode: decode)
            Task { @MainActor [weak self] in self?.finish(key, image, generation: generation) }
        }
    }

    /// A decode done: kept if it's still wanted, asked for or read ahead, and handed to whoever waits.
    private func finish(_ key: Key, _ image: CGImage?, generation: Int) {
        guard let done = decoding[key], done.generation == generation else { return }
        decoding[key] = nil
        let wanted = asked == key || ahead.contains(key)
        if asked == key {
            asked = nil
        }
        let item = done.item
        if let image, wanted {
            recent.removeAll { $0.url == item.url }
            recent.append(Entry(url: item.url, size: item.size, modified: item.modified, edit: key.edit, image: image))
            if recent.count > Self.kept {
                recent.removeFirst(recent.count - Self.kept)
            }
        } else if image == nil, let edit = key.edit {
            renders?.missing(item.url, edit)
        }
        for completion in done.completions {
            completion(image)
        }
    }

    /// From the store's preview tier, made there first when it has none, else decoded from the photo; with
    /// `edit`, the store's render of it, or nil when it has none.
    nonisolated static func load(
        _ item: LibraryItem, store: (StoreThumbnails, ContentKey)?, edit: EditDigest? = nil,
        decode: @escaping @Sendable (URL, Int) -> CGImage?,
    ) -> CGImage? {
        if let edit {
            guard let (thumbnails, key) = store else { return nil }
            return thumbnails.image(
                for: key, tier: .preview, edit: edit, size: item.size, modified: item.modified, pixelSize: pixelSize,
            )
        }
        if let (thumbnails, key) = store {
            let tier = PhotoStore.Tier.preview
            let maker = StoreThumbnailMaker(store: thumbnails.store, tier: tier, image: StoreThumbnails.source(decode))
            if let data = thumbnails.store.data(for: key, tier: tier, size: item.size, modified: item.modified)
                ?? (maker.make(item.url, key: key, head: Data())
                    ? thumbnails.store.data(for: key, tier: tier, size: item.size, modified: item.modified) : nil),
                let image = StoreThumbnails.decode(data, pixelSize: pixelSize) {
                return image
            }
        }
        return decode(item.url, pixelSize)
    }
}
