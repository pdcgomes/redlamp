import Foundation
import SQLite3

/// A compiled statement of a `SQLiteDatabase`, used on its connection's thread and only while the
/// connection is open.
///
/// Parameters count from 1 and columns from 0, as in SQLite. Text and blobs are copied when they
/// are bound (`SQLITE_TRANSIENT`), so the values may go as soon as the call returns. SQLite here
/// never resets a finished statement by itself (`SQLITE_OMIT_AUTORESET`): `run`, `forEachRow`,
/// `map` and `first` reset it when they're done; a caller stepping by hand calls `reset`.
public final class SQLiteStatement {
    let handle: OpaquePointer

    init(_ handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_finalize(handle)
    }

    public var sql: String {
        sqlite3_sql(handle).map { String(cString: $0) } ?? ""
    }

    /// Stepped into its rows and not yet finished or reset.
    var isBusy: Bool {
        sqlite3_stmt_busy(handle) != 0
    }

    // MARK: - Binding

    public func bind(_ value: Int64?, at index: Int32) throws {
        guard let value else { return try bindNull(at: index) }
        try check(sqlite3_bind_int64(handle, index, value))
    }

    public func bind(_ value: Int?, at index: Int32) throws {
        try bind(value.map { Int64($0) }, at: index)
    }

    public func bind(_ value: Double?, at index: Int32) throws {
        guard let value else { return try bindNull(at: index) }
        try check(sqlite3_bind_double(handle, index, value))
    }

    public func bind(_ value: Bool, at index: Int32) throws {
        try check(sqlite3_bind_int64(handle, index, value ? 1 : 0))
    }

    public func bind(_ value: String?, at index: Int32) throws {
        guard let value else { return try bindNull(at: index) }
        try check(sqlite3_bind_text64(
            handle, index, value, sqlite3_uint64(value.utf8.count), Self.transient, UInt8(SQLITE_UTF8),
        ))
    }

    public func bind(_ value: Data?, at index: Int32) throws {
        guard let value else { return try bindNull(at: index) }
        let result = value.withUnsafeBytes { bytes -> Int32 in
            // A null pointer binds NULL rather than an empty blob.
            guard let base = bytes.baseAddress, !bytes.isEmpty else { return sqlite3_bind_zeroblob(handle, index, 0) }
            return sqlite3_bind_blob64(handle, index, base, sqlite3_uint64(bytes.count), Self.transient)
        }
        try check(result)
    }

    public func bindNull(at index: Int32) throws {
        try check(sqlite3_bind_null(handle, index))
    }

    /// Binds a copy of `column` of the row `statement` is on, whatever its type.
    public func bind(_ column: Int32, of statement: SQLiteStatement, at index: Int32) throws {
        try check(sqlite3_bind_value(handle, index, sqlite3_column_value(statement.handle, column)))
    }

    public func bind(_ value: Int64?, named name: String) throws {
        try bind(value, at: index(of: name))
    }

    public func bind(_ value: Int?, named name: String) throws {
        try bind(value, at: index(of: name))
    }

    public func bind(_ value: Double?, named name: String) throws {
        try bind(value, at: index(of: name))
    }

    public func bind(_ value: Bool, named name: String) throws {
        try bind(value, at: index(of: name))
    }

    public func bind(_ value: String?, named name: String) throws {
        try bind(value, at: index(of: name))
    }

    public func bind(_ value: Data?, named name: String) throws {
        try bind(value, at: index(of: name))
    }

    public func bindNull(named name: String) throws {
        try bindNull(at: index(of: name))
    }

    /// The index of the parameter `name`, written with its prefix: `:name`, `@name` or `$name`.
    public func index(of name: String) throws -> Int32 {
        let index = sqlite3_bind_parameter_index(handle, name)
        guard index > 0 else { throw SQLiteError(code: SQLITE_RANGE, message: "no parameter named \(name)", sql: sql) }
        return index
    }

    /// Sets every parameter back to NULL.
    public func clearBindings() {
        sqlite3_clear_bindings(handle)
    }

    // MARK: - Stepping

    /// Steps to the next row: true when there is one, false when the statement has finished.
    @discardableResult
    public func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: true
        case SQLITE_DONE: false
        default: throw error
        }
    }

    /// Back to before the first row, keeping the bindings.
    public func reset() {
        sqlite3_reset(handle)
    }

    /// Steps to the end (a statement that returns no rows, or whose rows don't matter) and resets.
    public func run() throws {
        defer { reset() }
        while try step() {}
    }

    /// Calls `body` with the statement on each row in turn, then resets.
    public func forEachRow(_ body: (SQLiteStatement) throws -> Void) throws {
        defer { reset() }
        while try step() {
            try body(self)
        }
    }

    /// Each row, through `transform`.
    public func map<T>(_ transform: (SQLiteStatement) throws -> T) throws -> [T] {
        var rows: [T] = []
        try forEachRow { try rows.append(transform($0)) }
        return rows
    }

    /// The first row through `transform`, or nil when there's none.
    public func first<T>(_ transform: (SQLiteStatement) throws -> T) throws -> T? {
        defer { reset() }
        return try step() ? transform(self) : nil
    }

    // MARK: - Columns

    public var columnCount: Int32 {
        sqlite3_column_count(handle)
    }

    public func columnName(at column: Int32) -> String {
        sqlite3_column_name(handle, column).map { String(cString: $0) } ?? ""
    }

    public func isNull(at column: Int32) -> Bool {
        sqlite3_column_type(handle, column) == SQLITE_NULL
    }

    /// The column as an integer: 0 for NULL.
    public func int64(at column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    public func int(at column: Int32) -> Int {
        Int(sqlite3_column_int64(handle, column))
    }

    /// The column as a number: 0 for NULL.
    public func double(at column: Int32) -> Double {
        sqlite3_column_double(handle, column)
    }

    public func bool(at column: Int32) -> Bool {
        sqlite3_column_int64(handle, column) != 0
    }

    public func optionalInt64(at column: Int32) -> Int64? {
        isNull(at: column) ? nil : int64(at: column)
    }

    public func optionalInt(at column: Int32) -> Int? {
        isNull(at: column) ? nil : int(at: column)
    }

    public func optionalDouble(at column: Int32) -> Double? {
        isNull(at: column) ? nil : double(at: column)
    }

    public func string(at column: Int32) -> String? {
        guard let text = sqlite3_column_text(handle, column) else { return nil }
        let count = Int(sqlite3_column_bytes(handle, column))
        return String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)
    }

    public func data(at column: Int32) -> Data? {
        guard !isNull(at: column) else { return nil }
        guard let bytes = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, column)))
    }

    // MARK: - Errors

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw error }
    }

    private var error: SQLiteError {
        let database = sqlite3_db_handle(handle)
        return SQLiteError(
            code: sqlite3_extended_errcode(database), message: String(cString: sqlite3_errmsg(database)), sql: sql,
        )
    }
}
