import Foundation
import RedlampDocument

/// One photo of a synthetic library, as the generator chose it: what its file, sidecar and
/// other app's `.xmp` say. A raw's camera, lens and exposure are its source's, as ImageIO reads
/// them; only its capture date is new.
public struct FixturePhoto: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case raw, jpeg, heic
    }

    /// Redlamp's `.redlamp` sidecar.
    public struct Sidecar: Sendable, Hashable {
        public let rating: Int
        public let flag: PhotoFlag?
        public let label: ColorLabel?
        /// The recipe isn't the default one.
        public let edited: Bool
    }

    /// Another app's `.xmp` beside the photo, named after it without its extension.
    public struct OtherXMP: Sendable, Hashable {
        public let rating: Int
        public let label: ColorLabel?
        public let keywords: [String]
    }

    public struct Location: Sendable, Hashable {
        public let latitude: Double
        public let longitude: Double
    }

    /// Its place in the library, from 0.
    public let index: Int
    /// Its folder, below the fixture's root, `/`-separated.
    public let folder: String
    public let name: String
    public let kind: Kind
    public let make: String?
    public let model: String?
    public let lens: String?
    public let iso: Int?
    public let aperture: Double?
    /// In seconds.
    public let exposureTime: Double?
    /// In millimetres.
    public let focalLength: Double?
    public let captured: FixtureDate
    public let location: Location?
    /// The IPTC keywords and caption in the file.
    public let embeddedKeywords: [String]
    public let caption: String?
    public let sidecar: Sidecar?
    public let xmp: OtherXMP?
    /// For a raw, the index of the source it's a clone of.
    public let source: Int?

    /// Below the fixture's root.
    public var path: String {
        folder + "/" + name
    }

    /// The `.xmp` another app would write: the photo's name without its extension.
    public var xmpName: String {
        (name as NSString).deletingPathExtension + ".xmp"
    }

    public var rating: Int {
        sidecar?.rating ?? xmp?.rating ?? 0
    }

    public var flag: PhotoFlag? {
        sidecar?.flag
    }

    public var label: ColorLabel? {
        sidecar?.label ?? xmp?.label
    }

    public var isEdited: Bool {
        sidecar?.edited ?? false
    }

    public var keywords: [String] {
        embeddedKeywords + (xmp?.keywords ?? [])
    }

    /// Make and model, as `camera:` searches them.
    public var camera: String {
        [make, model].compactMap(\.self).joined(separator: " ")
    }
}

/// A capture date and time as EXIF holds it: local time, with no time zone. Times are kept
/// between 07:00 and 21:00, away from midnight and from daylight saving's changes, so the
/// day doesn't depend on the zone a reader assumes.
public struct FixtureDate: Sendable, Hashable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let second: Int

    /// `days` after 1 January 1970, `seconds` into the day.
    init(days: Int, seconds: Int) {
        (year, month, day) = Self.civil(days)
        hour = seconds / 3600
        minute = seconds / 60 % 60
        second = seconds % 60
    }

    /// `2019:06:14 10:32:05`, always 19 characters.
    public var exif: String {
        "\(digits(year, 4)):\(digits(month)):\(digits(day)) \(digits(hour)):\(digits(minute)):\(digits(second))"
    }

    /// `2019-06-14`.
    public var dayName: String {
        "\(digits(year, 4))-\(digits(month))-\(digits(day))"
    }

    /// The same wall-clock time in UTC.
    public var date: Date {
        Date(timeIntervalSince1970: Double(Self.days(year, month, day) * 86400 + hour * 3600 + minute * 60 + second))
    }

    public static func < (lhs: FixtureDate, rhs: FixtureDate) -> Bool {
        (lhs.year, lhs.month, lhs.day, lhs.hour, lhs.minute, lhs.second)
            < (rhs.year, rhs.month, rhs.day, rhs.hour, rhs.minute, rhs.second)
    }

    /// Days after 1 January 1970 (Howard Hinnant's `days_from_civil`).
    static func days(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The year, month and day `days` after 1 January 1970 (`civil_from_days`).
    static func civil(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shifted = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shifted + 2) / 5 + 1
        let month = shifted < 10 ? shifted + 3 : shifted - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}

/// `value` in decimal, zero-padded to `width` digits.
func digits(_ value: Int, _ width: Int = 2) -> String {
    let text = String(value)
    return text.count < width ? String(repeating: "0", count: width - text.count) + text : text
}
