import Foundation

/// A file as Redlamp last saw it.
public struct XMPFileStamp: Sendable, Hashable, Codable {
    public var size: Int64
    public var modified: Date

    public init(size: Int64, modified: Date) {
        self.size = size
        self.modified = modified
    }

    init(_ entry: FileEntry) {
        self.init(size: entry.size, modified: entry.modified)
    }

    /// The file at `url` as it is now; nil when there's none.
    init?(at url: URL) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: keys),
              let modified = values.contentModificationDate
        else { return nil }
        self.init(size: Int64(values.fileSize ?? 0), modified: modified)
    }

    /// Whether both say the same file, or neither has one, allowing for what storing a date as
    /// seconds since 1970 rounds away.
    static func same(_ lhs: XMPFileStamp?, _ rhs: XMPFileStamp?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?):
            lhs.size == rhs.size && abs(lhs.modified.timeIntervalSince1970 - rhs.modified.timeIntervalSince1970) < 1e-6
        default: false
        }
    }

    /// What the index keeps of a photo's `.xmp` files (`xmp_signature`): the size and modification date
    /// of each, hashed with which file it is, so it changes whenever either file does, comes or goes;
    /// nil when there's neither. Dates come from the same resource value in a listing and a stamp.
    static func signature(shared: XMPFileStamp?, darktable: XMPFileStamp?) -> Int64? {
        guard shared != nil || darktable != nil else { return nil }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for (marker, stamp) in [(UInt64(1), shared), (2, darktable)] {
            guard let stamp else { continue }
            hash = mix(hash ^ marker)
            hash = mix(hash &+ UInt64(bitPattern: stamp.size))
            hash = mix(hash &+ stamp.modified.timeIntervalSinceReferenceDate.bitPattern)
        }
        return Int64(bitPattern: hash)
    }

    /// SplitMix64's finaliser: every bit of the input reaches every bit of the output.
    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// What Redlamp recorded when it last merged a photo's other apps' fields into its `.redlamp`, or
/// wrote its `.xmp`: the files as they were, and the fields on each side. The next merge takes only
/// what changed since, so another app's change is taken once, and a `.xmp` Redlamp wrote isn't
/// taken for another app's. Kept in the index's settings, by photo; a rebuilt index merges as if
/// for the first time, which never loses a field the `.redlamp` holds.
public struct XMPMergeRecord: Sendable, Hashable, Codable {
    /// The `.xmp` the photo shares (`IMG_1234.xmp`).
    public var sidecar: XMPFileStamp?
    /// darktable's own (`IMG_1234.ARW.xmp`).
    public var darktable: XMPFileStamp?
    /// The photo, whose own XMP and IPTC count where no `.xmp` has a field.
    public var photo: XMPFileStamp?
    /// The `.redlamp` sidecar's edit.
    public var redlamp: XMPFileStamp?
    /// What the photo's own XMP and IPTC held, so they're read again only when the photo changes.
    public var embedded: XMPSource?
    /// Other apps' fields: each from the `.xmp`, then darktable's, then the photo's own.
    public var other: XMPFields
    /// The `.redlamp`'s fields once merged.
    public var redlampFields: XMPFields
    /// Fields the `.redlamp` decides that the `.xmp` doesn't hold: writing was off, or failed.
    public var unwritten: [XMPField]

    public init(
        sidecar: XMPFileStamp? = nil, darktable: XMPFileStamp? = nil, photo: XMPFileStamp? = nil,
        redlamp: XMPFileStamp? = nil, embedded: XMPSource? = nil, other: XMPFields, redlampFields: XMPFields,
        unwritten: [XMPField] = [],
    ) {
        self.sidecar = sidecar
        self.darktable = darktable
        self.photo = photo
        self.redlamp = redlamp
        self.embedded = embedded
        self.other = other
        self.redlampFields = redlampFields
        self.unwritten = unwritten
    }
}

/// Which side's value each field takes when a photo's `.redlamp` and other apps' XMP disagree.
///
/// - **Other apps' value** is the `.xmp`'s (`IMG_1234.xmp`), else darktable's (`IMG_1234.ARW.xmp`),
///   else the photo's own XMP, else its IPTC, field by field (`XMPSource.combining`).
/// - **The first time** (no record): a field the `.redlamp` holds keeps its value, which Redlamp
///   then decides; a field it doesn't hold takes other apps'.
/// - **After that**, against the record: a field other apps haven't changed keeps the `.redlamp`'s,
///   decided by Redlamp if it holds one or changed it since; a field only other apps changed takes
///   theirs, clearing included; a field both changed takes the later change, other apps' when
///   their file was modified after the `.redlamp` was saved.
///
/// Only the fields asked about are touched: whatever else the `.redlamp` holds stays as it is.
public enum XMPMerge {
    public struct Outcome: Sendable, Hashable {
        /// The `.redlamp`'s fields once merged.
        public var fields: XMPFields
        /// Fields taken from other apps.
        public var taken: [XMPField]
        /// Fields both sides changed, where the `.redlamp`'s later value stays.
        public var kept: [XMPField]
        /// Fields whose value is Redlamp's: what the `.xmp` gets when writing is on.
        public var decided: [XMPField]
    }

    public static func merge(
        redlamp: XMPFields, other: XMPFields, record: XMPMergeRecord?, fields: Set<XMPField> = XMPField.held,
        otherIsLater: Bool,
    ) -> Outcome {
        var outcome = Outcome(fields: redlamp, taken: [], kept: [], decided: [])
        for field in fields.sorted() {
            guard let record else {
                if redlamp.holds(field) {
                    outcome.decided.append(field)
                } else if other.holds(field) {
                    outcome.fields.take(field, from: other)
                    outcome.taken.append(field)
                }
                continue
            }
            let otherChanged = !other.same(field, as: record.other)
            let redlampChanged = !redlamp.same(field, as: record.redlampFields)
            if !otherChanged || redlamp.same(field, as: other) {
                if redlamp.holds(field) || redlampChanged {
                    outcome.decided.append(field)
                }
            } else if !redlampChanged || otherIsLater {
                outcome.fields.take(field, from: other)
                outcome.taken.append(field)
            } else {
                outcome.kept.append(field)
                outcome.decided.append(field)
            }
        }
        return outcome
    }

    /// Whether other apps changed the photo after its `.redlamp` was saved, `merge`'s `otherIsLater`:
    /// the latest of its `.xmp`, darktable's and the photo itself to differ from `record` (all that
    /// exist, without a record), against when the `.redlamp` was saved.
    static func otherIsLater(
        _ record: XMPMergeRecord?, sidecar: XMPFileStamp?, darktable: XMPFileStamp?, photo: XMPFileStamp?,
        redlampSaved: Date?,
    ) -> Bool {
        let changed = [(record?.sidecar, sidecar), (record?.darktable, darktable), (record?.photo, photo)]
            .compactMap { recorded, now -> Date? in
                guard let now, record == nil || !XMPFileStamp.same(recorded, now) else { return nil }
                return now.modified
            }
        return changed.max().map { $0 > redlampSaved ?? .distantPast } ?? false
    }
}
