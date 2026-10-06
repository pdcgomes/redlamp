import Foundation
import ImageIO
import RedlampDocument
import UniformTypeIdentifiers

/// The fields other apps share through XMP, as Redlamp keeps them: a rating, a flag, a colour label,
/// keywords, a title and a caption. Each app's conventions for them come in through
/// `XMPSource.init(packet:conventions:)` and go out through `changes(_:to:conventions:now:)`.
public struct XMPFields: Sendable, Hashable, Codable {
    /// 1 to 5 stars; nil when unrated.
    public var rating: Int?
    public var flag: PhotoFlag?
    public var label: ColorLabel?
    /// A label none of the sets names ("Urgent", Capture One's "Orange"), as it's written. Read only,
    /// until the sidecar holds custom labels.
    public var customLabel: String?
    /// Each keyword's path from the top of its hierarchy: "Places/Portugal/Lisbon".
    public var keywords: [String]
    public var title: String?
    public var caption: String?

    public init(
        rating: Int? = nil, flag: PhotoFlag? = nil, label: ColorLabel? = nil, customLabel: String? = nil,
        keywords: [String] = [], title: String? = nil, caption: String? = nil,
    ) {
        self.rating = rating
        self.flag = flag
        self.label = label
        self.customLabel = customLabel
        self.keywords = keywords
        self.title = title
        self.caption = caption
    }

    /// The fields a `.redlamp` sidecar's metadata holds: a rating of 0 is none, and so are no keywords.
    public init(_ metadata: PhotoMetadata?) {
        self.init(
            rating: metadata.flatMap { $0.rating > 0 ? $0.rating : nil }, flag: metadata?.flag, label: metadata?.label,
            keywords: KeywordPath.texts(metadata?.keywords ?? []),
        )
    }

    public var isEmpty: Bool {
        XMPField.allCases.allSatisfy { !holds($0) } && customLabel == nil
    }

    /// Whether it has a value for `field`.
    public func holds(_ field: XMPField) -> Bool {
        switch field {
        case .rating: rating != nil
        case .flag: flag != nil
        case .label: label != nil
        case .keywords: !keywords.isEmpty
        case .title: title != nil
        case .caption: caption != nil
        }
    }

    /// Whether `other` has the same value for `field`: keywords in any order.
    public func same(_ field: XMPField, as other: XMPFields) -> Bool {
        switch field {
        case .rating: rating == other.rating
        case .flag: flag == other.flag
        case .label: label == other.label
        case .keywords: Set(keywords) == Set(other.keywords)
        case .title: title == other.title
        case .caption: caption == other.caption
        }
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
        }
        if fields.contains(.keywords) {
            applied.keywords = keywords
        }
        return applied
    }
}

/// A field `XMPFields` keeps.
public enum XMPField: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case rating, flag, label, keywords, title, caption

    /// The fields `.redlamp` sidecars hold. Titles and captions join with LIB-22: once `PhotoMetadata`
    /// has them, they're added here and to `XMPFields`' conversions to and from it, and they merge and
    /// are written as these are.
    public static let held: Set<XMPField> = [.rating, .flag, .label, .keywords]

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
            fields.keywords = Self.keywords(
                hierarchical: packet.items(XMPNamespace.hierarchicalSubject), flat: packet.items(XMPNamespace.subject),
            )
        }
        if packet.has(XMPNamespace.title) {
            present.insert(.title)
            fields.title = packet.alternative(XMPNamespace.title).flatMap(Self.trimmed)
        }
        if packet.has(XMPNamespace.description) {
            present.insert(.caption)
            fields.caption = packet.alternative(XMPNamespace.description).flatMap(Self.trimmed)
        }
        self.init(fields: fields, present: present)
    }

    /// What an `.xmp`'s bytes hold; nil when they aren't XMP.
    public init?(xmp data: Data, conventions: XMPConventions = XMPConventions()) {
        guard let packet = XMPPacket(data) else { return nil }
        self.init(packet: packet, conventions: conventions)
    }

    /// What a photo's own XMP holds, and its IPTC where the XMP has nothing (ImageIO mirrors most of
    /// each into the other); nil when ImageIO can't read the file or it holds none of the fields.
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
            iptc: properties?[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:], conventions: conventions,
        )
    }

    /// What a photo's own XMP (`xmp`, as ImageIO reads it) holds, and its IPTC (`iptc`) where the XMP
    /// has nothing; nil when it holds none of the fields. The indexer reads both from the image
    /// source it reads the rest of the photo's metadata from.
    static func embedded(
        _ xmp: XMPImageProperties, iptc: [CFString: Any], conventions: XMPConventions,
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
    /// `xmp:LabelColor`, and Urgency when `conventions` write it; keywords go to Lightroom's paths and
    /// the flat list; a title and caption to the default language.
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
        if fields.contains(.label), current.label != label {
            if let label {
                changes.append((XMPNamespace.label, .text(conventions.labels.name(for: label))))
                changes.append((XMPNamespace.labelColor, .text(label.rawValue)))
                if conventions.urgency {
                    changes.append((XMPNamespace.urgency, .text(String(XMPUrgency.value(for: label)))))
                }
            } else {
                var removed = [XMPNamespace.label, XMPNamespace.labelColor]
                if conventions.urgency {
                    removed.append(XMPNamespace.urgency)
                }
                changes += removed.filter(has).map { ($0, nil) }
            }
        }
        if fields.contains(.keywords), !current.same(.keywords, as: self) {
            if keywords.isEmpty {
                changes += [XMPNamespace.hierarchicalSubject, XMPNamespace.subject].filter(has).map { ($0, nil) }
            } else {
                let keywords = KeywordPath.paths(keywords)
                let paths = keywords.map { $0.names.joined(separator: "|") }
                var names: [String] = []
                var seen = Set<String>()
                for name in keywords.flatMap(\.names) where seen.insert(name).inserted {
                    names.append(name)
                }
                changes.append((XMPNamespace.hierarchicalSubject, .bag(paths)))
                changes.append((XMPNamespace.subject, .bag(names)))
            }
        }
        for (field, property, value) in [
            (XMPField.title, XMPNamespace.title, title),
            (.caption, XMPNamespace.description, caption),
        ]
            where fields.contains(field) && !current.same(field, as: self) {
            if let value {
                changes.append((property, .alternative(value)))
            } else if has(property) {
                changes.append((property, nil))
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
