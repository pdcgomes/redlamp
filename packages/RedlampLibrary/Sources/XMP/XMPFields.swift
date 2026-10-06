import Foundation
import ImageIO
import RedlampDocument
import UniformTypeIdentifiers

/// The fields other apps share through XMP, as Redlamp keeps them: a rating, a flag, a colour label or
/// a custom one, keywords, and IPTC Core's title, caption, creator, copyright and location. Each app's
/// conventions for them come in through `XMPSource.init(packet:conventions:)` and go out through
/// `changes(_:to:conventions:now:)`.
public struct XMPFields: Sendable, Hashable, Codable {
    /// 1 to 5 stars; nil when unrated.
    public var rating: Int?
    public var flag: PhotoFlag?
    public var label: ColorLabel?
    /// A label none of the sets names ("Urgent", Capture One's "Orange"), as it's written, when `label`
    /// is nil.
    public var customLabel: String?
    /// Each keyword's path from the top of its hierarchy: "Places/Portugal/Lisbon". Empty: the
    /// `.redlamp`'s keyword list that has none, which XMP writes as no keywords; nil: none held.
    public var keywords: [String]?
    /// An empty title, caption, creator, copyright or location is the `.redlamp`'s none, which XMP
    /// writes as no value.
    public var title: String?
    public var caption: String?
    /// The creators' names, separated by semicolons.
    public var creator: String?
    public var copyright: String?
    public var location: PhotoLocation?

    public init(
        rating: Int? = nil, flag: PhotoFlag? = nil, label: ColorLabel? = nil, customLabel: String? = nil,
        keywords: [String]? = nil, title: String? = nil, caption: String? = nil, creator: String? = nil,
        copyright: String? = nil, location: PhotoLocation? = nil,
    ) {
        self.rating = rating
        self.flag = flag
        self.label = label
        self.customLabel = customLabel
        self.keywords = keywords
        self.title = title
        self.caption = caption
        self.creator = creator
        self.copyright = copyright
        self.location = location
    }

    /// The fields a `.redlamp` sidecar's metadata holds: a rating of 0 is none, and an empty keyword list
    /// is keywords held, none of them.
    public init(_ metadata: PhotoMetadata?) {
        self.init(
            rating: metadata.flatMap { $0.rating > 0 ? $0.rating : nil }, flag: metadata?.flag, label: metadata?.label,
            customLabel: metadata?.label == nil ? metadata?.customLabel.flatMap(XMPSource.trimmed) : nil,
            keywords: metadata?.keywords.map(KeywordPath.texts), title: metadata?.title, caption: metadata?.caption,
            creator: metadata?.creator, copyright: metadata?.copyright, location: metadata?.location,
        )
    }

    public var isEmpty: Bool {
        XMPField.allCases.allSatisfy { !holds($0) }
    }

    /// Whether it has a value for `field`; an empty text, location or keyword list is one.
    public func holds(_ field: XMPField) -> Bool {
        switch field {
        case .rating: rating != nil
        case .flag: flag != nil
        case .label: label != nil || customLabel != nil
        case .keywords: keywords != nil
        case .title: title != nil
        case .caption: caption != nil
        case .creator: creator != nil
        case .copyright: copyright != nil
        case .location: location != nil
        }
    }

    /// Whether `other` has the same value for `field`, as XMP can tell: keywords in any order, texts
    /// without the spaces at their ends, creators name by name, and an empty text, location or keyword
    /// list as none.
    public func same(_ field: XMPField, as other: XMPFields) -> Bool {
        switch field {
        case .rating: rating == other.rating
        case .flag: flag == other.flag
        case .label: label == other.label && (label != nil || Self.text(customLabel) == Self.text(other.customLabel))
        case .keywords: Set(keywords ?? []) == Set(other.keywords ?? [])
        case .title: Self.text(title) == Self.text(other.title)
        case .caption: Self.text(caption) == Self.text(other.caption)
        case .creator: Self.names(creator) == Self.names(other.creator)
        case .copyright: Self.text(copyright) == Self.text(other.copyright)
        case .location: Self.place(location) == Self.place(other.location)
        }
    }

