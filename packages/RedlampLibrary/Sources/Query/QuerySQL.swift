import Foundation
import SQLite3
import Synchronization

/// A query compiled to SQL over the index, which answers before the column store is ready, and
/// which the column engine is checked against (`QueryDifferentialTests`). It computes the store's
/// encodings (`ColumnEncoding`) and matches text with the same functions (`QueryText`), registered
/// with SQLite, so both engines answer alike, in the same order.
struct QuerySQL: Sendable, Hashable {
    enum Binding: Sendable, Hashable {
        case integer(Int64)
        case text(String)
    }

    var sql: String
    var bindings: [Binding]

    /// The photos `query` finds, in `sort`'s order; nil finds every photo. `query` has been through
    /// `LibraryQuery.searchable`. `synonyms` are the keywords' synonyms, by path. Photos that can't
    /// be read are left out unless the query names `unreadable`, as lists leave them out (LIB-40).
    init(_ query: LibraryQuery?, sort: QuerySort, today: Int, synonyms: [String: [String]] = [:]) {
        var compiler = Compiler(today: today, synonyms: KeywordSynonyms(synonyms))
        var predicate = query.map { compiler.predicate($0) } ?? "1"
        if query?.findsUnreadable != true {
            predicate = "(\(predicate)) AND (\(ColumnEncoding.stateSQL) & \(PhotoRecord.State.unreadable.rawValue)) = 0"
        }
        let direction = sort.ascending ? "" : " DESC"
        let keys: [String] = switch sort.key {
        case .captured: [ColumnEncoding.capturedSQL, "p.id"]
        case .name: ["p.name COLLATE redlamp_finder", "p.id"]
        case .rating: [ColumnEncoding.ratingSQL, ColumnEncoding.capturedSQL, "p.id"]
        case .edited: [ColumnEncoding.editedAtSQL, ColumnEncoding.capturedSQL, "p.id"]
        case .modified: [ColumnEncoding.modifiedAtSQL, ColumnEncoding.capturedSQL, "p.id"]
        case .size: [ColumnEncoding.fileSizeSQL, ColumnEncoding.capturedSQL, "p.id"]
        }
        sql = "SELECT p.id FROM photos p WHERE \(predicate) ORDER BY "
            + keys.map { $0 + direction }.joined(separator: ", ")
        bindings = compiler.bindings
    }

    private struct Compiler {
        let today: Int
        let synonyms: KeywordSynonyms
        var bindings: [Binding] = []

        /// A predicate that's never NULL, so `NOT` leaves out exactly what it keeps.
        mutating func predicate(_ query: LibraryQuery) -> String {
            switch query {
            case .all:
                return "1"
            case let .text(text):
                var alternatives: [String] = []
                if QueryText.isSearchable(text) {
                    alternatives.append(textMatch(QueryText.match(text)))
                }
                alternatives.append("p.folder IN (SELECT id FROM folders WHERE redlamp_contains(path, \(bind(text))))")
                alternatives.append(Self.named("camera", "cameras", bind(text)))
                alternatives.append(Self.named("lens", "lenses", bind(text)))
                for column in ["creator"] + PlaceCodes.Part.allCases.map(\.column) {
                    alternatives.append("redlamp_contains(p.\(column), \(bind(text)))")
                }
                let owners = synonyms.owners(containing: text)
                if !owners.isEmpty {
                    alternatives.append(keywords(within: owners))
                }
                return "(" + alternatives.joined(separator: " OR ") + ")"
            case let .filter(filter):
                var alternatives: [String] = []
                for value in filter.values {
                    alternatives.append(predicate(filter.field, filter.comparison, value))
                }
                let any = alternatives.count == 1 ? alternatives[0] : "(" + alternatives.joined(separator: " OR ") + ")"
                return filter.comparison == .notEqual ? "NOT (\(any))" : any
            case let .not(inner):
                return "NOT (\(predicate(inner)))"
            case let .and(queries), let .or(queries):
                var parts: [String] = []
                for query in queries {
                    parts.append(predicate(query))
                }
                let isAnd = if case .and = query {
                    true
                } else {
                    false
                }
                return "(" + parts.joined(separator: isAnd ? " AND " : " OR ") + ")"
            }
        }

