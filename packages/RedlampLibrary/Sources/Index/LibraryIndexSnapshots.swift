import Foundation
import SQLite3

public extension LibraryIndex {
    /// What `openOrRestore` found.
    enum OpenOutcome: Sendable, Hashable {
        /// The index opened and passed its check.
        case opened
        /// The index was damaged and this snapshot replaced it: what changed on the disks since
        /// it was taken needs reconciling (LIB-08).
        case restored(from: URL)
        /// The index was damaged and no snapshot was good: a new, empty index replaced it, and the
        /// library needs indexing again.
        case rebuilt
    }

    /// Opens the index at `url` or, if it's damaged (it fails `PRAGMA quick_check`, or opening it
    /// finds no database or a corrupt one), moves it and its write-ahead log aside to
    /// `<name>.damaged` and restores the newest snapshot in `snapshots` that passes the check,
    /// or else starts a new, empty index. `check: false` skips the check on an index that opens,
    /// since it reads the whole file.
    static func openOrRestore(
        at url: URL, snapshots: URL, readers: Int = 4, check: Bool = true,
    ) async throws -> (index: LibraryIndex, outcome: OpenOutcome) {
        try await offCaller {
            if let index = try openIfSound(at: url, readers: readers, check: check, migrations: migrations) {
                return (index, .opened)
            }
            try moveAside(url)
            for snapshot in snapshotFiles(in: snapshots, for: url) {
                if let index = try? restore(snapshot, to: url, readers: readers) {
                    return (index, .restored(from: snapshot))
                }
            }
            return try (LibraryIndex(url: url, readers: readers, migrations: migrations), .rebuilt)
        }
    }

    /// Copies the index into `directory` with `VACUUM INTO`, keeping the newest `keeping` copies
    /// there, and returns the copy. It reads on a read connection, so writes go on meanwhile.
    @discardableResult
    func snapshot(to directory: URL, keeping: Int = 3) async throws -> URL {
        let url = url
        return try await onReader { database in
            try Self.snapshot(of: database, at: url, to: directory, keeping: keeping)
        }
    }

    /// Whether `PRAGMA quick_check` finds the index sound: false for a damaged index; other
    /// failures (a closed index, a disk that can't be read) throw.
    func quickCheck() async throws -> Bool {
        try await onReader(Self.passesQuickCheck)
    }
}

extension LibraryIndex {
    /// The snapshots of the index at `url` in `directory`, newest first.
    static func snapshotFiles(in directory: URL, for url: URL) -> [URL] {
        let (prefix, suffix) = snapshotAffixes(for: url)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }.sorted(by: >)
            .map { directory.appending(path: $0) }
    }

    static func passesQuickCheck(_ database: SQLiteDatabase) throws -> Bool {
        do {
            return try database.prepare("PRAGMA quick_check").map { $0.string(at: 0) } == ["ok"]
        } catch let error as SQLiteError where error.isCorruption {
            return false
        }
    }

    /// The index at `url` if it opens and passes its check; nil if it's damaged.
    private static func openIfSound(
        at url: URL, readers: Int, check: Bool, migrations: [Migration],
    ) throws -> LibraryIndex? {
        let index: LibraryIndex
        do {
            index = try LibraryIndex(url: url, readers: readers, migrations: migrations)
        } catch let error as SQLiteError where error.isCorruption {
            return nil
        }
        if try !check || index.onWriterAndWait(passesQuickCheck) {
            return index
        }
        index.closeAndWait()
        return nil
    }

    /// Moves a damaged index and its write-ahead log to `<name>.damaged`, replacing the last
    /// damaged index kept there.
    private static func moveAside(_ url: URL) throws {
        let damaged = url.appendingPathExtension("damaged")
        removeDatabase(at: damaged)
        for suffix in databaseSuffixes {
            let file = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            try FileManager.default.moveItem(at: file, to: URL(fileURLWithPath: damaged.path + suffix))
        }
    }

    /// Copies `snapshot` to `url` if the copy passes the check, and opens it.
    private static func restore(_ snapshot: URL, to url: URL, readers: Int) throws -> LibraryIndex {
        let staging = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).restoring")
        removeDatabase(at: staging)
        defer { removeDatabase(at: staging) }
        try FileManager.default.copyItem(at: snapshot, to: staging)
        let sound: Bool
        do {
            sound = try passesQuickCheck(SQLiteDatabase(path: staging.path, flags: .readOnly))
        } catch let error as SQLiteError where error.isCorruption {
            sound = false
        }
        guard sound else { throw SQLiteError(code: SQLITE_CORRUPT, message: "the snapshot is damaged", sql: nil) }
        removeDatabase(at: url)
        try FileManager.default.moveItem(at: staging, to: url)
        do {
            return try LibraryIndex(url: url, readers: readers, migrations: migrations)
        } catch {
            removeDatabase(at: url)
            throw error
        }
    }

    private static func snapshot(of database: SQLiteDatabase, at url: URL, to directory: URL, keeping: Int) throws
        -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (prefix, suffix) = snapshotAffixes(for: url)
        var date = Date()
        var destination = directory.appending(path: prefix + date.formatted(snapshotStamp) + suffix)
        while FileManager.default.fileExists(atPath: destination.path) {
            date += 0.001
            destination = directory.appending(path: prefix + date.formatted(snapshotStamp) + suffix)
        }
        // Written under another name and renamed once complete, so a snapshot cut short never
        // passes for one.
        let partial = directory.appending(path: ".\(destination.lastPathComponent).partial")
        removeDatabase(at: partial)
        defer { removeDatabase(at: partial) }
        let vacuum = try database.prepare("VACUUM INTO ?")
        try vacuum.bind(partial.path, at: 1)
        try vacuum.run()
        let file = try FileHandle(forUpdating: partial)
        try file.synchronize()
        try file.close()
        try FileManager.default.moveItem(at: partial, to: destination)
        for old in snapshotFiles(in: directory, for: url).dropFirst(max(keeping, 1)) {
            try? FileManager.default.removeItem(at: old)
        }
        return destination
    }

    /// `Index-` and `.sqlite` for `Index.sqlite`: the snapshots' names are the index's with a UTC
    /// time between, so they sort oldest first.
    private static func snapshotAffixes(for url: URL) -> (prefix: String, suffix: String) {
        let ext = url.pathExtension
        return (url.deletingPathExtension().lastPathComponent + "-", ext.isEmpty ? "" : "." + ext)
    }

    private static let snapshotStamp = Date.ISO8601FormatStyle(
        dateSeparator: .omitted, timeSeparator: .omitted, includingFractionalSeconds: true, timeZone: .gmt,
    )

    private static let databaseSuffixes = ["", "-wal", "-shm", "-journal"]

    private static func removeDatabase(at url: URL) {
        for suffix in databaseSuffixes {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}