    /// A text as XMP holds it: without the spaces at its ends, nil when that leaves nothing.
    static func text(_ value: String?) -> String? {
        value.flatMap(XMPSource.trimmed)
    }

    /// The names in a creator's text, which separates them with semicolons.
    static func names(_ creator: String?) -> [String] {
        creator?.split(separator: ";").compactMap { XMPSource.trimmed(String($0)) } ?? []
    }

    /// A location as XMP holds it: each field trimmed, nil when none is left.
    static func place(_ location: PhotoLocation?) -> PhotoLocation? {
        guard let location else { return nil }
        let place = PhotoLocation(
            country: text(location.country), state: text(location.state), city: text(location.city),
            sublocation: text(location.sublocation), countryCode: text(location.countryCode),
        )
        return place.isEmpty ? nil : place
    }

    /// Takes `other`'s value for `field`.
    public mutating func take(_ field: XMPField, from other: XMPFields) {
        switch field {
        case .rating: rating = other.rating
        case .flag: flag = other.flag
        case .label:
            label = other.label
            customLabel = other.customLabel
        case .keywords: keywords = other.keywords
        case .title: title = other.title
        case .caption: caption = other.caption
        case .creator: creator = other.creator
        case .copyright: copyright = other.copyright
        case .location: location = other.location
        }
    }

    /// `metadata` with this one's values for `fields`, its others as they were.
    func applied(to metadata: PhotoMetadata?, fields: Set<XMPField>) -> PhotoMetadata {
        var applied = metadata ?? PhotoMetadata()
        if fields.contains(.rating) {
            applied.rating = rating ?? 0
        }
        if fields.contains(.flag) {
            applied.flag = flag
        }
        if fields.contains(.label) {
            applied.label = label
            applied.customLabel = label == nil ? customLabel : nil
        }
        if fields.contains(.keywords) {
            applied.keywords = keywords ?? []
        }
        if fields.contains(.title) {
            applied.title = title
        }
        if fields.contains(.caption) {
            applied.caption = caption
        }
        if fields.contains(.creator) {
            applied.creator = creator
        }
        if fields.contains(.copyright) {
            applied.copyright = copyright
        }
        if fields.contains(.location) {
            applied.location = location
        }
        return applied
    }
}

/// A field `XMPFields` keeps.
public enum XMPField: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case rating, flag, label, keywords, title, caption, creator, copyright, location

    /// The fields `.redlamp` sidecars hold, which merge and are written: all of them.
    public static let held = Set(allCases)

    public static func < (lhs: XMPField, rhs: XMPField) -> Bool {
        allCases.firstIndex(of: lhs) ?? 0 < allCases.firstIndex(of: rhs) ?? 0
    }
}

/// The fields one place holds (an `.xmp`, or a photo's own XMP and IPTC), and which it has at all:
/// an `.xmp` that says a photo is unrated (`xmp:Rating="0"`) hides a rating in the photo's own XMP.
public struct XMPSource: Sendable, Hashable, Codable {
    public var fields: XMPFields
    public var present: Set<XMPField>

    public init(fields: XMPFields = XMPFields(), present: Set<XMPField> = []) {
        self.fields = fields
        self.present = present
    }

    /// Each field from the first of `sources` that has it.
    public static func combining(_ sources: [XMPSource?]) -> XMPFields {
        var combined = XMPFields()
        for field in XMPField.allCases {
            if let source = sources.lazy.compactMap(\.self).first(where: { $0.present.contains(field) }) {
                combined.take(field, from: source.fields)
            }
        }
        if combined.label == nil, combined.customLabel == nil {
            combined.customLabel = sources.lazy.compactMap { $0?.fields.customLabel }.first
        }
        return combined
    }

