import Foundation
import RedlampLibrary

/// The filter bar's sections, as Lightroom Classic's: Text, Attribute and Metadata. None of them
/// shown is the bar's None, which also turns the filter off.
public enum FilterSection: String, CaseIterable, Sendable, Codable {
    case text, attribute, metadata

    public var title: String {
        switch self {
        case .text: "Text"
        case .attribute: "Attribute"
        case .metadata: "Metadata"
        }
    }
}

/// A source's filter (LIB-18): one query in the library's language, which the Text section shows as
/// typed and the Attribute and Metadata sections read and write as rules; whether it's on (⌘L); the
/// sections shown; and the metadata columns, side by side, each narrowing the next.
public struct LibraryFilter: Sendable, Hashable, Codable {
    public var text: String
    public var isEnabled: Bool
    public var sections: Set<FilterSection>
    public var columns: [FacetColumn]

    public static let defaultColumns: [FacetColumn] = [.date, .camera, .lens, .label]
    /// Lightroom Classic shows up to eight.
    public static let maxColumns = 8

    public init(
        text: String = "", isEnabled: Bool = true, sections: Set<FilterSection> = [.text],
        columns: [FacetColumn] = LibraryFilter.defaultColumns,
    ) {
        self.text = text
        self.isEnabled = isEnabled
        self.sections = sections
        self.columns = columns
    }

    /// The text as the language reads it as you type: unfinished terms at its end left out.
    public var parsed: Result<LibraryQuery, LibraryQueryError> {
        Result { () throws(LibraryQueryError) in try LibraryQuery(parsing: text, asYouType: true) }
    }

    /// The query the photos are filtered by: nil when the filter is off, finds every photo, or can't
    /// be read.
    public var query: LibraryQuery? {
        guard isEnabled, case let .success(query) = parsed, query != .all else { return nil }
        return query
    }

    /// The query's rules, the empty rules when the text can't be read.
    public var rules: QueryRules {
        (try? parsed.get()).map(QueryRules.init) ?? QueryRules()
    }

    /// The same filter with the text the rules write.
    public func with(_ rules: QueryRules) -> LibraryFilter {
        var filter = self
        filter.text = rules.description
        filter.isEnabled = true
        return filter
    }

    /// Whether it finds every photo: nothing set, or off.
    public var isEmpty: Bool {
        query == nil
    }
}

/// What a source's photos are ordered by: the folder's own order (each folder's photos by name, a
/// folder before its subfolders), or one of the query language's sorts.
public enum LibrarySortField: String, CaseIterable, Sendable, Codable {
    case folder, captured, name, rating, edited, modified, size

    public var title: String {
        switch self {
        case .folder: "Folder Order"
        case .captured: "Capture Time"
        case .name: "File Name"
        case .rating: "Rating"
        case .edited: "Edit Time"
        case .modified: "Modified Date"
        case .size: "File Size"
        }
    }

    var key: QuerySort.Key? {
        switch self {
        case .folder: nil
        case .captured: .captured
        case .name: .name
        case .rating: .rating
        case .edited: .edited
        case .modified: .modified
        case .size: .size
        }
    }
}

/// A source's sort, ascending or descending.
public struct LibrarySort: Sendable, Hashable, Codable {
    public var field: LibrarySortField
    public var ascending: Bool

    public init(_ field: LibrarySortField = .folder, ascending: Bool = true) {
        self.field = field
        self.ascending = ascending
    }

    /// The query language's sort; nil for the folder's own order.
    var query: QuerySort? {
        field.key.map { QuerySort($0, ascending: ascending) }
    }
}

/// What a library list is filtered and sorted by (`LibraryFolderList`): no query and no sort is the
/// folder's photos in its own order, as Folders lists them, or the other way round when reversed.
struct LibraryListFilter: Sendable, Hashable {
    var query: LibraryQuery?
    var sort: QuerySort?
    var reversed = false
    /// The source's Tighter–Looser setting, which the query's `is:unpicked-moment` finds moments with
    /// (LIB-41); the default for a query without it, so the setting changes nothing else's list.
    var moments = MomentSetting()

    init(query: LibraryQuery? = nil, sort: LibrarySort = LibrarySort(), moments: MomentSetting = MomentSetting()) {
        self.query = query
        self.sort = sort.query
        reversed = sort.field == .folder && !sort.ascending
        if query?.findsMoments == true {
            self.moments = moments
        }
    }

    var isEmpty: Bool {
        query == nil && sort == nil && !reversed
    }
}

/// A saved filter (Lightroom Classic's filter presets): its query, its sections and its columns.
public struct FilterPreset: Sendable, Hashable, Codable, Identifiable {
    public var name: String
    public var filter: LibraryFilter
    public var isBuiltIn: Bool

    public var id: String {
        (isBuiltIn ? "built-in:" : "") + name
    }

    public init(name: String, filter: LibraryFilter, isBuiltIn: Bool = false) {
        self.name = name
        self.filter = filter
        self.isBuiltIn = isBuiltIn
    }

    /// Redlamp's own, after Lightroom Classic's defaults.
    public static let builtIn: [FilterPreset] = [
        ("Filters Off", LibraryFilter(isEnabled: false, sections: [])),
        ("Default Columns", LibraryFilter(sections: [.metadata])),
        ("Flagged", LibraryFilter(text: "flag:pick", sections: [.attribute])),
        ("Rated", LibraryFilter(text: "rating>=1", sections: [.attribute])),
        ("Unrated", LibraryFilter(text: "rating:0", sections: [.attribute])),
        ("Rejected", LibraryFilter(text: "flag:reject", sections: [.attribute])),
        ("Edited", LibraryFilter(text: "edited:yes", sections: [.attribute])),
        ("Raw Files", LibraryFilter(text: "ext:raw", sections: [.attribute])),
        ("Missing or Offline", LibraryFilter(text: "missing:yes OR offline:yes", sections: [.text])),
        (
            "Location Columns",
            LibraryFilter(sections: [.metadata], columns: [.folder, .date, .keyword, .camera]),
        ),
    ].map { FilterPreset(name: $0.0, filter: $0.1, isBuiltIn: true) }

    /// Whether choosing it gives `filter`: the same query, sections and columns, on or off alike.
    func matches(_ filter: LibraryFilter) -> Bool {
        self.filter.isEnabled == filter.isEnabled && self.filter.sections == filter.sections
            && self.filter.columns == filter.columns && self.filter.text == filter.text
    }
}
