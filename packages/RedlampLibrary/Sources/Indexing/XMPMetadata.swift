import Foundation
import ImageIO

/// What other apps leave in XMP for organising photos: ratings, flags, labels, keywords, titles,
/// captions, creators, copyrights and places, embedded in photos or in the `.xmp` sidecars Lightroom,
/// Bridge, Capture One, Photo Mechanic and darktable write beside them. The fields Redlamp shares
/// with other apps are read as `LibraryXMP` reads them (`XMPSource`), so the index shows what it
/// would take.
public enum XMPMetadata {
    /// The organising fields of an `.xmp` sidecar, the rest of the metadata left empty; nil when
    /// `data` isn't XMP.
    public static func parse(_ data: Data, conventions: XMPConventions = XMPConventions()) -> CaptureMetadata? {
        guard let packet = XMPPacket(data) else { return nil }
        let source = XMPSource(packet: packet, conventions: conventions)
        var found = CaptureMetadata()
        organise(&found, source.present.isEmpty ? nil : source)
        return found
    }

    /// Where other apps put `photo`'s `.xmp` sidecar: `IMG_1234.xmp` (Lightroom, Bridge, Capture One,
    /// Photo Mechanic), then `IMG_1234.ARW.xmp` (darktable).
    public static func sidecarURLs(for photo: URL) -> [URL] {
        let replacing = photo.deletingPathExtension().appendingPathExtension("xmp")
        let adding = photo.appendingPathExtension("xmp")
        return replacing == adding ? [replacing] : [replacing, adding]
    }

    /// Sets `found`'s organising fields from a photo's own XMP as ImageIO reads it, and from IPTC's
    /// IIM and TIFF's fields where the XMP has nothing (ImageIO mirrors most of each into the other).
    static func organise(
        _ found: inout CaptureMetadata, xmp: CGImageMetadata?, iptc: [CFString: Any], tiff: [CFString: Any],
        conventions: XMPConventions,
    ) {
        organise(
            &found, XMPSource.embedded(XMPImageProperties(xmp), iptc: iptc, tiff: tiff, conventions: conventions),
        )
    }

    private static func organise(_ found: inout CaptureMetadata, _ source: XMPSource?) {
        found.xmp = source
        let fields = source?.fields ?? XMPFields()
        found.rating = fields.flag == .reject ? -1 : fields.rating
        found.label = fields.label.map { XMPLabelNames.lightroom.name(for: $0) } ?? fields.customLabel
        found.keywords = fields.keywords
        found.title = fields.title
        found.caption = fields.caption
        found.creator = fields.creator
        found.copyright = fields.copyright
        found.location = fields.location
    }
}