    /// What an `.xmp`, or a photo's own XMP, holds by each app's conventions: `xmp:Rating` (-1 for a
    /// reject, as Bridge and Lightroom write it), Lightroom's pick (`xmpDM:good`), the label's colour
    /// (`xmp:LabelColor`), its name in any set (`xmp:Label`), Urgency when `conventions` read it,
    /// darktable's labels, Lightroom's keyword paths with the flat keywords not in them, and the
    /// default title and caption.
    init(packet: some XMPProperties, conventions: XMPConventions) {
        var fields = XMPFields()
        var present = Set<XMPField>()
        if let text = packet.text(XMPNamespace.rating) {
            present.formUnion([.rating, .flag])
            if let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite {
                let stars = Int(value.rounded())
                if stars == -1 {
                    fields.flag = .reject
                } else if (1 ... 5).contains(stars) {
                    fields.rating = stars
                }
            }
        }
        if let good = packet.text(XMPNamespace.good) {
            present.insert(.flag)
            if fields.flag == nil, Self.trimmed(good)?.lowercased() == "true" {
                fields.flag = .pick
            }
        }

        let name = packet.text(XMPNamespace.label).flatMap(Self.trimmed)
        let color = packet.text(XMPNamespace.labelColor).flatMap(Self.trimmed)
        if packet.has(XMPNamespace.label) || packet.has(XMPNamespace.labelColor) {
            present.insert(.label)
        }
        fields.label = color.flatMap { ColorLabel(rawValue: $0.lowercased()) } ?? name.flatMap(XMPLabelNames.label)
        if fields.label == nil {
            fields.customLabel = name
        }
        if conventions.urgency, let urgency = packet.text(XMPNamespace.urgency) {
            present.insert(.label)
            if fields.label == nil, fields.customLabel == nil {
                fields.label = Self.trimmed(urgency).flatMap { Int($0) }.flatMap(XMPUrgency.label)
            }
        }
        if packet.has(XMPNamespace.colorLabels) {
            present.insert(.label)
            if fields.label == nil, fields.customLabel == nil {
                fields.label = packet.items(XMPNamespace.colorLabels).lazy
                    .compactMap { Self.trimmed($0).flatMap { Int($0) } }
                    .first.flatMap { ColorLabel.allCases.indices.contains($0) ? ColorLabel.allCases[$0] : nil }
            }
        }

        if packet.has(XMPNamespace.subject) || packet.has(XMPNamespace.hierarchicalSubject) {
            present.insert(.keywords)
            let keywords = Self.keywords(
                hierarchical: packet.items(XMPNamespace.hierarchicalSubject), flat: packet.items(XMPNamespace.subject),
            )
            fields.keywords = keywords.isEmpty ? nil : keywords
        }
        if packet.has(XMPNamespace.title) {
            present.insert(.title)
            fields.title = packet.alternative(XMPNamespace.title).flatMap(Self.trimmed)
        }
        if packet.has(XMPNamespace.description) {
            present.insert(.caption)
            fields.caption = packet.alternative(XMPNamespace.description).flatMap(Self.trimmed)
        }
        if packet.has(XMPNamespace.creator) {
            present.insert(.creator)
            fields.creator = Self.joined(packet.items(XMPNamespace.creator))
        }
        if packet.has(XMPNamespace.rights) {
            present.insert(.copyright)
            fields.copyright = packet.alternative(XMPNamespace.rights).flatMap(Self.trimmed)
        }
        if Self.places.contains(where: { packet.has($0) }) {
            present.insert(.location)
            fields.location = XMPFields.place(PhotoLocation(
                country: packet.text(XMPNamespace.country), state: packet.text(XMPNamespace.state),
                city: packet.text(XMPNamespace.city), sublocation: packet.text(XMPNamespace.sublocation),
                countryCode: packet.text(XMPNamespace.countryCode),
            ))
        }
        self.init(fields: fields, present: present)
    }

    /// The properties a location is written in.
    static let places = [
        XMPNamespace.sublocation, XMPNamespace.city, XMPNamespace.state, XMPNamespace.country,
        XMPNamespace.countryCode,
    ]

    /// Names as one text, separated by semicolons; nil when there are none.
    static func joined(_ names: [String]) -> String? {
        let names = names.compactMap(trimmed)
        return names.isEmpty ? nil : names.joined(separator: "; ")
    }