        private mutating func predicate(
            _ field: LibraryQuery.Field, _ comparison: LibraryQuery.Comparison, _ value: LibraryQuery.Value,
        ) -> String {
            if let range = QueryRanges.range(field, comparison, value, today: today) {
                let expression = switch field {
                case .rating: ColumnEncoding.ratingSQL
                case .iso: ColumnEncoding.isoSQL
                case .aperture: ColumnEncoding.apertureSQL
                case .focal: ColumnEncoding.focalSQL
                case .shutter: ColumnEncoding.shutterSQL
                case .megapixels: ColumnEncoding.megapixelsSQL
                case .aspect: ColumnEncoding.aspectSQL
                default: ColumnEncoding.capturedSQL
                }
                return range.isEmpty ? "0" : "(\(expression) BETWEEN \(range.lowerBound) AND \(range.upperBound - 1))"
            }
            switch (field, value) {
            case let (.flag, .flag(flag)):
                return "(\(ColumnEncoding.flagSQL) = \(PhotoRecord.code(for: flag)))"
            case let (.label, .label(label)):
                let colour = "(\(ColumnEncoding.labelSQL) = \(PhotoRecord.code(for: label)))"
                return label == nil ? "(\(colour) AND NOT \(ColumnEncoding.presentSQL("p.custom_label")))" : colour
            case let (.label, .text(name)):
                let custom = "redlamp_named(p.custom_label, \(bind(name)))"
                guard let colour = XMPLabelNames.label(named: name) else { return custom }
                return "((\(ColumnEncoding.labelSQL) = \(PhotoRecord.code(for: colour))) OR \(custom))"
            case let (.creator, .text(text)), let (.copyright, .text(text)):
                return "redlamp_contains(p.\(field.rawValue), \(bind(text)))"
            case let (.sublocation, .text(text)), let (.city, .text(text)), let (.state, .text(text)),
                 let (.country, .text(text)), let (.countryCode, .text(text)):
                guard let part = PlaceCodes.Part(field) else { return "0" }
                return "redlamp_contains(p.\(part.column), \(bind(text)))"
            case let (.marked, .bool(yes)):
                return yes ? "(p.marked != 0)" : "(p.marked = 0)"
            case let (.edited, .bool(yes)):
                return yes ? "(p.edited != 0)" : "(p.edited = 0)"
            case let (.missing, .bool(yes)), let (.offline, .bool(yes)), let (.unreadable, .bool(yes)):
                let state: PhotoRecord.State = field == .missing ? .missing : field == .offline ? .offline : .unreadable
                return "((\(ColumnEncoding.stateSQL) & \(state.rawValue)) \(yes ? "!=" : "=") 0)"
            case let (.keyword, .text(text)):
                var tests = ["redlamp_keyword(k.path, \(bind(text)))"]
                for owner in synonyms.owners(of: text) {
                    tests.append("redlamp_within(k.path, \(bind(owner)))")
                }
                return "p.id IN (SELECT pk.photo FROM photo_keywords pk JOIN keywords k ON k.id = pk.keyword"
                    + " WHERE " + tests.joined(separator: " OR ") + ")"
            case let (.camera, .text(text)):
                return Self.named("camera", "cameras", bind(text))
            case let (.lens, .text(text)):
                return Self.named("lens", "lenses", bind(text))
            case let (.folder, .text(text)):
                return "p.folder IN (SELECT id FROM folders WHERE redlamp_contains(path, \(bind(text))))"
            case let (.name, .text(text)):
                return textMatch(QueryText.match(text, in: .name))
            case let (.title, .text(text)):
                return textMatch(QueryText.match(text, in: .title))
            case let (.caption, .text(text)):
                return textMatch(QueryText.match(text, in: .caption))
            case let (.ext, .kind(kind)):
                return "(\(ColumnEncoding.kindSQL) = \(kind.rawValue))"
            case let (.orientation, .orientation(orientation)):
                return "(\(ColumnEncoding.orientationSQL) = \(orientation?.code ?? 0))"
            case let (.ext, .text(ext)):
                return textMatch(QueryText.match("." + ext, in: .name))
            case let (.collection, .text(text)):
                return "p.id IN (SELECT cp.photo FROM collection_photos cp JOIN collections c ON c.id = cp.collection"
                    + " WHERE c.path IS NOT NULL AND redlamp_keyword(c.path, \(bind(text))))"
            case let (.trait, .trait(trait)):
                return predicate(trait.query)
            case let (.has, .detail(detail)):
                return switch detail {
                case .gps: ColumnEncoding.locationSQL
                case .keywords: ColumnEncoding.keywordsSQL
                case .caption: ColumnEncoding.captionSQL
                case .title: ColumnEncoding.titleSQL
                case .xmp: ColumnEncoding.xmpSQL
                case .creator: ColumnEncoding.presentSQL("p.creator")
                case .copyright: ColumnEncoding.presentSQL("p.copyright")
                case .location:
                    "(" + PlaceCodes.Part.allCases.map { ColumnEncoding.presentSQL("p." + $0.column) }
                        .joined(separator: " OR ") + ")"
                }
            default:
                return "0"
            }
        }

