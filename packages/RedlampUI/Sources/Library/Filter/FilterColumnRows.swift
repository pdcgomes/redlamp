import Foundation
import RedlampDocument
import RedlampLibrary

/// A row of a metadata column: a value, how many photos have it, and the rows inside it (a year's
/// months, a month's days, a keyword's keywords, a set's collections, a folder's folders). The photos
/// without a value come last, as a row that can't be chosen.
final class FilterColumnRow: NSObject {
    /// The same for the same value as counts change, so the column keeps what's expanded.
    let key: String
    let title: String
    var count: Int
    /// The value its filter takes; nil for the photos without one.
    let value: LibraryQuery.Value?
    let children: [FilterColumnRow]

    init(key: String, title: String, count: Int, value: LibraryQuery.Value?, children: [FilterColumnRow] = []) {
        self.key = key
        self.title = title
        self.count = count
        self.value = value
        self.children = children
    }

    /// The rows of a column's counts: `folder` is the source's folder, which folders are shown below.
    static func rows(_ counts: FacetColumnCounts, folder: String?) -> [FilterColumnRow] {
        let known = counts.values.filter { $0.name != nil }
        let unknown = counts.values.first { $0.name == nil }.map { value in
            FilterColumnRow(key: "\u{0}none", title: unknownTitle(counts.column), count: value.count, value: nil)
        }
        let rows: [FilterColumnRow] = switch counts.column {
        case .date: dates(known)
        case .keyword, .collection: nested(known)
        case .folder: folders(known, below: folder)
        default: known.compactMap(flat(counts.column))
        }
        return rows + (unknown.map { [$0] } ?? [])
    }

    private static func unknownTitle(_ column: FacetColumn) -> String {
        switch column {
        case .keyword: "No Keywords"
        case .collection: "No Collection"
        case .date: "No Date"
        case .customLabel: "No Custom Label"
        case .orientation: "No Orientation"
        default: "Unknown"
        }
    }

    private static func flat(_ column: FacetColumn) -> (FacetValue) -> FilterColumnRow? {
        { value in
            guard let name = value.name, case let .filter(filter)? = value.filter, let first = filter.values.first
            else { return nil }
            return FilterColumnRow(key: name, title: title(name, column), count: value.count, value: first)
        }
    }

    /// A value as its column shows it.
    static func title(_ name: String, _ column: FacetColumn) -> String {
        switch column {
        case .iso: "ISO \(name)"
        case .focal: "\(name) mm"
        case .aperture: "f/\(name)"
        case .label: name == "none" ? "No Label" : ColorLabel(rawValue: name) == nil ? name : name.capitalized
        case .flag: ["pick": "Picked", "reject": "Rejected", "none": "Unflagged"][name] ?? name
        case .rating: Int(name).map { $0 == 0 ? "Unrated" : String(repeating: "★", count: $0) } ?? name
        case .kind: ["raw": "Raw", "jpeg": "JPEG", "heic": "HEIC", "tiff": "TIFF", "png": "PNG"][name] ?? name
        case .orientation: PhotoOrientation(rawValue: name)?.title ?? name
        default: name
        }
    }

    /// Days, under their months, under their years.
    private static func dates(_ values: [FacetValue]) -> [FilterColumnRow] {
        var years: [Int: [Int: [(day: Int, count: Int)]]] = [:]
        for value in values {
            let parts = (value.name ?? "").split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { continue }
            years[parts[0], default: [:]][parts[1], default: []].append((parts[2], value.count))
        }
        let months = monthNames
        return years.keys.sorted().map { year in
            let monthRows = (years[year] ?? [:]).keys.sorted().map { month in
                let days = (years[year]?[month] ?? []).sorted { $0.day < $1.day }
                let dayRows = days.map { day in
                    FilterColumnRow(
                        key: String(format: "%04d-%02d-%02d", year, month, day.day), title: "\(day.day)",
                        count: day.count, value: .date(.day(year, month, day.day)),
                    )
                }
                return FilterColumnRow(
                    key: String(format: "%04d-%02d", year, month),
                    title: months.indices.contains(month - 1) ? months[month - 1] : "\(month)",
                    count: dayRows.reduce(0) { $0 + $1.count }, value: .date(.month(year, month)), children: dayRows,
                )
            }
            return FilterColumnRow(
                key: String(format: "%04d", year), title: "\(year)", count: monthRows.reduce(0) { $0 + $1.count },
                value: .date(.year(year)), children: monthRows,
            )
        }
    }

    private static let monthNames = DateFormatter().monthSymbols ?? []

    /// Folders, each counting the photos in it, by their paths below the source's folder.
    private static func folders(_ values: [FacetValue], below folder: String?) -> [FilterColumnRow] {
        let base = folder.map { $0 == "/" ? "/" : $0 + "/" }
        let rows = values.compactMap { value -> (title: String, row: FilterColumnRow)? in
            guard let path = value.name else { return nil }
            let title = if path == folder {
                URL(fileURLWithPath: path).lastPathComponent
            } else if let base, path.hasPrefix(base) {
                String(path.dropFirst(base.count))
            } else {
                path
            }
            return (title, FilterColumnRow(key: path, title: title, count: value.count, value: .text(path)))
        }
        return rows.sorted { FileOrder.precedes($0.title, $1.title) }.map(\.row)
    }

