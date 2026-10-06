import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI

/// The edit recipe an export carries in its XMP, so the file says how it was made and the edit can
/// be recovered from it ("Edits embedded in exports" in `docs/recipes/sidecar-format.md`).
public struct EmbeddedEdit: Sendable, Hashable {
    /// The namespace of the XMP properties `Recipe`, `FormatVersion` and `ProcessVersion`.
    public static let namespace = "https://redlamp.app/ns/edit/1.0/"
    /// The prefix Redlamp writes. Other tools may rename it, so reading goes by `namespace`.
    public static let prefix = "redlamp"
    /// The most bytes of XMP an edit may take. A bigger edit is left out, never cut short.
    public static let maximumSize = 256_000

    public var recipe: EditRecipe
    /// The format version the recipe was written in: its `version`.
    public var formatVersion: Int

    public init(recipe: EditRecipe, formatVersion: Int = EditRecipe.formatVersion) {
        self.recipe = recipe
        self.formatVersion = formatVersion
    }

    /// Written by a newer Redlamp, so it may hold settings this one can't read or render (a sidecar
    /// like it opens read-only).
    public var isWrittenByNewerVersion: Bool {
        formatVersion > EditRecipe.formatVersion || recipe.requiresNewerProcess
    }
}

// MARK: - Reading

extension EmbeddedEdit {
    /// The edit embedded in the image file at `url`; nil when it has none or it can't be read.
    public static func read(_ url: URL) -> EmbeddedEdit? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            .flatMap { edit(in: $0) }
    }

    /// The edit embedded in an encoded image; nil when it has none or it can't be read.
    public static func read(_ data: Data) -> EmbeddedEdit? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
            .flatMap { edit(in: $0) }
    }

    private static func edit(in source: CGImageSource) -> EmbeddedEdit? {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil),
              let json = recipeJSON(in: metadata).map({ Data($0.utf8) }),
              let recipe = try? JSONDecoder.sidecar.decode(EditRecipe.self, from: json)
        else { return nil }
        let version = (try? JSONDecoder.sidecar.decode(Versions.self, from: json))?.version
        return EmbeddedEdit(recipe: recipe, formatVersion: version ?? 1)
    }

    /// The recipe's `version`, which decoding it doesn't keep.
    private struct Versions: Decodable {
        var version: Int?
    }

    /// `Recipe` in the edit's namespace, whatever prefix the file gives it.
    private static func recipeJSON(in metadata: CGImageMetadata) -> String? {
        var json: String?
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
            guard CGImageMetadataTagCopyNamespace(tag) as String? == namespace,
                  CGImageMetadataTagCopyName(tag) as String? == "Recipe"
            else { return true }
            json = CGImageMetadataTagCopyValue(tag) as? String
            return false
        }
        return json
    }
}

// MARK: - Writing

extension EmbeddedEdit {
    /// Where `ExportMetadata.properties` puts the edit's XMP, for `ExportMetadata.addImage`.
    static var propertyKey: CFString {
        "RedlampEmbeddedEdit" as CFString
    }

