import Foundation
import SQLite3
import Testing
@testable import RedlampLibrary

struct SQLiteDatabaseTests {
    private func memory() throws -> SQLiteDatabase {
        try SQLiteDatabase(path: ":memory:")
    }

    @Test func `values bound by index and by name read back as they went in`() throws {
        let database = try memory()
        try database.execute("CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB, n)")
        let insert = try database.prepare("INSERT INTO t VALUES (?1, ?2, :text, @blob, $none)")
        try insert.bind(Int64.max, at: 1)
        try insert.bind(2.5, at: 2)
        try insert.bind("Lisbon, Portugal 🇵🇹", named: ":text")
        try insert.bind(Data([0, 1, 2, 255]), named: "@blob")
        try insert.bindNull(named: "$none")
        try insert.run()
        try insert.bind(-7, at: 1)
        try insert.bind(nil as Double?, at: 2)
        try insert.bind("a\u{0}b", named: ":text")
        try insert.bind(Data(), named: "@blob")
        try insert.bind(true, named: "$none")
        try insert.run()

        let select = try database.prepare("SELECT i, r, s, b, n FROM t ORDER BY rowid")
        #expect(try select.step())
        #expect(select.int64(at: 0) == Int64.max)
        #expect(select.double(at: 1) == 2.5)
        #expect(select.string(at: 2) == "Lisbon, Portugal 🇵🇹")
        #expect(select.data(at: 3) == Data([0, 1, 2, 255]))
        #expect(select.isNull(at: 4) && select.optionalInt(at: 4) == nil)
        #expect(try select.step())
        #expect(select.int(at: 0) == -7)
        #expect(select.optionalDouble(at: 1) == nil)
        #expect(select.string(at: 2) == "a\u{0}b", "text is bound by its length, not up to a NUL")
        #expect(select.data(at: 3) == Data(), "an empty blob stays a blob, not NULL")
        #expect(select.bool(at: 4))
        #expect(try !select.step())
        select.reset()
        #expect(select.columnCount == 5 && select.columnName(at: 2) == "s")
    }

    @Test func `a failing call throws SQLite's result code and message`() throws {
        let database = try memory()
        try database.execute("CREATE TABLE t (name TEXT UNIQUE)")
        try database.execute("INSERT INTO t VALUES ('a')")

        let duplicate = try #require(throws: SQLiteError.self) { try database.execute("INSERT INTO t VALUES ('a')") }
        #expect(duplicate.code == SQLITE_CONSTRAINT)
        #expect(duplicate.extendedCode == SQLITE_CONSTRAINT | (8 << 8), "SQLITE_CONSTRAINT_UNIQUE")
        #expect(duplicate.message.contains("UNIQUE constraint failed: t.name"))

        let unknown = try #require(throws: SQLiteError.self) { try database.prepare("SELECT nope FROM t") }
        #expect(unknown.message.contains("nope") && unknown.sql == "SELECT nope FROM t")

        let statement = try database.prepare("SELECT * FROM t WHERE name = :name")
        let unnamed = try #require(throws: SQLiteError.self) { try statement.bind("a", named: ":other") }
        #expect(unnamed.code == SQLITE_RANGE)
        #expect(throws: SQLiteError.self) { try statement.bind("a", at: 2) }

        let missing = try #require(throws: SQLiteError.self) {
            try SQLiteDatabase(path: "/nonexistent-\(UUID().uuidString)/x.sqlite", flags: .readOnly)
        }
        #expect(missing.code == SQLITE_CANTOPEN)
    }

    @Test func `a transaction that throws leaves nothing, and a nested one rolls back only its own changes`() throws {
        struct Failure: Error {}
        let database = try memory()
        try database.execute("CREATE TABLE t (n INTEGER)")
        #expect(throws: Failure.self) {
            try database.transaction {
                try database.execute("INSERT INTO t VALUES (1)")
                throw Failure()
            }
        }
        #expect(!database.isInTransaction)

        try database.transaction(.immediate) {
            try database.execute("INSERT INTO t VALUES (2)")
            #expect(throws: Failure.self) {
                try database.transaction {
                    try database.execute("INSERT INTO t VALUES (3)")
                    throw Failure()
                }
            }
            try database.transaction { try database.execute("INSERT INTO t VALUES (4)") }
        }
        #expect(try database.prepare("SELECT n FROM t ORDER BY n").map { $0.int(at: 0) } == [2, 4])
    }

    @Test func `a cached statement compiles once, and one still being stepped through isn't handed out again`() throws {
        let database = try memory()
        try database.execute("CREATE TABLE t (n INTEGER); INSERT INTO t VALUES (1), (2), (3)")
        let sql = "SELECT n FROM t WHERE n >= ? ORDER BY n"
        let first = try database.cached(sql)
        try first.bind(2, at: 1)
        #expect(try first.step())

        let nested = try database.cached(sql)
        #expect(nested !== first, "the first is still on its first row")
        try nested.bind(1, at: 1)
        #expect(try nested.map { $0.int(at: 0) } == [1, 2, 3])
        #expect(first.int(at: 0) == 2)

        first.reset()
        let again = try database.cached(sql)
        #expect(again === first)
        #expect(try again.map { $0.int(at: 0) }.isEmpty, "handed out without the last caller's bindings")
    }

    @Test func `the last row ID and the rows changed are the connection's`() throws {
        let database = try memory()
        try database.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER)")
        try database.execute("INSERT INTO t (n) VALUES (1), (1), (2)")
        #expect(database.lastInsertRowID == 3)
        #expect(database.changes == 3)
        try database.execute("UPDATE t SET n = 5 WHERE n = 1")
        #expect(database.changes == 2)
        #expect(database.totalChanges == 5)
        try database.setUserVersion(7)
        #expect(try database.userVersion == 7)
    }
}
