import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo's image at a store tier's size, encoded for the store: scaled down so its long edge is
/// the tier's (never up), upright as it's given, in its own RGB colour space.
public struct StoreImageEncoder: Sendable, Hashable {
    public enum Codec: String, Sendable, Hashable, CaseIterable {
        case jpeg
        case heic

        var type: UTType {
            switch self {
            case .jpeg: .jpeg
            case .heic: .heic
            }
        }
    }

    /// JPEG for both tiers, as measured on the CC0 raws' previews: at the grid's size it decodes in
    /// 0.8 ms to HEIC's 5, and 16 threads decode 10,000 a second to HEIC's 650, which the grid
    /// needs as it scrolls; at the preview's, 16 ms to 43 or more. HEIC is a third smaller at the
    /// same quality and takes 34 ms to encode to JPEG's 0.8.
    public static let defaultCodec = Codec.jpeg

    /// On the CC0 raws' previews, a grid thumbnail at 0.5 is about 22 KB and looks as it does at
    /// 0.75 at its own size; a preview at 0.6 is about 560 KB and keeps the fine texture that 0.4
    /// and 0.5 soften. So a million photos' grid tier takes about 22 GB, and a 10 GB preview
    /// budget holds about 18,000 previews.
    public static func defaultQuality(for tier: PhotoStore.Tier) -> Double {
        switch tier {
        case .grid: 0.5
        case .preview: 0.6
        }
    }

    public var codec: Codec
    /// ImageIO's lossy compression quality, 0 to 1; nil for each tier's default.
    public var quality: Double?

    public init(codec: Codec = StoreImageEncoder.defaultCodec, quality: Double? = nil) {
        self.codec = codec
        self.quality = quality
    }

    /// `image` fitted to the tier and encoded; nil when it can't be.
    public func encode(_ image: CGImage, for tier: PhotoStore.Tier) -> Data? {
        let quality = quality ?? Self.defaultQuality(for: tier)
        return Self.fitted(image, to: tier.pixelSize).flatMap { encode($0, quality: quality) }
    }

    /// `image` encoded at its own size.
    public func encode(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, codec.type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary,
        )
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A stored image, decoded now rather than when first drawn, at its own size. It's decoded as a
    /// thumbnail no larger than the image: ImageIO decodes those on every thread at once, where it
    /// decodes whole images (`CGImageSourceCreateImageAtIndex`) one at a time across the process.
    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1 << 14,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A `width` by `height` image's size once its long edge is at most `edge`.
    public static func size(fitting width: Int, _ height: Int, in edge: Int) -> (width: Int, height: Int) {
        let long = max(width, height)
        guard long > edge, edge > 0 else { return (width, height) }
        let scale = Double(edge) / Double(long)
        let scaled = { (side: Int) in side == long ? edge : max(Int((Double(side) * scale).rounded()), 1) }
        return (scaled(width), scaled(height))
    }

    /// `image` scaled down so its long edge is `edge`, or itself when it's no longer.
    public static func fitted(_ image: CGImage, to edge: Int) -> CGImage? {
        let (width, height) = size(fitting: image.width, image.height, in: edge)
        guard width != image.width || height != image.height else { return image }
        let own = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        for space in [own, CGColorSpace(name: CGColorSpace.sRGB)].compactMap(\.self) {
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            ) else { continue }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        return nil
    }
}