        /// The photos with a keyword at one of `owners` or inside it.
        private mutating func keywords(within owners: [String]) -> String {
            var tests: [String] = []
            for owner in owners {
                tests.append("redlamp_within(k.path, \(bind(owner)))")
            }
            return "p.id IN (SELECT pk.photo FROM photo_keywords pk JOIN keywords k ON k.id = pk.keyword WHERE "
                + tests.joined(separator: " OR ") + ")"
        }

        private mutating func textMatch(_ match: String) -> String {
            "p.id IN (SELECT rowid FROM photo_text WHERE photo_text MATCH \(bind(match)))"
        }

        private static func named(_ column: String, _ table: String, _ parameter: String) -> String {
            "(p.\(column) IS NOT NULL AND p.\(column) IN (SELECT id FROM \(table) WHERE redlamp_contains(name, \(parameter))))"
        }

        private mutating func bind(_ text: String) -> String {
            bindings.append(.text(text))
            return "?"
        }
    }
}

/// The encoded values a filter on an ordered field accepts, which the column engine and the SQL
/// both test: from the lower bound up to, not including, the upper.
enum QueryRanges {
    /// Nil for a field that isn't ordered.
    static func range(
        _ field: LibraryQuery.Field, _ comparison: LibraryQuery.Comparison, _ value: LibraryQuery.Value, today: Int,
    ) -> Range<Int64>? {
        let encode: (Double) -> Int64
        let all: ClosedRange<Int64>
        switch field {
        case .rating:
            encode = { Int64(max(0, min(7, $0.rounded(.down)))) }
            all = 0 ... 7
        case .iso:
            encode = { Int64(ColumnEncoding.iso($0)) }
            all = 1 ... Int64(UInt16.max)
        case .aperture:
            encode = { Int64(ColumnEncoding.aperture($0)) }
            all = 1 ... Int64(UInt16.max)
        case .focal:
            encode = { Int64(ColumnEncoding.focal($0)) }
            all = 1 ... Int64(UInt16.max)
        case .shutter:
            encode = { Int64(ColumnEncoding.shutter($0)) }
            all = 1 ... Int64(UInt32.max)
        case .megapixels:
            encode = { Int64(ColumnEncoding.scaled($0, by: 10, limit: Double(UInt16.max))) }
            all = 1 ... Int64(UInt16.max)
        case .aspect:
            encode = { Int64(ColumnEncoding.scaled($0, by: 100, limit: Double(UInt16.max))) }
            all = 1 ... Int64(UInt16.max)
        case .date:
            return dates(comparison, value, today: today)
        default:
            return nil
        }
        let lowest = all.lowerBound
        let end = all.upperBound + 1
        func clamped(_ lower: Int64, _ upper: Int64) -> Range<Int64> {
            let lower = max(lower, lowest)
            return lower ..< max(lower, min(upper, end))
        }
        switch (comparison, value) {
        case let (.equal, .number(number)), let (.notEqual, .number(number)):
            return clamped(encode(number), encode(number) + 1)
        case let (_, .numberRange(lower, upper)):
            return clamped(lower.map(encode) ?? lowest, upper.map { encode($0) + 1 } ?? end)
        case let (.less, .number(number)): return clamped(lowest, encode(number))
        case let (.lessOrEqual, .number(number)): return clamped(lowest, encode(number) + 1)
        case let (.greater, .number(number)): return clamped(encode(number) + 1, end)
        case let (.greaterOrEqual, .number(number)): return clamped(encode(number), end)
        default: return 0 ..< 0
        }
    }

