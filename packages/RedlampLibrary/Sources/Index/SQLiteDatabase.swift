import Foundation
import SQLite3

/// A connection to a SQLite database: macOS's and iOS's own SQLite, never a package.
///
/// SQLite is built multi-threaded on Apple's platforms: a connection, and every statement it
/// prepares, may move between threads but is used from one thread at a time. Neither is
/// `Sendable`; `LibraryIndex` keeps each of its connections on a serial queue of its own.
public final class SQLiteDatabase {
    /// How the file is opened (`sqlite3_open_v2`'s flags).
    public struct OpenFlags: OptionSet, Sendable {
        public let rawValue: Int32

        public init(rawValue: Int32) {
            self.rawValue = rawValue
        }

        public static let readOnly = OpenFlags(rawValue: SQLITE_OPEN_READONLY)
        public static let readWrite = OpenFlags(rawValue: SQLITE_OPEN_READWRITE)
        /// Creates the file when there's none (with `readWrite`).
        public static let create = OpenFlags(rawValue: SQLITE_OPEN_CREATE)
        /// Refuses a path that is a symbolic link.
        public static let noFollow = OpenFlags(rawValue: SQLITE_OPEN_NOFOLLOW)
    }

    public enum TransactionKind: String, Sendable {
        /// Takes the write lock at the first write.
        case deferred = "DEFERRED"
        /// Takes the write lock at once, so a write never fails halfway for want of it.
        case immediate = "IMMEDIATE"
        case exclusive = "EXCLUSIVE"
    }

    public let path: String
    let handle: OpaquePointer
    private var statements: [String: SQLiteStatement] = [:]
    private var savepoints = 0

    public init(path: String, flags: OpenFlags = [.readWrite, .create]) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(path, &handle, flags.rawValue | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_EXRESCODE, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(result))
            sqlite3_close_v2(handle)
            throw SQLiteError(code: result, message: message, sql: nil)
        }
        self.path = path
        self.handle = handle
    }

    deinit {
        statements.removeAll()
        sqlite3_close_v2(handle)
    }

    // MARK: - Running SQL

    /// Runs `sql`, one statement or several separated by semicolons, ignoring any rows.
    public func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) != SQLITE_OK else { return }
        let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
        sqlite3_free(message)
        throw SQLiteError(code: sqlite3_extended_errcode(handle), message: text, sql: sql)
    }

    /// Compiles `sql`, one statement.
    public func prepare(_ sql: String) throws -> SQLiteStatement {
        try prepare(sql, flags: 0)
    }

    /// The statement for `sql`, compiled on first use and kept, so a hot query compiles once per
    /// connection. Each call hands it out reset, with no bindings; while one caller is still
    /// stepping through its rows, another asking for the same SQL gets a statement of its own.
    public func cached(_ sql: String) throws -> SQLiteStatement {
        if let statement = statements[sql] {
            guard !statement.isBusy else { return try prepare(sql) }
            statement.reset()
            statement.clearBindings()
            return statement
        }
        let statement = try prepare(sql, flags: UInt32(SQLITE_PREPARE_PERSISTENT))
        statements[sql] = statement
        return statement
    }

    private func prepare(_ sql: String, flags: UInt32) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v3(handle, sql, -1, flags, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(
                code: sqlite3_extended_errcode(handle), message: String(cString: sqlite3_errmsg(handle)), sql: sql,
            )
        }
        guard let statement else {
            throw SQLiteError(code: SQLITE_MISUSE, message: "no statement to prepare", sql: sql)
        }
        return SQLiteStatement(statement)
    }

    // MARK: - Transactions

    /// Whether a transaction is open.
    public var isInTransaction: Bool {
        sqlite3_get_autocommit(handle) == 0
    }

    /// Runs `body` in a transaction, committed when it returns and rolled back when it throws.
    /// Inside another transaction it runs in a savepoint instead, so only its own changes roll back.
    public func transaction<T>(_ kind: TransactionKind = .deferred, _ body: () throws -> T) throws -> T {
        if isInTransaction {
            savepoints += 1
            defer { savepoints -= 1 }
            let name = "nested\(savepoints)"
            try execute("SAVEPOINT \(name)")
            do {
                let result = try body()
                try execute("RELEASE \(name)")
                return result
            } catch {
                try? execute("ROLLBACK TO \(name)")
                try? execute("RELEASE \(name)")
                throw error
            }
        }
        try execute("BEGIN \(kind.rawValue)")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            // Some errors (a full disk, an I/O error) have rolled the transaction back already.
            if isInTransaction {
                try? execute("ROLLBACK")
            }
            throw error
        }
    }

    // MARK: - State

    /// The row ID of the last row inserted on this connection.
    public var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    /// Rows the last `INSERT`, `UPDATE` or `DELETE` changed, not counting triggers.
    public var changes: Int {
        Int(sqlite3_changes64(handle))
    }

    /// Rows changed since the connection opened, triggers included.
    public var totalChanges: Int {
        Int(sqlite3_total_changes64(handle))
    }

    /// `PRAGMA user_version`: the schema's version, 0 in a new database.
    public var userVersion: Int {
        get throws {
            try cached("PRAGMA user_version").first { $0.int(at: 0) } ?? 0
        }
    }

    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }
}

/// A SQLite call that failed: its result code and SQLite's message.
public struct SQLiteError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The extended result code (`SQLITE_CONSTRAINT_UNIQUE`, `SQLITE_IOERR_SHORT_READ`...).
    public let extendedCode: Int32
    public let message: String
    /// The statement that failed, when there was one.
    public let sql: String?

    public init(code: Int32, message: String, sql: String?) {
        extendedCode = code
        self.message = message
        self.sql = sql
    }

    /// The primary result code (`SQLITE_CONSTRAINT`, `SQLITE_IOERR`...).
    public var code: Int32 {
        extendedCode & 0xFF
    }

    /// The file isn't a database, or the database is damaged.
    public var isCorruption: Bool {
        code == SQLITE_CORRUPT || code == SQLITE_NOTADB
    }

    public var description: String {
        let statement = sql.map { " in \($0)" } ?? ""
        return "SQLite error \(extendedCode): \(message)\(statement)"
    }
}
