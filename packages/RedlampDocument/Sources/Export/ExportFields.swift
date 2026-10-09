import CoreGraphics
import Foundation
import ImageIO

public extension ExportMetadata {
    /// The photo's own fields, which an export carries in place of what its file says of them: IPTC
    /// Core's descriptions and location (LIB-22), its keywords as they're exported (LIB-21), its rating
    /// and label, and its capture time where the library moved it. The library works them out from
    /// the photo's merged metadata; each nil or empty one is none.
    struct Fields: Sendable, Hashable {
        public var title: String?
        public var caption: String?
        /// The creators' names, each on its own.
        public var creators: [String]
        public var copyright: String?
        public var location: PhotoLocation?
        /// Flat, for IPTC's keywords and `dc:subject`: each keyword exported, and the names exported
        /// with it, once.
        public var keywords: [String]
        /// For `lr:hierarchicalSubject`: each exported keyword's names from the top of the keyword list
        /// down.
        public var keywordPaths: [[String]]
        /// 1 to 5 stars; nil for none.
        public var rating: Int?
        /// The label's name, as `xmp:Label` holds it.
        public var label: String?
        /// The capture time, where it isn't the camera's; nil leaves the camera's.
        public var captured: CaptureTime?

        public init(
            title: String? = nil, caption: String? = nil, creators: [String] = [], copyright: String? = nil,
            location: PhotoLocation? = nil, keywords: [String] = [], keywordPaths: [[String]] = [],
            rating: Int? = nil, label: String? = nil, captured: CaptureTime? = nil,
        ) {
            self.title = title
            self.caption = caption
            self.creators = creators
            self.copyright = copyright
            self.location = location
            self.keywords = keywords
            self.keywordPaths = keywordPaths
            self.rating = rating
            self.label = label
            self.captured = captured
        }
    }

    /// A time by the camera's clock: its reading as if it were UTC, as the library keeps capture
    /// times, and the zone the clock was in, in seconds east of UTC, nil when it isn't known.
    struct CaptureTime: Sendable, Hashable {
        public var time: Date
        public var offset: Int?

        public init(time: Date, offset: Int? = nil) {
            self.time = time
            self.offset = offset
        }
    }
}

extension ExportMetadata.Fields {
    /// Where `ExportMetadata.properties` puts the fields' XMP, for `ExportMetadata.addImage`.
    static var propertyKey: CFString {
        "RedlampExportFields" as CFString
    }

    /// The TIFF tags ImageIO reads before IPTC's caption and copyright, by their IPTC keys.
    static var tiffKeys: [CFString: CFString] {
        [
            kCGImagePropertyIPTCCaptionAbstract: kCGImagePropertyTIFFImageDescription,
            kCGImagePropertyIPTCCopyrightNotice: kCGImagePropertyTIFFCopyright,
        ]
    }

    /// The IPTC fields the photo's fields stand for, which an export copies from its source only
    /// without them.
    static var iptcKeys: [CFString] {
        [
            kCGImagePropertyIPTCObjectName, kCGImagePropertyIPTCCaptionAbstract, kCGImagePropertyIPTCByline,
            kCGImagePropertyIPTCCopyrightNotice, kCGImagePropertyIPTCKeywords, kCGImagePropertyIPTCStarRating,
            kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCCity, kCGImagePropertyIPTCProvinceState,
            kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
        ]
    }

