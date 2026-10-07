import AppKit
import CoreGraphics
import Foundation
import RedlampDocument
import RedlampLibrary

/// The import grid's thumbnails (LIB-27): the previews browsing made into the store, decoded at the
/// cell's size on the scheduler's on-screen lane, and kept in memory within a byte budget.
@MainActor
final class ImportThumbnails {
    let store: PhotoStore
    let pixelSize: Int
    private let scheduler: WorkScheduler
    private let cache = NSCache<NSString, CGImage>()
    private var loading: Set<String> = []

    /// The long edge thumbnails are decoded at: a cell's image at 2x.
    static let standardPixelSize = 320

    init(
        store: PhotoStore,
        pixelSize: Int = ImportThumbnails.standardPixelSize,
        scheduler: WorkScheduler = LibraryIndexer.scheduler,
    ) {
        self.store = store
        self.pixelSize = pixelSize
        self.scheduler = scheduler
        cache.totalCostLimit = 96 << 20
    }

    func image(for photo: ImportPhoto) -> CGImage? {
        cache.object(forKey: photo.id as NSString)
    }

    /// Decodes `photo`'s preview once browsing has made it, and calls `loaded` with it on the main thread.
    func load(_ photo: ImportPhoto, loaded: @escaping @MainActor (String, CGImage) -> Void) {
        guard photo.state == .previewed, let key = photo.primary.contentKey, !loading.contains(photo.id),
              cache.object(forKey: photo.id as NSString) == nil
        else { return }
        let id = photo.id
        loading.insert(id)
        let (store, size, modified, pixelSize) = (store, photo.primary.size, photo.primary.modified, pixelSize)
        Task { [weak self] in
            let image = try? await self?.scheduler.run(.onScreen, key: "import-thumbnail:" + id) {
                store.data(for: key, tier: .grid, size: size, modified: modified)
                    .flatMap { StoreThumbnails.decode($0, pixelSize: pixelSize) }
            }
            guard let self else { return }
            loading.remove(id)
            guard let image = image ?? nil else { return }
            cache.setObject(image, forKey: id as NSString, cost: image.bytesPerRow * image.height)
            loaded(id, image)
        }
    }
}