    /// Capture times in milliseconds; never the none of `ColumnEncoding.captured`, nor `Int64.max`,
    /// which no capture time reaches.
    private static func dates(
        _ comparison: LibraryQuery.Comparison, _ value: LibraryQuery.Value, today: Int,
    ) -> Range<Int64> {
        let lowest = Int64.min + 1
        let end = Int64.max
        switch (comparison, value) {
        case let (.equal, .date(date)), let (.notEqual, .date(date)):
            return date.interval(today: today)
        case let (_, .dateRange(lower, upper)):
            let start = lower?.interval(today: today).lowerBound ?? lowest
            return start ..< max(start, upper?.interval(today: today).upperBound ?? end)
        case let (.less, .date(date)): return lowest ..< date.interval(today: today).lowerBound
        case let (.lessOrEqual, .date(date)): return lowest ..< date.interval(today: today).upperBound
        case let (.greater, .date(date)): return date.interval(today: today).upperBound ..< end
        case let (.greaterOrEqual, .date(date)): return date.interval(today: today).lowerBound ..< end
        default: return 0 ..< 0
        }
    }
}

/// Set when a query is cancelled, for work that runs where `Task.isCancelled` can't see it: SQL on a
/// reader's queue.
final class QueryCancellation: Sendable {
    private let state = Atomic(false)

    var isCancelled: Bool {
        state.load(ordering: .acquiring)
    }

    func cancel() {
        state.store(true, ordering: .releasing)
    }
}

extension IndexQueries {
    /// Runs `sql`, calling `body` with each photo ID it returns. Throws `CancellationError` once
    /// `cancellation` is set, even partway through a statement.
    func run(_ sql: QuerySQL, cancellation: QueryCancellation, _ body: (Int64) throws -> Void) throws {
        try QueryFunctions.register(on: database)
        let statement = try database.prepare(sql.sql)
        for (offset, binding) in sql.bindings.enumerated() {
            switch binding {
            case let .integer(value): try statement.bind(value, at: Int32(offset + 1))
            case let .text(value): try statement.bind(value, at: Int32(offset + 1))
            }
        }
        sqlite3_progress_handler(
            database.handle,
            4096,
            cancelOnProgress,
            Unmanaged.passUnretained(cancellation)
                .toOpaque(),
        )
        defer { sqlite3_progress_handler(database.handle, 0, nil, nil) }
        do {
            try statement.forEachRow { row in
                guard !cancellation.isCancelled else { throw CancellationError() }
                try body(row.int64(at: 0))
            }
        } catch let error as SQLiteError where error.code == SQLITE_INTERRUPT {
            throw CancellationError()
        }
    }
}

