import CoreGraphics
import Foundation
import ImageIO

/// Makes photos' thumbnails for the store as the indexer reads them: `thumbnails` is
/// `LibraryIndexer`'s closure. Each photo's image comes from `image`, by default ImageIO's
/// thumbnail of the file (for a raw, of its largest embedded preview), and is stored under the
/// photo's content key with its file's size and date, unless the store has it already.
public struct StoreThumbnailMaker: Sendable {
    /// The photo's image, upright, at most `maxPixelSize` on its long edge. `bytes` is the whole
    /// file when the indexer's head held all of it, else nil.
    public typealias ImageSource = @Sendable (_ photo: URL, _ bytes: Data?, _ maxPixelSize: Int) -> CGImage?

    public let store: PhotoStore
    public let tier: PhotoStore.Tier
    public let encoder: StoreImageEncoder
    private let fileSystem: any LibraryFileSystem
    private let image: ImageSource

    public init(
        store: PhotoStore, tier: PhotoStore.Tier = .grid, encoder: StoreImageEncoder = StoreImageEncoder(),
        fileSystem: any LibraryFileSystem = LocalFileSystem(),
        image: @escaping ImageSource = StoreThumbnailMaker.imageIO,
    ) {
        self.store = store
        self.tier = tier
        self.encoder = encoder
        self.fileSystem = fileSystem
        self.image = image
    }

    /// For `LibraryIndexer(thumbnails:)`.
    public var thumbnails: LibraryIndexer.Thumbnails {
        { photo, key, head in make(photo, key: key, head: head) }
    }

    /// Makes and stores the photo's image for the tier unless the store has one of the file as it
    /// is now; whether the store has it afterwards. `head` is the file's first bytes, as read.
    @discardableResult
    public func make(_ photo: URL, key: ContentKey, head: Data) -> Bool {
        guard let file = try? fileSystem.attributes(of: photo) else { return false }
        if store.contains(key, tier: tier, size: file.size, modified: file.modified) {
            return true
        }
        let bytes = Int64(head.count) >= file.size ? head.prefix(Int(file.size)) : nil
        guard let image = image(photo, bytes, tier.pixelSize), let payload = encoder.encode(image, for: tier) else {
            return false
        }
        return store.store(payload, for: key, tier: tier, size: file.size, modified: file.modified)
    }

    /// ImageIO's thumbnail of the photo, made from its image (a raw's largest embedded preview)
    /// rather than any smaller thumbnail it embeds, and turned upright.
    public static func imageIO(_ photo: URL, _ bytes: Data?, _ maxPixelSize: Int) -> CGImage? {
        let source = bytes.map { CGImageSourceCreateWithData($0 as CFData, nil) }
            ?? CGImageSourceCreateWithURL(photo as CFURL, nil)
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