    /// The XMP of `recipe`: the recipe as a sidecar's `edit.json` holds it, without whitespace, and
    /// its format and process versions. nil when that takes more than `maximumSize` bytes.
    static func xmp(for recipe: EditRecipe) -> Data? {
        let encoder = JSONEncoder.sidecar
        encoder.outputFormatting.remove(.prettyPrinted)
        guard let json = try? encoder.encode(recipe) else { return nil }
        let metadata = CGImageMetadataCreateMutable()
        guard CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace as CFString, prefix as CFString, nil)
        else { return nil }
        let values = [
            ("Recipe", String(decoding: json, as: UTF8.self)),
            ("FormatVersion", String(EditRecipe.formatVersion)),
            ("ProcessVersion", String(recipe.processVersion)),
        ]
        for (name, value) in values {
            guard CGImageMetadataSetValueWithPath(metadata, nil, "\(prefix):\(name)" as CFString, value as CFString)
            else { return nil }
        }
        guard let xmp = CGImageMetadataCreateXMPData(metadata, nil) as Data?,
              xmp.count <= maximumSize else { return nil }
        return xmp
    }

    /// The XMP to write in a `format` file with `properties`: the tags of each of `parts` (the edit's,
    /// the photo's fields'), or nil if writing them would change how the file's properties read back.
    ///
    /// Given XMP, ImageIO writes it instead of the XMP it would make from `properties`, the only place
    /// it keeps some of them (lens details and a rating; in HEIC and AVIF, every IPTC field). It also
    /// writes EXIF and IPTC fields from what it's given, so handing it all of its own XMP back changes
    /// them. The XMP is the parts', then, with the tags ImageIO matches to whichever properties a file
    /// with only their XMP loses. Each is tried on one pixel in `image`'s pixel format.
    static func xmp(
        adding parts: [Data],
        to properties: [CFString: Any],
        format: ExportFormat,
        like image: CGImage,
    ) -> CGImageMetadata? {
        guard let pixel = pixel(like: image),
              let plain = encode(pixel, format: format, properties: properties),
              let expected = readProperties(plain),
              let xmp = combined(parts),
              let alone = encode(pixel, format: format, properties: properties, metadata: xmp).flatMap(readProperties)
        else { return nil }
        if alone.isEqual(expected) {
            return xmp
        }
        guard let source = CGImageSourceCreateWithData(plain as CFData, nil),
              let written = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        else { return nil }
        for (dictionary, key) in lost(from: alone, comparedWith: expected) {
            guard let tag = CGImageMetadataCopyTagMatchingImageProperty(written, dictionary, key),
                  let tagNamespace = CGImageMetadataTagCopyNamespace(tag),
                  let tagPrefix = CGImageMetadataTagCopyPrefix(tag),
                  let tagName = CGImageMetadataTagCopyName(tag)
            else { return nil }
            _ = CGImageMetadataRegisterNamespaceForPrefix(xmp, tagNamespace, tagPrefix, nil)
            guard CGImageMetadataSetTagWithPath(xmp, nil, "\(tagPrefix):\(tagName)" as CFString, tag)
            else { return nil }
        }
        guard let restored = encode(pixel, format: format, properties: properties, metadata: xmp)
            .flatMap(readProperties), restored.isEqual(expected)
        else { return nil }
        return xmp
    }

    /// The first of `parts`' XMP with the others' tags added; nil when one can't be read.
    private static func combined(_ parts: [Data]) -> CGMutableImageMetadata? {
        guard let first = parts.first.flatMap({ CGImageMetadataCreateFromXMPData($0 as CFData) }),
              let xmp = CGImageMetadataCreateMutableCopy(first)
        else { return nil }
        for part in parts.dropFirst() {
            guard let tags = CGImageMetadataCreateFromXMPData(part as CFData) else { return nil }
            var added = true
            CGImageMetadataEnumerateTagsUsingBlock(tags, nil, nil) { _, tag in
                guard let namespace = CGImageMetadataTagCopyNamespace(tag),
                      let prefix = CGImageMetadataTagCopyPrefix(tag),
                      let name = CGImageMetadataTagCopyName(tag)
                else {
                    added = false
                    return false
                }
                _ = CGImageMetadataRegisterNamespaceForPrefix(xmp, namespace, prefix, nil)
                added = CGImageMetadataSetTagWithPath(xmp, nil, "\(prefix):\(name)" as CFString, tag)
                return added
            }
            guard added else { return nil }
        }
        return xmp
    }

    /// The entries of `expected`'s dictionaries (EXIF, IPTC and so on) that `found` lacks or reads
    /// differently, by dictionary and key.
    private static func lost(
        from found: NSDictionary,
        comparedWith expected: NSDictionary,
    ) -> [(dictionary: CFString, key: CFString)] {
        var lost: [(dictionary: CFString, key: CFString)] = []
        for case let (dictionary as String, entries as NSDictionary) in expected {
            let other = found[dictionary] as? NSDictionary
            for case let (key as String, value as NSObject) in entries where !value.isEqual(other?[key]) {
                lost.append((dictionary as CFString, key as CFString))
            }
        }
        return lost
    }

    /// One black pixel in `image`'s pixel format and colour space.
    private static func pixel(like image: CGImage) -> CGImage? {
        let bytesPerRow = (image.bitsPerPixel + 7) / 8
        guard let space = image.colorSpace,
              let provider = CGDataProvider(data: Data(count: bytesPerRow) as CFData)
        else { return nil }
        return CGImage(
            width: 1, height: 1, bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel,
            bytesPerRow: bytesPerRow, space: space, bitmapInfo: image.bitmapInfo, provider: provider,
            decode: nil, shouldInterpolate: false, intent: image.renderingIntent,
        )
    }

    private static func encode(
        _ image: CGImage,
        format: ExportFormat,
        properties: [CFString: Any],
        metadata: CGImageMetadata? = nil,
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, format.typeIdentifier as CFString, 1, nil,
        ) else { return nil }
        if let metadata {
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func readProperties(_ file: Data) -> NSDictionary? {
        CGImageSourceCreateWithData(file as CFData, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as NSDictionary?
    }
}