    /// What an `.xmp`'s bytes hold; nil when they aren't XMP.
    public init?(xmp data: Data, conventions: XMPConventions = XMPConventions()) {
        guard let packet = XMPPacket(data) else { return nil }
        self.init(packet: packet, conventions: conventions)
    }

    /// What a photo's own XMP holds, and its IPTC and TIFF fields where the XMP has nothing (ImageIO
    /// mirrors most of each into the other); nil when ImageIO can't read the file or it holds none of
    /// the fields.
    public static func embedded(in url: URL, conventions: XMPConventions = XMPConventions()) -> XMPSource? {
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        options[kCGImageSourceTypeIdentifierHint] = UTType(filenameExtension: url.pathExtension)?.identifier
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        return embedded(
            XMPImageProperties(CGImageSourceCopyMetadataAtIndex(source, index, nil)),
            iptc: properties?[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:],
            tiff: properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:], conventions: conventions,
        )
    }

    /// What a photo's own XMP (`xmp`, as ImageIO reads it) holds, and its IPTC (`iptc`) and TIFF
    /// (`tiff`) fields where the XMP has nothing; nil when it holds none of the fields. The indexer reads
    /// them from the image source it reads the rest of the photo's metadata from.
    static func embedded(
        _ xmp: XMPImageProperties, iptc: [CFString: Any], tiff: [CFString: Any] = [:], conventions: XMPConventions,
    ) -> XMPSource? {
        var found = XMPSource(packet: xmp, conventions: conventions)
        if !found.present.contains(.rating),
           let stars = PhotoMetadataReader.number(iptc[kCGImagePropertyIPTCStarRating]) {
            found.present.insert(.rating)
            found.fields.rating = (1 ... 5).contains(Int(stars.rounded())) ? Int(stars.rounded()) : nil
        }
        if !found.present.contains(.label), conventions.urgency,
           let urgency = PhotoMetadataReader.number(iptc[kCGImagePropertyIPTCUrgency]) {
            found.present.insert(.label)
            found.fields.label = XMPUrgency.label(for: Int(urgency))
        }
        let keywords = (iptc[kCGImagePropertyIPTCKeywords] as? [String]) ??
            (iptc[kCGImagePropertyIPTCKeywords] as? String)
            .map { [$0] } ?? []
        if !found.present.contains(.keywords), !keywords.isEmpty {
            found.present.insert(.keywords)
            found.fields.keywords = Self.keywords(hierarchical: [], flat: keywords)
        }
        if !found.present.contains(.title), let title = PhotoMetadataReader.text(iptc[kCGImagePropertyIPTCObjectName]) {
            found.present.insert(.title)
            found.fields.title = title
        }
        if !found.present.contains(.caption),
           let caption = PhotoMetadataReader.text(iptc[kCGImagePropertyIPTCCaptionAbstract]) {
            found.present.insert(.caption)
            found.fields.caption = caption
        }
        let byline = (iptc[kCGImagePropertyIPTCByline] as? [String])
            ?? (iptc[kCGImagePropertyIPTCByline] as? String).map { [$0] } ?? []
        if !found.present.contains(.creator),
           let creator = joined(byline) ?? PhotoMetadataReader.text(tiff[kCGImagePropertyTIFFArtist]) {
            found.present.insert(.creator)
            found.fields.creator = creator
        }
        if !found.present.contains(.copyright),
           let copyright = PhotoMetadataReader.text(iptc[kCGImagePropertyIPTCCopyrightNotice])
           ?? PhotoMetadataReader.text(tiff[kCGImagePropertyTIFFCopyright]) {
            found.present.insert(.copyright)
            found.fields.copyright = copyright
        }
        if !found.present.contains(.location), let location = XMPFields.place(PhotoLocation(
            country: PhotoMetadataReader.text(iptc[kCGImagePropertyIPTCCountryPrimaryLocationName]),
            state: PhotoMetadataReader.text(iptc[kCGImagePropertyIPTCProvinceState]),
            city: PhotoMetadataReader.text(iptc[kCGImagePropertyIPTCCity]),
            sublocation: PhotoMetadataReader.text(iptc[kCGImagePropertyIPTCSubLocation]),
            countryCode: PhotoMetadataReader.text(iptc[kCGImagePropertyIPTCCountryPrimaryLocationCode]),
        )) {
            found.present.insert(.location)
            found.fields.location = location
        }
        return found.present.isEmpty ? nil : found
    }

    /// Lightroom's paths ("Places|Portugal|Lisbon" as "Places/Portugal/Lisbon", a slash in a name as
    /// `%2F`), then each flat keyword no path names. darktable keeps its bookkeeping in tags under
    /// "darktable", which its users never see.
    static func keywords(hierarchical: [String], flat: [String]) -> [String] {
        var paths: [String] = []
        var seen = Set<String>()
        var named = Set<String>()
        for entry in hierarchical {
            let parts = entry.split(separator: "|").compactMap { trimmed(String($0)) }
            guard let top = parts.first, top != "darktable", let path = KeywordPath(names: parts) else { continue }
            named.formUnion(path.names)
            if seen.insert(path.text).inserted {
                paths.append(path.text)
            }
        }
        for entry in flat {
            guard let name = trimmed(entry), !name.hasPrefix("darktable|"), let path = KeywordPath(names: [name]),
                  !named.contains(path.name), seen.insert(path.text).inserted
            else { continue }
            paths.append(path.text)
        }
        return paths
    }

    static func trimmed(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Writing

extension XMPFields {
    /// The changes that give `packet` (nil for a new `.xmp`) these values for `fields`, in
    /// `conventions`' names, with `xmp:MetadataDate` set to `now` when there are any; none for a
    /// field it holds already. A reject is `xmp:Rating` -1, which takes the place of the stars; a
    /// pick is Lightroom's `xmpDM:good`; a label is its name in the chosen set with its colour in
    /// `xmp:LabelColor`, and Urgency when `conventions` write it, and a custom label its name alone;
    /// keywords go to Lightroom's paths and the flat list; a title, caption and copyright to the
    /// default language, other languages kept (an empty default clears one beside them); creators to a
    /// sequence of names; and a location to IPTC Core's five properties.
    func changes(
        _ fields: Set<XMPField>, to packet: XMPPacket?, conventions: XMPConventions, now: Date,
    ) -> [(XMPProperty, XMPValue?)] {
        let current = packet.map { XMPSource(packet: $0, conventions: conventions) }?.fields ?? XMPFields()
        func has(_ property: XMPProperty) -> Bool {
            packet?.has(property) ?? false
        }
        var changes: [(XMPProperty, XMPValue?)] = []
        if !fields.isDisjoint(with: [.rating, .flag]) {
            let wanted = flag == .reject ? -1 : rating ?? 0
            let written = packet?.text(XMPNamespace.rating).flatMap(XMPSource.trimmed).flatMap(Double.init)
                .map { Int($0.rounded()) }
            if has(XMPNamespace.rating) ? written != wanted : wanted != 0 {
                changes.append((XMPNamespace.rating, .text(String(wanted))))
            }
        }
        if fields.contains(.flag) {
            let good = packet?.text(XMPNamespace.good).flatMap(XMPSource.trimmed)?.lowercased()
            if flag == .pick, good != "true" {
                changes.append((XMPNamespace.good, .text("True")))
            } else if flag != .pick, good == "true" {
                changes.append((XMPNamespace.good, nil))
            }
        }
        if fields.contains(.label), !current.same(.label, as: self) {
            if let label {
                changes.append((XMPNamespace.label, .text(conventions.labels.name(for: label))))
                changes.append((XMPNamespace.labelColor, .text(label.rawValue)))
                if conventions.urgency {
                    changes.append((XMPNamespace.urgency, .text(String(XMPUrgency.value(for: label)))))
                }
            } else if let custom = Self.text(customLabel) {
                changes.append((XMPNamespace.label, .text(custom)))
                var removed = [XMPNamespace.labelColor]
                if conventions.urgency {
                    removed.append(XMPNamespace.urgency)
                }
                changes += removed.filter(has).map { ($0, nil) }
            } else {
                var removed = [XMPNamespace.label, XMPNamespace.labelColor]
                if conventions.urgency {
                    removed.append(XMPNamespace.urgency)
                }
                changes += removed.filter(has).map { ($0, nil) }
            }
        }
        if fields.contains(.keywords), !current.same(.keywords, as: self) {
            if let keywords, !keywords.isEmpty {
                let keywords = KeywordPath.paths(keywords)
                let paths = keywords.map { $0.names.joined(separator: "|") }
                var names: [String] = []
                var seen = Set<String>()
                for name in keywords.flatMap(\.names) where seen.insert(name).inserted {
                    names.append(name)
                }
                changes.append((XMPNamespace.hierarchicalSubject, .bag(paths)))
                changes.append((XMPNamespace.subject, .bag(names)))
            } else {
                changes += [XMPNamespace.hierarchicalSubject, XMPNamespace.subject].filter(has).map { ($0, nil) }
            }
        }
        for (field, property, value) in [
            (XMPField.title, XMPNamespace.title, title),
            (.caption, XMPNamespace.description, caption),
            (.copyright, XMPNamespace.rights, copyright),
        ]
            where fields.contains(field) && !current.same(field, as: self) {
            if let value = Self.text(value) {
                changes.append((property, .alternative(value)))
            } else if has(property) {
                changes.append((property, packet?.hasOtherLanguages(property) == true ? .alternative("") : nil))
            }
        }
        if fields.contains(.creator), !current.same(.creator, as: self) {
            let names = Self.names(creator)
            if !names.isEmpty {
                changes.append((XMPNamespace.creator, .seq(names)))
            } else if has(XMPNamespace.creator) {
                changes.append((XMPNamespace.creator, nil))
            }
        }
        if fields.contains(.location), !current.same(.location, as: self) {
            let place = Self.place(location)
            let values = [place?.sublocation, place?.city, place?.state, place?.country, place?.countryCode]
            for (property, value) in zip(XMPSource.places, values) {
                if let value {
                    if packet?.text(property).flatMap(XMPSource.trimmed) != value {
                        changes.append((property, .text(value)))
                    }
                } else if has(property) {
                    changes.append((property, nil))
                }
            }
        }
        if !changes.isEmpty {
            changes.append((XMPNamespace.metadataDate, .text(Self.date(now))))
        }
        return changes
    }

    /// `packet` (a new one when nil) with `changes` made, once it's checked: it parses, as ImageIO
    /// reads it too; every property the changes leave alone is as it was; and it reads back with
    /// these values for `fields`. Nil when any check fails.
    func written(
        into packet: XMPPacket?, _ changes: [(XMPProperty, XMPValue?)], fields: Set<XMPField>,
        conventions: XMPConventions,
    ) -> [UInt8]? {
        let base = packet ?? XMPPacket.empty(toolkit: "Redlamp")
        guard let bytes = base.editing(changes, prefixes: XMPNamespace.prefixes), let edited = XMPPacket(bytes: bytes)
        else { return nil }
        let changed = Set(changes.map(\.0))
        func untouched(_ packet: XMPPacket) -> [String] {
            packet.properties().filter { !changed.contains($0.property) }
                .map { "\($0.property.namespace) \($0.property.name) \($0.written)" }.sorted()
        }
        let read = XMPSource(packet: edited, conventions: conventions).fields
        guard untouched(base) == untouched(edited), fields.allSatisfy({ represented($0, in: read) }),
              CGImageMetadataCreateFromXMPData(Data(bytes) as CFData) != nil
        else { return nil }
        return bytes
    }

    /// Whether `other` holds this one's value for `field`, as far as XMP can: a reject's stars have
    /// no place beside it.
    func represented(_ field: XMPField, in other: XMPFields) -> Bool {
        (field == .rating && flag == .reject && other.flag == .reject) || same(field, as: other)
    }

    /// As Adobe's apps write dates: `2026-10-05T23:30:12+01:00`.
    static func date(_ date: Date, in zone: TimeZone = .current) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: zone))
    }
}