    /// Gives `properties` (an export's, under `policy`) these fields in place of the source's: in IPTC;
    /// in XMP as ImageIO writes them, with Lightroom's keyword paths and the label; and in EXIF's Artist,
    /// Copyright and ImageDescription, which ImageIO reads before IPTC's creator, copyright and caption,
    /// and writes `dc:rights` over. A capture time goes to EXIF's DateTimeOriginal and OffsetTimeOriginal,
    /// IPTC's date and time created, and XMP's `photoshop:DateCreated` and `exif:DateTimeOriginal`, which
    /// ImageIO leaves out of the XMP of files with EXIF of their own. The location stays out under
    /// `.allExceptLocation`, as GPS does; nothing is written under `.none`.
    func write(into properties: inout [CFString: Any], policy: ExportMetadataPolicy) {
        guard policy != .none else { return }
        let location = policy == .all ? location : nil
        var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var xmp: [Tag] = []
        for key in Self.iptcKeys {
            iptc[key] = nil
        }
        let creators = creators.compactMap(Self.text)
        let texts: [(CFString, XMPProperty, String?)] = [
            (kCGImagePropertyIPTCObjectName, .title, title),
            (kCGImagePropertyIPTCCaptionAbstract, .description, caption),
            (kCGImagePropertyIPTCCopyrightNotice, .rights, copyright),
        ]
        for (key, property, value) in texts {
            let value = value.flatMap(Self.text)
            iptc[key] = value
            if let tiffKey = Self.tiffKeys[key] {
                tiff[tiffKey] = value
            }
            if let value {
                xmp.append(Tag(property, .alternative(value)))
            }
        }
        tiff[kCGImagePropertyTIFFArtist] = creators.isEmpty ? nil : creators.joined(separator: "; ")
        if !creators.isEmpty {
            iptc[kCGImagePropertyIPTCByline] = creators
            xmp.append(Tag(.creator, .ordered(creators)))
        }
        let places: [(CFString, XMPProperty, String?)] = [
            (kCGImagePropertyIPTCSubLocation, .sublocation, location?.sublocation),
            (kCGImagePropertyIPTCCity, .city, location?.city),
            (kCGImagePropertyIPTCProvinceState, .state, location?.state),
            (kCGImagePropertyIPTCCountryPrimaryLocationName, .country, location?.country),
            (kCGImagePropertyIPTCCountryPrimaryLocationCode, .countryCode, location?.countryCode),
        ]
        for (key, property, value) in places {
            if let value = value.flatMap(Self.text) {
                iptc[key] = value
                xmp.append(Tag(property, .text(value)))
            }
        }
        let keywords = keywords.compactMap(Self.text)
        if !keywords.isEmpty {
            iptc[kCGImagePropertyIPTCKeywords] = keywords
            xmp.append(Tag(.subject, .unordered(keywords)))
        }
        let paths = keywordPaths.map { $0.compactMap(Self.text) }.filter { !$0.isEmpty }
        if !paths.isEmpty {
            xmp.append(Tag(.hierarchicalSubject, .unordered(paths.map { $0.joined(separator: "|") })))
        }
        if let rating, (1 ... 5).contains(rating) {
            iptc[kCGImagePropertyIPTCStarRating] = rating
            xmp.append(Tag(.rating, .text(String(rating))))
        }
        if let label = label.flatMap(Self.text) {
            xmp.append(Tag(.label, .text(label)))
        }
        if let captured {
            var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            exif[kCGImagePropertyExifDateTimeOriginal] = captured.exifTime
            exif[kCGImagePropertyExifOffsetTimeOriginal] = captured.exifOffset
            iptc[kCGImagePropertyIPTCDateCreated] = captured.iptcDate
            iptc[kCGImagePropertyIPTCTimeCreated] = captured.iptcTime
            let xmpTime = captured.xmpTime(subseconds: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String)
            xmp.append(Tag(.dateTimeOriginal, .text(xmpTime)))
            xmp.append(Tag(.dateCreated, .text(xmpTime)))
            properties[kCGImagePropertyExifDictionary] = exif
        }
        properties[kCGImagePropertyIPTCDictionary] = iptc.isEmpty ? nil : iptc
        properties[kCGImagePropertyTIFFDictionary] = tiff
        properties[Self.propertyKey] = Self.xmp(xmp)
    }

