import Foundation
import RedlampDocument

/// The packed `UInt16` of each row: rating (3 bits), flag (2), label (3), marked, edited, and the
/// details `has` asks about.
enum Packed {
    static let flagShift: UInt16 = 3
    static let labelShift: UInt16 = 5
    static let marked: UInt16 = 1 << 8
    static let edited: UInt16 = 1 << 9
    /// `Details` from here up.
    static let detailsShift: UInt16 = 10

    static func pack(_ row: ColumnStore.Row) -> UInt16 {
        let hot = row.hot
        var packed = UInt16(clamping: max(0, min(7, hot.rating)))
        packed |= UInt16(clamping: max(0, min(3, hot.flag))) << flagShift
        packed |= UInt16(clamping: max(0, min(7, hot.label))) << labelShift
        packed |= hot.marked ? marked : 0
        packed |= hot.edited ? edited : 0
        return packed | (row.details.rawValue & 0x1F) << detailsShift
    }

    @inline(__always)
    static func rating(_ packed: UInt16) -> UInt16 {
        packed & 0x7
    }

    @inline(__always)
    static func flag(_ packed: UInt16) -> UInt16 {
        packed >> flagShift & 0x3
    }

    @inline(__always)
    static func label(_ packed: UInt16) -> UInt16 {
        packed >> labelShift & 0x7
    }

    static func details(_ details: ColumnStore.Details) -> UInt16 {
        (details.rawValue & 0x1F) << detailsShift
    }
}

/// How numbers are kept in the store, and the SQL that computes the same from the index's columns
/// (`p` being `photos`). Each is whole: a comparison with a value of the language encodes the value
/// alike, so `f:2.8` matches an aperture of 2.8 however the file rounded it. 0 is none, except
/// where noted.
enum ColumnEncoding {
    /// Milliseconds, truncated as SQLite's `CAST` truncates; `Int64.min` for none.
    static func captured(_ seconds: Double?) -> Int64 {
        guard let seconds, !seconds.isNaN else { return .min }
        return saturated(seconds * 1000)
    }

    static let capturedSQL = """
    (CASE WHEN p.captured IS NULL THEN -9223372036854775807 - 1 ELSE CAST(p.captured * 1000 AS INTEGER) END)
    """

    /// Whole ISO, 1 to 65,535.
    static func iso(_ iso: Double?) -> UInt16 {
        UInt16(scaled(iso, by: 1, limit: Double(UInt16.max)))
    }

    static let isoSQL = scaledSQL("p.iso", by: "1", limit: "65535")

    /// Hundredths of an f-number, 1 to 65,535.
    static func aperture(_ aperture: Double?) -> UInt16 {
        UInt16(scaled(aperture, by: 100, limit: Double(UInt16.max)))
    }

    static let apertureSQL = scaledSQL("p.aperture", by: "100", limit: "65535")

    /// Tenths of a millimetre, 1 to 65,535.
    static func focal(_ focal: Double?) -> UInt16 {
        UInt16(scaled(focal, by: 10, limit: Double(UInt16.max)))
    }

    static let focalSQL = scaledSQL("p.focal", by: "10", limit: "65535")

    /// Microseconds, 1 to 4,294,967,295 (71 minutes).
    static func shutter(_ shutter: Double?) -> UInt32 {
        UInt32(scaled(shutter, by: 1_000_000, limit: Double(UInt32.max)))
    }

    static let shutterSQL = scaledSQL("p.shutter", by: "1000000", limit: "4294967295")

    /// Tenths of a megapixel, rounded half up, 1 to 65,535; 0 without both sides.
    static func megapixels(width: Int?, height: Int?) -> UInt16 {
        guard let width, let height, width > 0, height > 0 else { return 0 }
        return UInt16(max(1, min(65535, (Int64(width) * Int64(height) + 50000) / 100_000)))
    }

    static let megapixelsSQL = """
    (CASE WHEN p.width > 0 AND p.height > 0 \
    THEN max(1, min(65535, (CAST(p.width AS INTEGER) * CAST(p.height AS INTEGER) + 50000) / 100000)) ELSE 0 END)
    """

    /// The long side over the short in hundredths, rounded half up, 100 to 65,535; 0 without both sides.
    static func aspect(width: Int?, height: Int?) -> UInt16 {
        guard let width, let height, width > 0, height > 0 else { return 0 }
        let (long, short) = (Int64(max(width, height)), Int64(min(width, height)))
        return UInt16(min(65535, (long * 100 + short / 2) / short))
    }

