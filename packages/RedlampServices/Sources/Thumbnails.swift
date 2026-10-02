import CoreGraphics
import Foundation
import ImageIO
import LibRaw
import RedlampEngineAPI

public enum Thumbnails {
    /// The file's embedded preview (or a downsampled decode when there is none), with
    /// orientation applied. Fast enough for filmstrips and the pre-decode placeholder.
    ///
    /// A raw file's thumbnail comes from the smallest JPEG preview it embeds that is still
    /// `maxPixelSize` on its long edge, found by LibRaw. ImageIO always decodes the largest
    /// (often full size), which is 3 to 11 times slower for cameras that also embed a smaller one
    /// (`research/prototypes/thumbnails`). Anything else goes through ImageIO.
    public static func thumbnail(for url: URL, maxPixelSize: Int) -> CGImage? {
        if SupportedFormats.isRaw(url), let image = embeddedPreview(of: url, maxPixelSize: maxPixelSize) {
            return image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A JPEG preview embedded in a raw file.
    struct Preview: Equatable {
        var offset: Int
        var length: Int
        var width: Int
        var height: Int
    }

    /// The raw file's smallest JPEG preview at least `maxPixelSize` on its long edge, decoded at
    /// that size and turned upright. The file is mapped once: LibRaw parses it from the mapping
    /// and ImageIO decodes the preview straight from it. A copy of the preview (1 to 5 MB) was
    /// most of a decode's memory, and with every core decoding, malloc kept the copies' high-water
    /// mark in the footprint after they were freed.
    static func embeddedPreview(of url: URL, maxPixelSize: Int) -> CGImage? {
        guard let file = try? NSData(contentsOf: url, options: .alwaysMapped),
              let (preview, flip) = smallestPreview(in: Data(referencing: file), atLeast: maxPixelSize),
              let jpeg = bytes(of: preview, in: file),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil)
        else { return nil }
        // The preview itself, never its own (often 160 px) EXIF thumbnail; scaled as it decodes.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let tagged = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        return oriented(image, exifOrientation: tagged != 1 ? tagged : exifOrientation(libRawFlip: flip))
    }

    /// The preview's bytes where they are in the mapped file, which they keep mapped for as long as
    /// anything (ImageIO) holds them.
    static func bytes(of preview: Preview, in file: NSData) -> Data? {
        guard preview.offset >= 0, preview.length > 0, preview.offset + preview.length <= file.length else {
            return nil
        }
        return Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: file.bytes + preview.offset), count: preview.length,
            deallocator: .custom { _, _ in withExtendedLifetime(file) {} },
        )
    }

    /// The preview to decode and the photo's rotation (LibRaw's `flip`), from the file's metadata.
    static func smallestPreview(in file: Data, atLeast maxPixelSize: Int) -> (Preview, Int32)? {
        guard let raw = libraw_init(0) else { return nil }
        defer { libraw_close(raw) }
        let opened = file.withUnsafeBytes { libraw_open_buffer(raw, $0.baseAddress, $0.count) }
        guard opened == LIBRAW_SUCCESS.rawValue else { return nil }
        let count = min(Int(raw.pointee.thumbs_list.thumbcount), Int(LIBRAW_THUMBNAIL_MAXCOUNT))
        let previews = withUnsafeBytes(of: raw.pointee.thumbs_list.thumblist) { bytes in
            Array(bytes.bindMemory(to: libraw_thumbnail_item_t.self).prefix(count))
        }
        .filter { $0.tformat == LIBRAW_INTERNAL_THUMBNAIL_JPEG && $0.tlength > 0 }
        .map {
            Preview(offset: Int($0.toffset), length: Int($0.tlength), width: Int($0.twidth), height: Int($0.theight))
        }
        guard let chosen = choose(previews, atLeast: maxPixelSize) else { return nil }
        return (chosen, raw.pointee.sizes.flip)
    }

    /// The smallest preview whose long edge is at least `maxPixelSize`; one of unknown size only
    /// when none is known to be big enough.
    static func choose(_ previews: [Preview], atLeast maxPixelSize: Int) -> Preview? {
        let edge = { (preview: Preview) in max(preview.width, preview.height) }
        return previews.filter { edge($0) >= maxPixelSize }.min { edge($0) < edge($1) }
            ?? previews.first { edge($0) == 0 }
    }

    /// LibRaw's `flip` as an EXIF orientation: 3 is 180°, 5 is 90° counterclockwise, 6 clockwise.
    static func exifOrientation(libRawFlip flip: Int32) -> Int {
        switch flip {
        case 3: 3
        case 5: 8
        case 6: 6
        default: 1
        }
    }

    /// `image` turned upright for its EXIF orientation (1 to 8).
    static func oriented(_ image: CGImage, exifOrientation orientation: Int) -> CGImage? {
        guard (2 ... 8).contains(orientation) else { return image }
        let (width, height) = (CGFloat(image.width), CGFloat(image.height))
        let swaps = orientation >= 5
        let size = swaps ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
              ) else { return nil }
        // Transforms in Core Graphics' bottom-left coordinates, as `CGImagePropertyOrientation`
        // describes them.
        var transform = CGAffineTransform.identity
        switch orientation {
        case 2: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        case 3: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 4: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        case 5: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: height, ty: width)
        case 6: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        case 7: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        default: break
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
