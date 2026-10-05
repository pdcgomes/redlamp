import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI
import RedlampLibrary

/// The filmstrip's thumbnails of the library's photos (LIB-09): from the store's grid tier, made
/// for it first when it hasn't one yet, as the indexer makes them. A raw's comes from LibRaw's
/// smallest embedded preview big enough for the grid (`thumbnail`, the engine's), anything else's
/// from ImageIO.
public struct StoreThumbnails: Sendable {
    public let store: PhotoStore
    public let maker: StoreThumbnailMaker

    /// `thumbnail` is the engine's `decodeThumbnail(for:maxPixelSize:)`.
    public init(store: PhotoStore, thumbnail: @escaping @Sendable (URL, Int) -> CGImage?) {
        self.store = store
        maker = StoreThumbnailMaker(store: store, image: Self.source(thumbnail))
    }

    /// The image the store keeps of a photo: the engine's thumbnail for raws and focus stacks, which
    /// ImageIO can't read the way LibRaw does, ImageIO's for the rest.
    static func source(_ thumbnail: @escaping @Sendable (URL, Int) -> CGImage?) -> StoreThumbnailMaker.ImageSource {
        { photo, bytes, maxPixelSize in
            if SupportedFormats.isRaw(photo) || SupportedFormats.isStack(photo) {
                return thumbnail(photo, maxPixelSize)
            }
            return StoreThumbnailMaker.imageIO(photo, bytes, maxPixelSize)
        }
    }

    /// The photo's thumbnail at most `pixelSize` on its long edge, from the store's record of the
    /// file as it is (`size` bytes, modified at `modified`), made first when the store has none;
    /// nil when it can't be made. It blocks: only ever off the main thread.
    public func image(for photo: URL, key: ContentKey, size: Int64, modified: Date, pixelSize: Int) -> CGImage? {
        if let data = store.data(for: key, tier: .grid, size: size, modified: modified) {
            return Self.decode(data, pixelSize: pixelSize)
        }
        guard maker.make(photo, key: key, head: Data()),
              let data = store.data(for: key, tier: .grid, size: size, modified: modified)
        else { return nil }
        return Self.decode(data, pixelSize: pixelSize)
    }

    /// A stored image decoded now, at most `pixelSize` on its long edge, as `StoreImageEncoder.decode`
    /// decodes: as a thumbnail, which ImageIO decodes on every thread at once.
    static func decode(_ data: Data, pixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