/// The query language's text matching and name order, as SQL functions and a collation:
/// `redlamp_contains` a substring, `redlamp_named` a name, `redlamp_keyword` a keyword's or a
/// collection's path, `redlamp_within` a keyword inside another, and `redlamp_text` text as the
/// text index holds it (`QueryText.indexed`).
enum QueryFunctions {
    /// Registers them on `database`'s connection, once.
    static func register(on database: SQLiteDatabase) throws {
        let probe = "SELECT redlamp_contains('', ''), redlamp_named('', ''), redlamp_keyword('', ''),"
            + " redlamp_within('', ''), redlamp_text(''), '' COLLATE redlamp_finder"
        if (try? database.cached(probe)) != nil {
            return
        }
        let flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC
        let results = [
            sqlite3_create_function_v2(database.handle, "redlamp_text", 1, flags, nil, textFunction, nil, nil, nil),
            sqlite3_create_function_v2(
                database.handle,
                "redlamp_contains",
                2,
                flags,
                nil,
                containsFunction,
                nil,
                nil,
                nil,
            ),
            sqlite3_create_function_v2(database.handle, "redlamp_named", 2, flags, nil, namedFunction, nil, nil, nil),
            sqlite3_create_function_v2(
                database.handle,
                "redlamp_keyword",
                2,
                flags,
                nil,
                keywordFunction,
                nil,
                nil,
                nil,
            ),
            sqlite3_create_function_v2(database.handle, "redlamp_within", 2, flags, nil, withinFunction, nil, nil, nil),
            sqlite3_create_collation_v2(database.handle, "redlamp_finder", SQLITE_UTF8, nil, finderCollation, nil),
        ]
        if let failed = results.first(where: { $0 != SQLITE_OK }) {
            throw SQLiteError(code: failed, message: "couldn't register the query language's functions", sql: nil)
        }
    }
}

private func string(of value: OpaquePointer?) -> String? {
    sqlite3_value_text(value).map { String(cString: $0) }
}

private func containsFunction(_ context: OpaquePointer?, _: Int32, _ values: UnsafeMutablePointer<OpaquePointer?>?) {
    guard let values, let text = string(of: values[0]), let part = string(of: values[1]) else {
        return sqlite3_result_int(context, 0)
    }
    sqlite3_result_int(context, QueryText.contains(text, part) ? 1 : 0)
}

private func namedFunction(_ context: OpaquePointer?, _: Int32, _ values: UnsafeMutablePointer<OpaquePointer?>?) {
    guard let values, let text = string(of: values[0]), let name = string(of: values[1]) else {
        return sqlite3_result_int(context, 0)
    }
    sqlite3_result_int(context, QueryText.isSame(text, name) ? 1 : 0)
}

private func keywordFunction(_ context: OpaquePointer?, _: Int32, _ values: UnsafeMutablePointer<OpaquePointer?>?) {
    guard let values, let path = string(of: values[0]), let value = string(of: values[1]) else {
        return sqlite3_result_int(context, 0)
    }
    sqlite3_result_int(context, KeywordQuery.matches(path: path, value: value) ? 1 : 0)
}

/// Text other than all ASCII as the text index holds it; anything else as it is.
private func textFunction(_ context: OpaquePointer?, _: Int32, _ values: UnsafeMutablePointer<OpaquePointer?>?) {
    guard let value = values?[0] else { return sqlite3_result_null(context) }
    guard sqlite3_value_type(value) == SQLITE_TEXT, let text = sqlite3_value_text(value) else {
        return sqlite3_result_value(context, value)
    }
    let bytes = UnsafeBufferPointer(start: text, count: Int(sqlite3_value_bytes(value)))
    guard bytes.contains(where: { $0 >= 0x80 }) else { return sqlite3_result_value(context, value) }
    let indexed = QueryText.indexed(String(decoding: bytes, as: UTF8.self))
    sqlite3_result_text64(
        context, indexed, sqlite3_uint64(indexed.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self),
        UInt8(SQLITE_UTF8),
    )
}

private func withinFunction(_ context: OpaquePointer?, _: Int32, _ values: UnsafeMutablePointer<OpaquePointer?>?) {
    guard let values, let path = string(of: values[0]), let owner = string(of: values[1]) else {
        return sqlite3_result_int(context, 0)
    }
    sqlite3_result_int(context, KeywordQuery.isWithin(path: path, owner: owner) ? 1 : 0)
}

private func finderCollation(
    _: UnsafeMutableRawPointer?, _ leftCount: Int32, _ left: UnsafeRawPointer?, _ rightCount: Int32,
    _ right: UnsafeRawPointer?,
) -> Int32 {
    func string(_ bytes: UnsafeRawPointer?, _ count: Int32) -> String {
        bytes.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(count)), as: UTF8.self) } ?? ""
    }
    return Int32(FinderOrder.compare(string(left, leftCount), string(right, rightCount)))
}

private func cancelOnProgress(_ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 0 }
    return Unmanaged<QueryCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
}