    static let aspectSQL = """
    (CASE WHEN p.width > 0 AND p.height > 0 THEN min(65535, \
    (max(CAST(p.width AS INTEGER), CAST(p.height AS INTEGER)) * 100 \
    + min(CAST(p.width AS INTEGER), CAST(p.height AS INTEGER)) / 2) \
    / min(CAST(p.width AS INTEGER), CAST(p.height AS INTEGER))) ELSE 0 END)
    """

    /// Which way a photo is turned (`PhotoOrientation.code`), from its size as the index keeps it, which
    /// the indexer turns upright by EXIF's orientation, a raw's own rather than its sensor's; 0 without
    /// both sides.
    static func orientation(width: Int?, height: Int?) -> UInt8 {
        PhotoOrientation(width: width, height: height)?.code ?? 0
    }

    static let orientationSQL = """
    (CASE WHEN p.width > 0 AND p.height > 0 \
    THEN (CASE WHEN p.width > p.height THEN 1 WHEN p.width < p.height THEN 2 ELSE 3 END) ELSE 0 END)
    """

    /// Seconds since 2001, for a photo with an edit; `Int32.min` without.
    static func editedAt(edited: Bool, sidecarModified: Double?) -> Int32 {
        guard edited, let modified = sidecarModified, !modified.isNaN else { return .min }
        let seconds = modified - 978_307_200
        if seconds >= 2_147_483_647 {
            return .max
        }
        return seconds <= -2_147_483_647 ? -2_147_483_647 : Int32(seconds)
    }

    static let editedAtSQL = """
    (CASE WHEN p.edited != 0 AND p.sidecar_modified IS NOT NULL \
    THEN max(-2147483647, min(2147483647, CAST(p.sidecar_modified - 978307200 AS INTEGER))) ELSE -2147483648 END)
    """

    /// Seconds since 2001 as `editedAt` keeps them; `Int32.min` for none.
    static func modifiedAt(_ modified: Double?) -> Int32 {
        guard let modified, !modified.isNaN else { return .min }
        return editedAt(edited: true, sidecarModified: modified)
    }

    static let modifiedAtSQL = """
    (CASE WHEN p.modified IS NULL THEN -2147483648 \
    ELSE max(-2147483647, min(2147483647, CAST(p.modified - 978307200 AS INTEGER))) END)
    """

    /// Bytes, up to 4 GiB less one: larger files sort together at the end.
    static func fileSize(_ size: Int64) -> UInt32 {
        UInt32(clamping: max(size, 0))
    }

    static let fileSizeSQL = "max(0, min(4294967295, p.size))"

    /// `PhotoRecord.State`'s bits, as the state column of the store keeps them.
    static let stateSQL = "(p.state & 255)"

    static let ratingSQL = "max(0, min(7, p.rating))"
    static let flagSQL = "max(0, min(3, p.flag))"
    static let labelSQL = "max(0, min(7, p.label))"
    static let kindSQL = "max(0, min(255, p.kind))"

    /// The details `has` asks about, as the extra columns' scan reads them.
    static let locationSQL = "(p.latitude IS NOT NULL AND p.longitude IS NOT NULL)"
    static let titleSQL = "(coalesce(p.title, '') != '')"
    static let captionSQL = "(coalesce(p.caption, '') != '')"
    static let xmpSQL = "(p.xmp_modified IS NOT NULL)"
    static let keywordsSQL = "EXISTS (SELECT 1 FROM photo_keywords k WHERE k.photo = p.id)"

    /// Whether a text column has a name, as the code columns read it: an empty text is none.
    static func presentSQL(_ column: String) -> String {
        "(coalesce(\(column), '') != '')"
    }

    /// `value` times `scale`, rounded half up and truncated as SQLite's `CAST` does, between 1 and
    /// `limit`; 0 for none.
    static func scaled(_ value: Double?, by scale: Double, limit: Double) -> UInt64 {
        guard let value, !value.isNaN else { return 0 }
        let scaled = value * scale + 0.5
        if scaled >= limit {
            return UInt64(limit)
        }
        return scaled < 1 ? 1 : UInt64(scaled)
    }

    private static func scaledSQL(_ column: String, by scale: String, limit: String) -> String {
        "(CASE WHEN \(column) IS NULL THEN 0 ELSE max(1, min(\(limit), CAST(\(column) * \(scale) + 0.5 AS INTEGER))) END)"
    }

    /// `value` truncated to a whole number, saturating at `Int64`'s ends as SQLite's `CAST` does.
    static func saturated(_ value: Double) -> Int64 {
        if value >= 9_223_372_036_854_775_808.0 {
            return .max
        }
        return value <= -9_223_372_036_854_775_808.0 ? .min : Int64(value)
    }
}
