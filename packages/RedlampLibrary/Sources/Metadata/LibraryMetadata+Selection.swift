import Foundation
import RedlampDocument

/// What photos share of a field (LIB-22): none of them has it, each has the same, or they differ.
public enum SharedValue: Sendable, Hashable {
    case none
    case same(String)
    case mixed

    /// The value they share; nil when none has it or they differ.
    public var text: String? {
        if case let .same(text) = self {
            return text
        }
        return nil
    }
}

/// The IPTC Core fields and capture times of a selection's photos, as the Metadata panel shows them
/// (LIB-22).
public struct SelectionFields: Sendable, Hashable {
    /// The photos the store has.
    public var photos = 0
    public var values: [MetadataPreset.Field: SharedValue] = [:]
    /// The earliest and latest of their capture times by the camera's clock, read as UTC, as
    /// `PhotoRecord.captured` holds them; nil when none has one.
    public var captured: ClosedRange<Date>?
    /// How many have no capture time.
    public var undated = 0

    public init() {}

    public subscript(field: MetadataPreset.Field) -> SharedValue {
        values[field] ?? .none
    }
}

public extension LibraryMetadata {
    /// What photos `ids` hold of IPTC Core's fields and when they were taken: from `store`, the query
    /// engine's column store, whose codes tell which photos share a creator, a copyright or a place, and
    /// which have a title or a caption; and from the index for the titles and captions themselves, read
    /// only when every photo has one, and only until two differ. A selection of thousands takes a pass over
    /// its rows, never one over the library.
    func fields(ofPhotos ids: some Sequence<Int64>, in store: ColumnStore) async throws -> SelectionFields {
        var rows: [Int] = []
        for id in Set(ids) {
            if let row = store.row(of: id), store.live.contains(row) {
                rows.append(row)
            }
        }
        rows.sort()
        var fields = SelectionFields()
        fields.photos = rows.count
        guard !rows.isEmpty else { return fields }
        var earliest = Int64.max
        var latest = Int64.min
        for row in rows {
            let captured = store.captured[row]
            if captured == .min {
                fields.undated += 1
            } else {
                earliest = min(earliest, captured)
                latest = max(latest, captured)
            }
        }
        if earliest <= latest {
            fields.captured = Self.date(earliest) ... Self.date(latest)
        }

        var unread: Set<MetadataPreset.Field> = []
        let codes: [(MetadataPreset.Field, NameCodes, StoreColumn<UInt16>)] = [
            (.creator, store.creatorNames, store.creators), (.copyright, store.copyrightNames, store.copyrights),
        ]
        for (field, names, column) in codes {
            if let shared = Self.shared(rows, code: { UInt32(column[$0]) }, ambiguous: names.limit, name: {
                names.name(of: Int($0))
            }) {
                fields.values[field] = shared
            } else {
                unread.insert(field)
            }
        }
        let parts: [(MetadataPreset.Field, PlaceCodes.Part)] = [
            (.sublocation, .sublocation), (.city, .city), (.state, .state), (.country, .country),
            (.countryCode, .countryCode),
        ]
        let places = store.placeNames
        for (field, part) in parts {
            fields.values[field] = Self.shared(
                rows, code: { places.code(of: part, at: Int(store.places[$0])) }, ambiguous: nil,
                name: { places.parts[part.rawValue].name(of: Int($0)) },
            ) ?? .mixed
        }
        for (field, detail) in [(MetadataPreset.Field.title, ColumnStore.Details.title), (.caption, .caption)] {
            let having = rows.count { store.details(at: $0).contains(detail) }
            if having == 0 {
                fields.values[field] = SharedValue.none
            } else if having < rows.count {
                fields.values[field] = .mixed
            } else {
                unread.insert(field)
            }
        }
        guard !unread.isEmpty else { return fields }
        let photos = rows.map { store.ids[$0] }
        let reading = unread
        let read = try await index.read { reader in try Self.shared(reading, of: photos, in: reader) }
        fields.values.merge(read) { _, read in read }
        return fields
    }

    /// `.none`, `.same` or `.mixed` from each row's code, 0 being none; nil when a code stands for more than
    /// one name (past the column's limit).
    private static func shared(
        _ rows: [Int], code: (Int) -> UInt32, ambiguous: UInt32?, name: (UInt32) -> String?,
    ) -> SharedValue? {
        let first = code(rows[0])
        if let ambiguous, first == ambiguous {
            return nil
        }
        for row in rows.dropFirst() {
            let other = code(row)
            if let ambiguous, other == ambiguous {
                return nil
            }
            if other != first {
                return .mixed
            }
        }
        return name(first).map(SharedValue.same) ?? SharedValue.none
    }

    /// What `photos` share of `fields` as the index has them, each read until two photos differ.
    private static func shared(
        _ fields: Set<MetadataPreset.Field>, of photos: [Int64], in reader: some IndexQueries,
    ) throws -> [MetadataPreset.Field: SharedValue] {
        let columns: [MetadataPreset.Field: Int32] = [.title: 0, .caption: 1, .creator: 2, .copyright: 3]
        let statement = try reader.database.cached("SELECT title, caption, creator, copyright FROM photos WHERE id = ?")
        var first: [MetadataPreset.Field: String?] = [:]
        var mixed = Set<MetadataPreset.Field>()
        for photo in photos where mixed.count < fields.count {
            try statement.bind(photo, at: 1)
            let values = try statement.first { row in
                fields.reduce(into: [MetadataPreset.Field: String?]()) { values, field in
                    values[field] = columns[field].flatMap { row.string(at: $0) }.flatMap { $0.isEmpty ? nil : $0 }
                }
            }
            guard let values else { continue }
            for (field, value) in values where !mixed.contains(field) {
                if let seen = first[field] {
                    if seen != value {
                        mixed.insert(field)
                    }
                } else {
                    first[field] = value
                }
            }
        }
        return fields.reduce(into: [:]) { shared, field in
            shared[field] = mixed.contains(field) ? .mixed
                : first[field].flatMap(\.self).map(SharedValue.same) ?? SharedValue.none
        }
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}

extension ColumnStore {
    /// The details of `row`: which of a location, keywords, a title and a caption it has.
    func details(at row: Int) -> Details {
        Details(rawValue: packed[row] >> Packed.detailsShift & 0x1F)
    }
}