    /// Keywords or collections, each under the keyword or set it's inside.
    private static func nested(_ values: [FacetValue]) -> [FilterColumnRow] {
        let counts = Dictionary(values.compactMap { value in value.name.map { ($0, value.count) } }) { first, _ in
            first
        }
        var children: [String: [String]] = [:]
        var tops: [String] = []
        for path in counts.keys {
            if let slash = path.lastIndex(of: "/"), counts[String(path[..<slash])] != nil {
                children[String(path[..<slash]), default: []].append(path)
            } else {
                tops.append(path)
            }
        }
        func row(_ path: String) -> FilterColumnRow {
            let inside = (children[path] ?? []).sorted { FileOrder.precedes($0, $1) }.map(row)
            return FilterColumnRow(
                key: path, title: KeywordPath(path)?.name ?? path, count: counts[path] ?? 0, value: .text(path),
                children: inside,
            )
        }
        return tops.sorted { FileOrder.precedes($0, $1) }.map(row)
    }

    // MARK: - What the filter chooses

    /// Whether `filter`, a column's choice, takes this row's photos.
    func isChosen(by filter: LibraryQuery.Filter?, in column: FacetColumn) -> Bool {
        guard let filter, let value else { return false }
        return filter.values.contains { Self.covers($0, value, comparison: filter.comparison, column: column) }
    }

    private static func covers(
        _ chosen: LibraryQuery.Value, _ value: LibraryQuery.Value, comparison: LibraryQuery.Comparison,
        column: FacetColumn,
    ) -> Bool {
        switch (chosen, value) {
        case let (.text(chosen), .text(name)):
            let (chosen, name) = (chosen.lowercased(), name.lowercased())
            switch column {
            case .keyword, .collection:
                return name == chosen || name.hasPrefix(chosen + "/") || name.hasSuffix("/" + chosen)
                    || name.contains("/" + chosen + "/")
            case .label, .customLabel:
                return name == chosen
            default:
                return name.contains(chosen)
            }
        case let (.date(chosen), .date(date)):
            return chosen.description.count <= date.description.count && date.description.hasPrefix(chosen.description)
        case let (.number(chosen), .number(number)):
            switch comparison {
            case .greaterOrEqual: return number >= chosen
            case .lessOrEqual: return number <= chosen
            case .greater: return number > chosen
            case .less: return number < chosen
            default: return number == chosen
            }
        default:
            return chosen == value
        }
    }

    /// The column's choice in `rules`: its first filter on the column's field that keeps photos.
    static func choice(in rules: QueryRules, column: FacetColumn) -> LibraryQuery.Filter? {
        let filter = rules.filters(on: column.field).first?.filter
        guard let filter else { return nil }
        if column == .rating {
            return filter.comparison == .notEqual ? nil : filter
        }
        return filter.comparison == .equal ? filter : nil
    }
}

public extension LibraryFilters {
    /// Chooses `values` in column `index`, or every photo when there are none.
    internal func choose(_ values: [LibraryQuery.Value], inColumn index: Int) {
        guard filter.columns.indices.contains(index) else { return }
        let field = filter.columns[index].field
        edit { $0.replacingFilters(on: field, with: values.isEmpty ? nil : LibraryQuery.Filter(field, .equal, values)) }
    }

    /// Column `index` counts by `column` from now on.
    func setColumn(_ index: Int, to column: FacetColumn) {
        var columns = filter.columns
        guard columns.indices.contains(index), columns[index] != column else { return }
        columns[index] = column
        setColumns(columns)
    }

    func addColumn(after index: Int) {
        var columns = filter.columns
        guard columns.count < LibraryFilter.maxColumns else { return }
        let unused = FacetColumn.allCases.first { !columns.contains($0) } ?? .date
        columns.insert(unused, at: min(index + 1, columns.count))
        setColumns(columns)
    }

    func removeColumn(_ index: Int) {
        var columns = filter.columns
        guard columns.count > 1, columns.indices.contains(index) else { return }
        columns.remove(at: index)
        setColumns(columns)
    }
}

public extension PhotoOrientation {
    /// Its name, as the orientation column and completion show it.
    var title: String {
        switch self {
        case .landscape: "Landscape"
        case .portrait: "Portrait"
        case .square: "Square"
        }
    }
}

public extension FacetColumn {
    /// The column's name, as its header shows it.
    var title: String {
        switch self {
        case .date: "Date"
        case .camera: "Camera"
        case .lens: "Lens"
        case .iso: "ISO Speed"
        case .focal: "Focal Length"
        case .aperture: "Aperture"
        case .keyword: "Keyword"
        case .label: "Label"
        case .folder: "Folder"
        case .kind: "File Type"
        case .orientation: "Orientation"
        case .flag: "Flag"
        case .rating: "Rating"
        case .creator: "Creator"
        case .city: "City"
        case .country: "Country"
        case .collection: "Collection"
        case .customLabel: "Custom Label"
        }
    }
}