    /// `text` without the spaces at its ends; nil when that leaves nothing.
    private static func text(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - XMP

    /// A property of the fields, by namespace, the prefix ImageIO gives it and its name.
    private struct XMPProperty {
        let namespace: String
        let prefix: String
        let name: String

        static let dc = "http://purl.org/dc/elements/1.1/"
        static let photoshop = "http://ns.adobe.com/photoshop/1.0/"
        static let iptcCore = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
        static let xmp = "http://ns.adobe.com/xap/1.0/"

        static let title = XMPProperty(namespace: dc, prefix: "dc", name: "title")
        static let description = XMPProperty(namespace: dc, prefix: "dc", name: "description")
        static let creator = XMPProperty(namespace: dc, prefix: "dc", name: "creator")
        static let rights = XMPProperty(namespace: dc, prefix: "dc", name: "rights")
        static let subject = XMPProperty(namespace: dc, prefix: "dc", name: "subject")
        static let hierarchicalSubject = XMPProperty(
            namespace: "http://ns.adobe.com/lightroom/1.0/", prefix: "lr", name: "hierarchicalSubject",
        )
        static let sublocation = XMPProperty(namespace: iptcCore, prefix: "Iptc4xmpCore", name: "Location")
        static let city = XMPProperty(namespace: photoshop, prefix: "photoshop", name: "City")
        static let state = XMPProperty(namespace: photoshop, prefix: "photoshop", name: "State")
        static let country = XMPProperty(namespace: photoshop, prefix: "photoshop", name: "Country")
        static let countryCode = XMPProperty(namespace: iptcCore, prefix: "Iptc4xmpCore", name: "CountryCode")
        static let rating = XMPProperty(namespace: xmp, prefix: "xmp", name: "Rating")
        static let label = XMPProperty(namespace: xmp, prefix: "xmp", name: "Label")
        static let dateTimeOriginal = XMPProperty(
            namespace: "http://ns.adobe.com/exif/1.0/", prefix: "exif", name: "DateTimeOriginal",
        )
        static let dateCreated = XMPProperty(namespace: photoshop, prefix: "photoshop", name: "DateCreated")
    }

    private enum Value {
        case text(String)
        /// A language alternative with this as its default.
        case alternative(String)
        /// An `rdf:Seq`.
        case ordered([String])
        /// An `rdf:Bag`.
        case unordered([String])
    }

    private struct Tag {
        let property: XMPProperty
        let value: Value

        init(_ property: XMPProperty, _ value: Value) {
            self.property = property
            self.value = value
        }
    }

    /// `tags` as XMP; nil when there are none, or they can't be written.
    private static func xmp(_ tags: [Tag]) -> Data? {
        guard !tags.isEmpty else { return nil }
        let metadata = CGImageMetadataCreateMutable()
        for tag in tags {
            let property = tag.property
            guard CGImageMetadataRegisterNamespaceForPrefix(
                metadata, property.namespace as CFString, property.prefix as CFString, nil,
            ) else { return nil }
            let path = "\(property.prefix):\(property.name)"
            let written = switch tag.value {
            case let .text(text):
                CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, text as CFString)
            case let .alternative(text):
                CGImageMetadataSetValueWithPath(metadata, nil, "\(path)[x-default]" as CFString, text as CFString)
            case let .ordered(items):
                set(items, as: .arrayOrdered, at: property, in: metadata)
            case let .unordered(items):
                set(items, as: .arrayUnordered, at: property, in: metadata)
            }
            guard written else { return nil }
        }
        return CGImageMetadataCreateXMPData(metadata, nil) as Data?
    }

    private static func set(
        _ items: [String], as type: CGImageMetadataType, at property: XMPProperty, in metadata: CGMutableImageMetadata,
    ) -> Bool {
        guard let tag = CGImageMetadataTagCreate(
            property.namespace as CFString, property.prefix as CFString, property.name as CFString, type,
            items as CFArray,
        ) else { return false }
        return CGImageMetadataSetTagWithPath(metadata, nil, "\(property.prefix):\(property.name)" as CFString, tag)
    }
}

extension ExportMetadata.CaptureTime {
    /// The clock's reading, by field.
    private var reading: DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: time)
    }

    private func digits(_ components: [Int?], _ format: String) -> String {
        String(format: format, arguments: components.map { ($0 ?? 0) as CVarArg })
    }

    /// EXIF's DateTimeOriginal: `2026:10:01 13:30:00`.
    var exifTime: String {
        let reading = reading
        return digits(
            [reading.year, reading.month, reading.day, reading.hour, reading.minute, reading.second],
            "%04d:%02d:%02d %02d:%02d:%02d",
        )
    }

    /// EXIF's OffsetTimeOriginal: `+02:00`; nil without a zone.
    var exifOffset: String? {
        zone(separator: ":")
    }

    /// IPTC's Date Created: `20261001`.
    var iptcDate: String {
        let reading = reading
        return digits([reading.year, reading.month, reading.day], "%04d%02d%02d")
    }

    /// IPTC's Time Created: `133000+0200`, or `133000` without a zone.
    var iptcTime: String {
        let reading = reading
        return digits([reading.hour, reading.minute, reading.second], "%02d%02d%02d") + (zone(separator: "") ?? "")
    }

    /// XMP's `2026-10-01T13:30:00.25+02:00`, with `subseconds`' digits (EXIF's SubsecTimeOriginal) when
    /// there are any.
    func xmpTime(subseconds: String?) -> String {
        let reading = reading
        let fraction = subseconds.map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { !$0.isEmpty && $0.allSatisfy { ("0" ... "9").contains($0) } ? "." + $0 : nil }
        return digits(
            [reading.year, reading.month, reading.day, reading.hour, reading.minute, reading.second],
            "%04d-%02d-%02dT%02d:%02d:%02d",
        ) + (fraction ?? "") + (zone(separator: ":") ?? "")
    }

    private func zone(separator: String) -> String? {
        guard let offset else { return nil }
        let minutes = abs(offset) / 60
        return (offset < 0 ? "-" : "+") + String(format: "%02d", minutes / 60) + separator
            + String(format: "%02d", minutes % 60)
    }
}
