import Foundation
import RedlampDocument
import RedlampEngineAPI

/// A custom label the library's photos have, and how many have it.
public struct CustomLabelCount: Sendable, Hashable {
    public let name: String
    public let photos: Int

    public init(name: String, photos: Int) {
        self.name = name
        self.photos = photos
    }
}

extension IndexQueries {
    /// Each custom label the library's photos have, with how many have it, in Finder's order of their names;
    /// those of roots marked removed don't count.
    func customLabelCounts() throws -> [CustomLabelCount] {
        let statement = try database.cached("""
        SELECT custom_label, COUNT(*) FROM photos WHERE custom_label IS NOT NULL AND custom_label != ''
          AND \(inLibrary()) GROUP BY custom_label
        """)
        return try statement.map { CustomLabelCount(name: $0.string(at: 0) ?? "", photos: $0.int(at: 1)) }
            .sorted { FinderOrder.compare($0.name, $1.name) < 0 }
    }

    /// What the index shows of `keys` for each of `ids`, as the sidecar writes them, and which of the
    /// fields are other apps'; the photos the index doesn't have are left out.
    func metadataValues(ofPhotos ids: [Int64], keys: Set<String>) throws
        -> [Int64: (values: MetadataValues, others: Set<XMPField>)] {
        var found: [Int64: (values: MetadataValues, others: Set<XMPField>)] = [:]
        for id in ids {
            guard let row = try photo(id: id) else { continue }
            let collections = keys.contains("collections") ? try collections(ofPhoto: id).map(\.text) : []
            found[id] = (PhotoMetadata(shown: row, collections: collections).values(keys), row.otherFields)
        }
        return found
    }
}

extension PhotoMetadata {
    /// A photo's fields as its row shows them, in the sidecar's terms: the zone the camera's given is
    /// none where the row shows its file's.
    init(shown row: PhotoRecord, collections: [String] = []) {
        self.init(
            rating: row.rating, flag: row.flag, label: row.label, customLabel: row.customLabel, mark: row.marked,
            title: row.title, caption: row.caption, creator: row.creator, copyright: row.copyright,
            location: row.location, collections: collections, stack: row.stack, captureShift: row.captureShift,
            captureOffset: row.cameraCaptured != nil && row.capturedOffset != row.cameraOffset
                ? row.capturedOffset : nil,
        )
    }

    /// The field of `XMPField` a sidecar key is, for the keys other apps share.
    static func xmpField(_ key: String) -> XMPField? {
        switch key {
        case "rating": .rating
        case "flag": .flag
        case "label", "customLabel": .label
        case "keywords": .keywords
        case "title": .title
        case "caption": .caption
        case "creator": .creator
        case "copyright": .copyright
        case "location": .location
        default: nil
        }
    }
}

extension LibraryIndex.Writer {
    /// Shows `values` in `photo`'s row: each field's columns, its collections, its stack and its capture
    /// time, with its text indexed again; they're the `.redlamp`'s values now, but for the fields of
    /// `others`, which are other apps'.
    func setMetadata(_ values: MetadataValues, forPhoto photo: Int64, others: Set<XMPField> = []) throws {
        guard let metadata = PhotoMetadata().setting(values), var row = try self.photo(id: photo) else { return }
        for key in values.keys {
            switch key {
            case "rating": row.rating = metadata.rating
            case "flag": row.flag = metadata.flag
            case "mark": row.marked = metadata.mark
            case "title": row.title = XMPFields.text(metadata.title)
            case "caption": row.caption = XMPFields.text(metadata.caption)
            case "creator": row.creator = XMPSource.joined(XMPFields.names(metadata.creator))
            case "copyright": row.copyright = XMPFields.text(metadata.copyright)
            case "location": row.location = XMPFields.place(metadata.location)
            case "stack": row.stack = metadata.stack.flatMap { $0.id == nil && !$0.top ? nil : $0 }
            case "collections": try setCollections(metadata.collections, forPhoto: photo)
            default: break
            }
            if let field = PhotoMetadata.xmpField(key) {
                if others.contains(field) {
                    row.otherFields.insert(field)
                } else {
                    row.otherFields.remove(field)
                }
            }
        }
        if values.keys.contains("label") || values.keys.contains("customLabel") {
            row.label = values.keys.contains("label") ? metadata.label : row.label
            row.customLabel = row.label == nil ? XMPFields.text(metadata.customLabel) : nil
        }
        row.showCapture(values)
        try upsertPhotos([row])
    }
}

extension PhotoRecord {
    /// Shows the capture time the sidecar's `captureShift` and `captureOffset` among `values` give it;
    /// one they don't hold stays as the row shows it.
    mutating func showCapture(_ values: MetadataValues) {
        guard values.keys.contains("captureShift") || values.keys.contains("captureOffset") else { return }
        let given = PhotoMetadata().setting(values) ?? PhotoMetadata()
        let shown = PhotoMetadata(shown: self)
        showCapture(
            shift: values.keys.contains("captureShift") ? given.captureShift : shown.captureShift,
            offset: values.keys.contains("captureOffset") ? given.captureOffset : shown.captureOffset,
        )
    }
}

public extension MetadataPlan.Photo {
    /// The capture time and zone the photo shows once the plan has run, from `row`, its row now.
    func capture(of row: PhotoRecord) -> (time: Date?, offset: Int?) {
        var changed = row
        changed.showCapture(after)
        return (changed.captured, changed.capturedOffset)
    }
}
