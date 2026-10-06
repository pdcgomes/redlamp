import CoreGraphics
import Foundation
import RedlampDocument
import RedlampLibrary

/// Photos' previews at screen size, for the Library loupe and for Develop until a photo's render lands:
/// for a photo the library shows, its store's preview tier (LIB-09), made there first when it has none;
/// for any other, its embedded preview. They're decoded off the main thread. The last two stay in memory,
/// and asking for one photo's drops what's waiting for another's, so held arrow keys decode only where they
/// stop.
@MainActor
public final class PhotoPreviews {
    /// The long edge previews are decoded at: the store's preview tier.
    public nonisolated static let pixelSize = PhotoStore.Tier.preview.pixelSize
    static let kept = 2

    /// The store and content key of a photo the library shows; nil for any other.
    var library: (@MainActor (LibraryItem) -> (StoreThumbnails, ContentKey)?)?
    private let scheduler: WorkScheduler
    private let decode: @Sendable (URL, Int) -> CGImage?
    private var recent: [Entry] = []
    private var waiting: (item: LibraryItem, completions: [(CGImage?) -> Void])?
    private var generation = 0

    private struct Entry {
        let url: URL
        let size: Int64
        let modified: Date
        let image: CGImage
    }

    /// `decode` is the engine's `decodeThumbnail(for:maxPixelSize:)`.
    init(scheduler: WorkScheduler, decode: @escaping @Sendable (URL, Int) -> CGImage?) {
        self.scheduler = scheduler
        self.decode = decode
    }

    /// The photo's preview, if it's one of the last decoded.
    public func cached(_ url: URL) -> CGImage? {
        recent.last { $0.url == url }?.image
    }

    /// Asks for `item`'s preview; `completion` gets it on the main thread, or nil if it can't be made or
    /// another photo's is asked for first.
    public func request(_ item: LibraryItem, completion: @escaping (CGImage?) -> Void) {
        if let entry = recent.last(where: { $0.url == item.url }), entry.size == item.size,
           entry.modified == item.modified {
            completion(entry.image)
            return
        }
        if waiting?.item.url == item.url {
            waiting?.completions.append(completion)
            return
        }
        cancel()
        guard item.isLocal, !item.isSettling else {
            completion(nil)
            return
        }
        generation += 1
        let generation = generation
        waiting = (item, [completion])
        let (decode, store) = (decode, library?(item))
        scheduler.submit(.onScreen, key: Self.key) {
            let image = Self.load(item, store: store, decode: decode)
            Task { @MainActor [weak self] in self?.finish(item, image, generation: generation) }
        }
    }

    /// Drops the preview being waited for; its requests complete with nil.
    public func cancel() {
        guard let waiting else { return }
        self.waiting = nil
        scheduler.cancel(Self.key)
        for completion in waiting.completions {
            completion(nil)
        }
    }

    private static let key = "preview"

    private func finish(_ item: LibraryItem, _ image: CGImage?, generation: Int) {
        guard generation == self.generation, let waiting, waiting.item.url == item.url else { return }
        self.waiting = nil
        if let image {
            recent.removeAll { $0.url == item.url }
            recent.append(Entry(url: item.url, size: item.size, modified: item.modified, image: image))
            if recent.count > Self.kept {
                recent.removeFirst(recent.count - Self.kept)
            }
        }
        for completion in waiting.completions {
            completion(image)
        }
    }

    /// From the store's preview tier, made there first when it has none, else decoded from the photo.
    nonisolated static func load(
        _ item: LibraryItem, store: (StoreThumbnails, ContentKey)?, decode: @escaping @Sendable (URL, Int) -> CGImage?,
    ) -> CGImage? {
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
