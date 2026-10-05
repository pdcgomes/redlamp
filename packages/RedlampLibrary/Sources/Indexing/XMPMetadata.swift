import Foundation
import ImageIO

/// What other apps leave in XMP for organising photos: ratings, labels, keywords, titles, captions,
/// creators, copyrights and places, embedded in photos or in the `.xmp` sidecars Lightroom, Bridge,
/// Capture One, Photo Mechanic and darktable write beside them.
public enum XMPMetadata {
    /// The organising fields of an `.xmp` sidecar, the rest of the metadata left empty; nil when
    /// `data` isn't XMP.
    public static func parse(_ data: Data) -> CaptureMetadata? {
        guard let xmp = CGImageMetadataCreateFromXMPData(data as CFData) else { return nil }
        var found = CaptureMetadata()
        organise(&found, xmp: xmp)
        return found
    }

    /// Where other apps put `photo`'s `.xmp` sidecar: `IMG_1234.xmp` (Lightroom, Bridge, Capture One,
    /// Photo Mechanic), then `IMG_1234.ARW.xmp` (darktable).
    public static func sidecarURLs(for photo: URL) -> [URL] {
        let replacing = photo.deletingPathExtension().appendingPathExtension("xmp")
        let adding = photo.appendingPathExtension("xmp")
        return replacing == adding ? [replacing] : [replacing, adding]
    }

    /// Sets `found`'s organising fields from `xmp`, then from IPTC's IIM and TIFF's fields where the
    /// XMP has nothing (ImageIO mirrors most of each into the other).
    static func organise(
        _ found: inout CaptureMetadata, xmp: CGImageMetadata?, iptc: [CFString: Any] = [:], tiff: [CFString: Any] = [:],
    ) {
        let properties = XMPProperties(xmp)
        found.rating = rating(properties.texts(basic, "Rating").first ?? iptc[kCGImagePropertyIPTCStarRating])
        found.label = text(properties.texts(basic, "Label").first)
        let paths = unique(properties.texts(lightroom, "hierarchicalSubject").compactMap(path))
        let flat = (properties.texts(dc, "subject") + texts(iptc[kCGImagePropertyIPTCKeywords])).compactMap(text)
        found.keywords = paths.isEmpty ? unique(flat.filter { !$0.hasPrefix("darktable|") }) : paths
        found.title = text(properties.texts(dc, "title").first) ?? text(iptc[kCGImagePropertyIPTCObjectName])
        found.caption = text(properties.texts(dc, "description").first)
            ?? text(iptc[kCGImagePropertyIPTCCaptionAbstract])
        found.creator = joined(properties.texts(dc, "creator")) ?? joined(texts(iptc[kCGImagePropertyIPTCByline]))
            ?? text(tiff[kCGImagePropertyTIFFArtist])
        found.copyright = text(properties.texts(dc, "rights").first)
            ?? text(iptc[kCGImagePropertyIPTCCopyrightNotice]) ?? text(tiff[kCGImagePropertyTIFFCopyright])
        let location = CaptureMetadata.Location(
            country: text(properties.texts(photoshop, "Country").first)
                ?? text(iptc[kCGImagePropertyIPTCCountryPrimaryLocationName]),
            state: text(properties.texts(photoshop, "State").first) ?? text(iptc[kCGImagePropertyIPTCProvinceState]),
            city: text(properties.texts(photoshop, "City").first) ?? text(iptc[kCGImagePropertyIPTCCity]),
            sublocation: text(properties.texts(iptcCore, "Location").first)
                ?? text(iptc[kCGImagePropertyIPTCSubLocation]),
        )
        found.location = location.isEmpty ? nil : location
    }

    private static let basic = kCGImageMetadataNamespaceXMPBasic as String
    private static let dc = kCGImageMetadataNamespaceDublinCore as String
    private static let photoshop = kCGImageMetadataNamespacePhotoshop as String
    private static let iptcCore = kCGImageMetadataNamespaceIPTCCore as String
    private static let lightroom = "http://ns.adobe.com/lightroom/1.0/"

    /// -1 (rejected) to 5 stars; XMP allows fractions, which round.
    private static func rating(_ value: Any?) -> Int? {
        guard let stars = PhotoMetadataReader.number(value), stars.isFinite else { return nil }
        let rounded = Int(stars.rounded())
        return (-1 ... 5).contains(rounded) ? rounded : nil
    }

    /// A Lightroom keyword path, "Places|Portugal|Lisbon", as "Places/Portugal/Lisbon"; nil for the
    /// tags darktable keeps its bookkeeping in ("darktable|format|ARW"), which its users never see.
    private static func path(_ hierarchical: String) -> String? {
        let names = hierarchical.split(separator: "|").compactMap { text(String($0)) }
        guard let top = names.first, top != "darktable" else { return nil }
        return names.joined(separator: "/")
    }

    private static func text(_ value: Any?) -> String? {
        PhotoMetadataReader.text(value)
    }

    /// An IIM field ImageIO gives as one string or a list of them.
    private static func texts(_ value: Any?) -> [String] {
        (value as? [String]) ?? (value as? String).map { [$0] } ?? []
    }

    private static func joined(_ names: [String]) -> String? {
        let names = names.compactMap(text)
        return names.isEmpty ? nil : names.joined(separator: "; ")
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}

/// An XMP packet's top-level properties, found by namespace and name, whatever prefixes the file
/// gives them.
private struct XMPProperties {
    private let tags: [String: CGImageMetadataTag]

    init(_ metadata: CGImageMetadata?) {
        var tags: [String: CGImageMetadataTag] = [:]
        if let metadata {
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
                if let namespace = CGImageMetadataTagCopyNamespace(tag), let name = CGImageMetadataTagCopyName(tag) {
                    tags[(namespace as String) + (name as String)] = tag
                }
                return true
            }
        }
        self.tags = tags
    }

    /// The text of a property: a simple value's, each item's of a list, and the default language's
    /// (or else the first's) of an alternative text.
    func texts(_ namespace: String, _ name: String) -> [String] {
        tags[namespace + name].map(Self.texts) ?? []
    }

    private static func texts(_ tag: CGImageMetadataTag) -> [String] {
        let value = CGImageMetadataTagCopyValue(tag)
        if let text = value as? String {
            return [text]
        }
        let items = value as? [AnyObject] ?? []
        let tags = items.compactMap { item in
            CFGetTypeID(item) == CGImageMetadataTagGetTypeID() ? unsafeDowncast(item, to: CGImageMetadataTag.self) : nil
        }
        guard CGImageMetadataTagGetType(tag) == .alternateText else {
            return items.compactMap { $0 as? String } + tags.flatMap(texts)
        }
        return (tags.first(where: isDefaultLanguage) ?? tags.first).map(texts) ?? []
    }

    private static func isDefaultLanguage(_ tag: CGImageMetadataTag) -> Bool {
        let qualifiers = CGImageMetadataTagCopyQualifiers(tag) as? [CGImageMetadataTag] ?? []
        return qualifiers.contains { qualifier in
            CGImageMetadataTagCopyName(qualifier) as String? == "lang"
                && CGImageMetadataTagCopyValue(qualifier) as? String == "x-default"
        }
    }
}
