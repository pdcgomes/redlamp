import Foundation

/// The library's choices for other apps' metadata (DEC-37), in the index's settings: other apps'
/// XMP is always read; standard `.xmp` sidecars are written only once the user turns it on.
public struct XMPSettings: Sendable, Hashable, Codable {
    /// Off by default.
    public var writes: Bool
    public var conventions: XMPConventions

    public init(writes: Bool = false, conventions: XMPConventions = XMPConventions()) {
        self.writes = writes
        self.conventions = conventions
    }

    static let writesKey = "library.xmp.write"
    static let labelsKey = "library.xmp.labels"
    static let urgencyKey = "library.xmp.urgency"

    /// The settings `reader`'s index holds; the defaults for those it doesn't.
    init(_ reader: some IndexQueries) throws {
        try self.init(
            writes: reader.setting(Self.writesKey) == "1",
            conventions: XMPConventions(
                labels: reader.setting(Self.labelsKey).flatMap(XMPLabelNames.init(rawValue:)) ?? .lightroom,
                urgency: reader.setting(Self.urgencyKey) == "1",
            ),
        )
    }

    /// Keeps them in `writer`'s index, leaving out the defaults.
    func save(_ writer: LibraryIndex.Writer) throws {
        try writer.setSetting(writes ? "1" : nil, for: Self.writesKey)
        try writer.setSetting(conventions.labels == .lightroom ? nil : conventions.labels.rawValue, for: Self.labelsKey)
        try writer.setSetting(conventions.urgency ? "1" : nil, for: Self.urgencyKey)
    }
}

extension XMPMergeRecord {
    static func key(_ photo: Int64) -> String {
        "library.xmp.merged.\(photo)"
    }

    /// The records `reader`'s index holds for `photos`, by photo.
    static func records(
        _ photos: some Sequence<Int64>,
        in reader: some IndexQueries,
    ) throws -> [Int64: XMPMergeRecord] {
        let decoder = JSONDecoder()
        var records: [Int64: XMPMergeRecord] = [:]
        for photo in photos {
            guard let text = try reader.setting(key(photo)),
                  let record = try? decoder.decode(XMPMergeRecord.self, from: Data(text.utf8))
            else { continue }
            records[photo] = record
        }
        return records
    }

    /// Keeps `records` in `writer`'s index in place of the photos' earlier ones, and drops the
    /// records of `dropped`.
    static func save(
        _ records: [Int64: XMPMergeRecord],
        dropping dropped: [Int64],
        in writer: LibraryIndex.Writer,
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (photo, record) in records {
            try writer.setSetting(String(decoding: encoder.encode(record), as: UTF8.self), for: key(photo))
        }
        for photo in dropped {
            try writer.setSetting(nil, for: key(photo))
        }
    }
}
