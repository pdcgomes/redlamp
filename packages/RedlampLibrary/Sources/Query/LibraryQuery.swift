import Foundation
import RedlampDocument

/// A search in the library's query language (docs/plans/2026-10-05-library-design.md, The query
/// language), which the filter bar, the command palette, smart collections and
/// `redlamp library search` share. Words are free text; `field:value` and comparisons filter; `-`
/// leaves photos out; `OR` and parentheses group; quotes keep spaces; a comma list
/// (`label:red,blue`) matches any of its values.
///
/// `description` is the query's canonical text, which parses back to the same query. Parsing
/// flattens groups: an `and` holds no `and` and an `or` no `or`, each with two queries or more.
///
/// Text is matched with the index's trigrams, so free text and the values of `name`, `title`,
/// `caption` and an extension in `ext` need three characters to narrow a search: shorter ones are
/// kept in the query, and left out when it's run.
public indirect enum LibraryQuery: Sendable, Hashable {
    /// Every photo: the empty query.
    case all
    /// Free text: in a photo's name, folder, keywords, title, caption, camera, lens, creator or
    /// location, ignoring case.
    case text(String)
    case filter(Filter)
    case not(LibraryQuery)
    case and([LibraryQuery])
    case or([LibraryQuery])

    /// `field:value`, a comparison or a comma list.
    public struct Filter: Sendable, Hashable {
        public var field: Field
        public var comparison: Comparison
        /// One value, or several when any of them will do.
        public var values: [Value]

        public init(_ field: Field, _ comparison: Comparison = .equal, _ values: [Value]) {
            self.field = field
            self.comparison = comparison
            self.values = values
        }
    }

    public enum Field: String, Sendable, Hashable, CaseIterable {
        /// 0 to 5 stars (`stars`).
        case rating
        /// `pick`, `reject` or `none`.
        case flag
        /// A colour, a custom label's name, ignoring case, or `none`: neither. A name one of the label
        /// sets gives a colour (`XMPLabelNames`, Bridge's Approved for green) also finds that colour.
        case label
        /// `yes` or `no`: in the quick collection.
        case marked
        /// `yes` or `no`.
        case edited
        /// A keyword or a path (`keyword`); a parent matches its children.
        case keyword = "kw"
        /// A substring of the camera's name.
        case camera
        /// A substring of the lens's name.
        case lens
        case iso
        /// The f-number.
        case aperture = "f"
        /// Millimetres.
        case focal
        /// Seconds.
        case shutter
        /// When the photo was taken (`taken`).
        case date
        /// A substring of the folder's path (`in`).
        case folder
        /// A substring of the file's name.
        case name
        /// A kind of file (`raw`, `jpeg`, `heic`, `tiff`, `png`) or an extension (`type`).
        case ext
        /// A collection's name or path, as a keyword's is; a set matches the collections in it.
        case collection
        /// `gps`, `keywords`, `caption`, `title`, `xmp`, `creator`, `copyright` or `location`.
        case has
        case title
        case caption
        /// `yes` or `no`: gone from its folder.
        case missing
        /// `yes` or `no`: on a volume that isn't connected.
        case offline
        /// Substrings of IPTC Core's creator (the names of who made the photo) and copyright notice.
        case creator
        case copyright
        /// Substrings of the parts of IPTC Core's location: a place within the city, the city, the
        /// state or province (`province`), the country, and the country's ISO 3166 code.
        case sublocation
        case city
        case state
        case country
        case countryCode = "countrycode"
        /// The pixels, width times height, in millions (`mp`).
        case megapixels
        /// The long side over the short: `1.5` or `3:2`, whichever way the photo is turned.
        case aspect
        /// A trait (`Trait`), such as `is:long-exposure`: a name for a query over the other fields.
        case trait = "is"

        /// The other names fields go by.
        public static let aliases: [String: Field] = [
            "stars": .rating, "keyword": .keyword, "taken": .date, "in": .folder, "type": .ext, "province": .state,
            "mp": .megapixels,
        ]

        /// The field `name` names, ignoring case: its own name or an alias.
        public init?(name: String) {
            let lowered = name.lowercased()
            guard let field = Field(rawValue: lowered) ?? Self.aliases[lowered] else { return nil }
            self = field
        }

        /// Whether it can be compared with `<`, `<=`, `>` and `>=`, and take ranges.
        public var isOrdered: Bool {
            switch self {
            case .rating, .iso, .aperture, .focal, .shutter, .date, .megapixels, .aspect: true
            default: false
            }
        }
    }

    public enum Comparison: String, Sendable, Hashable, CaseIterable {
        /// `:` or `=`: the value, a substring of it, a range or one of a list.
        case equal = ":"
        case notEqual = "!="
        case less = "<"
        case lessOrEqual = "<="
        case greater = ">"
        case greaterOrEqual = ">="

        /// `<`, `<=`, `>` or `>=`.
        public var isOrdering: Bool {
            self != .equal && self != .notEqual
        }
    }

    public enum Value: Sendable, Hashable {
        /// A substring, a keyword's or collection's path, an extension, or a custom label's name.
        case text(String)
        case number(Double)
        /// `a..b`, either end open; both ends included.
        case numberRange(Double?, Double?)
        case date(QueryDate)
        /// `a..b`, either end open; both ends included.
        case dateRange(QueryDate?, QueryDate?)
        /// `none` is nil.
        case flag(PhotoFlag?)
        /// `none` is nil.
        case label(ColorLabel?)
        /// `yes` or `no`.
        case bool(Bool)
        case kind(PhotoRecord.Kind)
        case detail(Detail)
        case trait(Trait)
    }

    /// A trait (LIB-06): a name for a query over the index's fields, written `is:` and its name, and
    /// offered as the filter bar completes what's typed.
    public enum Trait: String, Sendable, Hashable, CaseIterable {
        /// A second or more: `shutter>=1`.
        case longExposure = "long-exposure"
        /// The long side twice the short or more: `aspect>=2`.
        case panorama
        /// 40 megapixels or more: `megapixels>=40`.
        case highResolution = "high-resolution"
        /// ISO 3200 or more: `iso>=3200`.
        case lowLight = "low-light"
        /// No GPS position: `-has:gps`.
        case noLocation = "no-location"

        /// Its name as the filter bar shows it.
        public var title: String {
            switch self {
            case .longExposure: "Long Exposure"
            case .panorama: "Panorama"
            case .highResolution: "High Resolution"
            case .lowLight: "Low Light"
            case .noLocation: "No Location"
            }
        }

        /// The query it stands for.
        public var query: LibraryQuery {
            switch self {
            case .longExposure: .filter(Filter(.shutter, .greaterOrEqual, [.number(1)]))
            case .panorama: .filter(Filter(.aspect, .greaterOrEqual, [.number(2)]))
            case .highResolution: .filter(Filter(.megapixels, .greaterOrEqual, [.number(40)]))
            case .lowLight: .filter(Filter(.iso, .greaterOrEqual, [.number(3200)]))
            case .noLocation: .not(.filter(Filter(.has, .equal, [.detail(.gps)])))
            }
        }
    }

    /// What a photo `has`.
    public enum Detail: String, Sendable, Hashable, CaseIterable {
        /// A GPS position.
        case gps
        case keywords
        case caption
        case title
        /// Another app's `.xmp` beside it.
        case xmp
        case creator
        case copyright
        /// Any part of IPTC Core's location.
        case location
    }
}

/// A date in the query language: a year, a month or a day of the capture time as the camera's
/// clock showed it, or a span ending today.
public enum QueryDate: Sendable, Hashable {
    case year(Int)
    case month(Int, Int)
    case day(Int, Int, Int)
    case today
    case yesterday
    /// The last `count` days, weeks, months or years, today included: `last:30d`.
    case last(Int, Unit)

    public enum Unit: String, Sendable, Hashable, CaseIterable {
        case days = "d"
        case weeks = "w"
        case months = "m"
        case years = "y"
    }
}

/// Why a query couldn't be read: the characters at fault and what's wrong with them.
public struct LibraryQueryError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Offsets into the query's characters.
    public let range: Range<Int>
    public let message: String

    public init(range: Range<Int>, message: String) {
        self.range = range
        self.message = message
    }

    public var description: String {
        message
    }
}
