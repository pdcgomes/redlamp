import Foundation
import ImageIO

/// An XMP packet's top-level properties, found by namespace and name whatever prefixes it gives them:
/// an `.xmp` sidecar's (`XMPPacket`), or a photo's own XMP as ImageIO reads it (`XMPImageProperties`).
/// `XMPSource` reads each app's conventions from either.
protocol XMPProperties {
    func has(_ property: XMPProperty) -> Bool
    /// A simple property's text.
    func text(_ property: XMPProperty) -> String?
    /// An array's items' texts; a simple value as one item.
    func items(_ property: XMPProperty) -> [String]
    /// A language alternative's text in the default language, or else its first; a simple value as
    /// it is.
    func alternative(_ property: XMPProperty) -> String?
}

extension XMPPacket: XMPProperties {}

/// A photo's own XMP as ImageIO reads it (`CGImageSourceCopyMetadataAtIndex`): its top-level tags, read
/// as `XMPPacket` reads an `.xmp`'s properties.
struct XMPImageProperties: XMPProperties {
    private let tags: [XMPProperty: CGImageMetadataTag]

    init(_ metadata: CGImageMetadata?) {
        var tags: [XMPProperty: CGImageMetadataTag] = [:]
        if let metadata {
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
                if let namespace = CGImageMetadataTagCopyNamespace(tag), let name = CGImageMetadataTagCopyName(tag) {
                    tags[XMPProperty(namespace as String, name as String)] = tag
                }
                return true
            }
        }
        self.tags = tags
    }

    func has(_ property: XMPProperty) -> Bool {
        tags[property] != nil
    }

    func text(_ property: XMPProperty) -> String? {
        tags[property].flatMap(Self.text)
    }

    func items(_ property: XMPProperty) -> [String] {
        guard let tag = tags[property] else { return [] }
        return Self.text(tag).map { [$0] } ?? Self.items(of: tag).compactMap(Self.itemText)
    }

    func alternative(_ property: XMPProperty) -> String? {
        guard let tag = tags[property] else { return nil }
        if let text = Self.text(tag) {
            return text
        }
        let items = Self.items(of: tag)
        let preferred = items.first { item in
            CFGetTypeID(item) == CGImageMetadataTagGetTypeID()
                && Self.isDefaultLanguage(unsafeDowncast(item, to: CGImageMetadataTag.self))
        }
        return (preferred ?? items.first).flatMap(Self.itemText)
    }

    private static func text(_ tag: CGImageMetadataTag) -> String? {
        CGImageMetadataTagCopyValue(tag) as? String
    }

    /// An array's items: tags, or text as ImageIO gives some.
    private static func items(of tag: CGImageMetadataTag) -> [AnyObject] {
        CGImageMetadataTagCopyValue(tag) as? [AnyObject] ?? []
    }

    private static func itemText(_ item: AnyObject) -> String? {
        if let text = item as? String {
            return text
        }
        guard CFGetTypeID(item) == CGImageMetadataTagGetTypeID() else { return nil }
        return text(unsafeDowncast(item, to: CGImageMetadataTag.self))
    }

    private static func isDefaultLanguage(_ item: CGImageMetadataTag) -> Bool {
        let qualifiers = CGImageMetadataTagCopyQualifiers(item) as? [CGImageMetadataTag] ?? []
        return qualifiers.contains { qualifier in
            CGImageMetadataTagCopyName(qualifier) as String? == "lang"
                && (CGImageMetadataTagCopyValue(qualifier) as? String)?.lowercased() == "x-default"
        }
    }
}
