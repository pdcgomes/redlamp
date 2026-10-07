import Dispatch
import Foundation
import Synchronization

/// The library's index: the volumes, roots, folders and photos the library knows, how the photos
/// are organised, and a trigram index of their text, in SQLite on the Mac's own disk
/// (`LibraryPaths.index`). It's rebuilt from the photos and their sidecars whenever it's lost.
///
/// One connection writes, on a serial queue of its own, each `write` in one transaction. A few
/// read-only connections read, each on its own serial queue, so a read never waits for a write
/// (WAL). Nothing here runs SQLite on the caller's thread, so the main thread never waits on it.
public final class LibraryIndex: Sendable {
    public let url: URL
    private let writer: Connection
    private let readers: [Connection]
    /// Reads waiting or running on each reader, so the next goes to the least busy.
    private let readerLoad: Mutex<[Int]>

    /// Opens the index at `url`, creating it and its folder if there's none, and brings its
    /// schema up to date.
    public static func open(at url: URL, readers: Int = 4) async throws -> LibraryIndex {
        try await open(at: url, readers: readers, migrations: migrations)
    }

    static func open(at url: URL, readers: Int = 4, migrations: [Migration]) async throws -> LibraryIndex {
        try await offCaller { try LibraryIndex(url: url, readers: readers, migrations: migrations) }
    }

    /// Opens the index, blocking: only ever off the main thread.
    init(url: URL, readers: Int, migrations: [Migration]) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try SQLiteDatabase(path: url.path)
        try Self.configure(database, writing: true)
        try Self.migrate(database, with: migrations)
        self.url = url
        writer = Connection(database, label: "writer")
        self.readers = try (0 ..< max(readers, 1)).map { _ in
            let reader = try SQLiteDatabase(path: url.path, flags: .readOnly)
            try Self.configure(reader, writing: false)
            return Connection(reader, label: "reader")
        }
        readerLoad = Mutex(Array(repeating: 0, count: self.readers.count))
    }

    /// The design's settings: WAL, so readers never wait for the writer; `synchronous=NORMAL`,
    /// so a commit doesn't wait for the disk (a power cut can lose the last commits, never the
    /// database); mapped reads, whose clean pages don't count against Redlamp's memory; and a
    /// 16 MB page cache per connection. The writer has the query language's functions, which fold
    /// the text it indexes (`redlamp_text`).
    private static func configure(_ database: SQLiteDatabase, writing: Bool) throws {
        if writing {
            let mode = try database.prepare("PRAGMA journal_mode = WAL").first { $0.string(at: 0) ?? "" }
            guard mode == "wal" else { throw LibraryIndexError.walUnavailable(journalMode: mode ?? "") }
            try database.execute("PRAGMA synchronous = NORMAL")
            try QueryFunctions.register(on: database)
        }
        try database.execute("""
        PRAGMA busy_timeout = 5000;
        PRAGMA mmap_size = \(1 << 30);
        PRAGMA temp_store = MEMORY;
        PRAGMA cache_size = -\(16 * 1024);
        """)
    }

    // MARK: - Reading and writing

    /// Runs `body` on the write connection, in one transaction: committed when it returns, rolled
    /// back when it throws. Writes run one at a time, in the order they're called. Once called,
    /// a write runs even if the calling task is cancelled.
    @discardableResult
    public func write<T: Sendable>(_ body: @escaping @Sendable (Writer) throws -> T) async throws -> T {
        try await writer.run { database in
            try database.transaction(.immediate) { try body(Writer(database: database)) }
        }
    }

    /// Runs `body` on one of the read connections, in a read transaction: everything it reads is
    /// from one moment, and a write in progress neither holds it up nor shows in it. Cancelling
    /// the calling task drops the read if it hasn't started (throwing `CancellationError`).
    public func read<T: Sendable>(_ body: @escaping @Sendable (Reader) throws -> T) async throws -> T {
        try await onReader { database in
            try database.transaction { try body(Reader(database: database)) }
        }
    }

    /// How many reads can run at once.
    var readerCount: Int {
        readers.count
    }

    /// Reads the index file into memory, in parallel runs through it, ahead of a scan of most of it:
    /// a table's pages lie scattered through the file, and a scan in its order would read them from
    /// a cold disk a page at a time. Pages already in memory cost a mapping each.
    func readAhead() async {
        let path = url.path
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                Self.touchPages(of: path)
                continuation.resume()
            }
        }
    }

    private static func touchPages(of path: String) {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0 else { return }
        let size = Int(info.st_size)
        guard let mapping = mmap(nil, size, PROT_READ, MAP_SHARED, descriptor, 0), mapping != MAP_FAILED else { return }
        defer { munmap(mapping, size) }
        madvise(mapping, size, MADV_WILLNEED)
        nonisolated(unsafe) let pages = UnsafeRawPointer(mapping)
        let page = Int(getpagesize())
        let run = 4 << 20
        let touched = Atomic<Int>(0)
        DispatchQueue.concurrentPerform(iterations: (size + run - 1) / run) { number in
            var sum = 0
            for offset in stride(from: number * run, to: min((number + 1) * run, size), by: page) {
                sum &+= Int(pages.load(fromByteOffset: offset, as: UInt8.self))
            }
            _ = touched.wrappingAdd(sum, ordering: .relaxed)
        }
    }

    /// Runs `body` on the least busy reader, outside any transaction.
    func onReader<T: Sendable>(_ body: @escaping @Sendable (SQLiteDatabase) throws -> T) async throws -> T {
        let slot = readerLoad.withLock { load in
            let slot = load.indices.min { load[$0] < load[$1] } ?? 0
            load[slot] += 1
            return slot
        }
        defer { readerLoad.withLock { $0[slot] -= 1 } }
        return try await readers[slot].run(cancellable: true, body)
    }

    /// Closes the connections once the work queued on them is done: the readers first, then the
    /// writer, which folds the write-ahead log into the database as it closes. Reads and writes
    /// called afterwards throw `LibraryIndexError.closed`.
    public func close() async {
        for reader in readers {
            await reader.close()
        }
        await writer.close()
    }

    /// `close`, blocking: only ever off the main thread.
    func closeAndWait() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        for reader in readers {
            reader.closeAndWait()
        }
        writer.closeAndWait()
    }

    /// Runs `body` on the write connection outside any transaction, blocking: only ever off the
    /// main thread.
    func onWriterAndWait<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return try writer.runAndWait(body)
    }

    /// Runs `body` on a global queue: opening, checking and restoring the index read the disk.
    static func offCaller<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}

public enum LibraryIndexError: Error, Sendable, Hashable {
    /// The index was made by a newer Redlamp, with a schema this build doesn't know.
    case newerVersion(found: Int, supported: Int)
    /// The file system can't keep a write-ahead log (SQLite's shared memory needs a local disk).
    case walUnavailable(journalMode: String)
    /// A keyword path with no names in it.
    case emptyKeywordPath
    case closed
}

/// A connection and the serial queue it's used on; nothing touches it anywhere else.
private final class Connection: @unchecked Sendable {
    private let queue: DispatchQueue
    /// Used only on `queue`.
    private var database: SQLiteDatabase?

    init(_ database: SQLiteDatabase, label: String) {
        self.database = database
        queue = DispatchQueue(label: "app.redlamp.library.index.\(label)", qos: .userInitiated)
    }

    func run<T: Sendable>(
        cancellable: Bool = false, _ body: @escaping @Sendable (SQLiteDatabase) throws -> T,
    ) async throws -> T {
        let handOff = HandOff<T>()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async { [self] in
                    handOff.finish(Result {
                        if cancellable, handOff.isCancelled {
                            throw CancellationError()
                        }
                        guard let database else { throw LibraryIndexError.closed }
                        return try body(database)
                    })
                    continuation.resume()
                }
            }
        } onCancel: {
            handOff.cancel()
        }
        return try handOff.result()
    }

    func runAndWait<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
        try queue.sync {
            guard let database else { throw LibraryIndexError.closed }
            return try body(database)
        }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                database = nil
                continuation.resume()
            }
        }
    }

    func closeAndWait() {
        queue.sync { database = nil }
    }
}

/// What a connection's queue hands back to the caller it ran for, and whether that caller was
/// cancelled. The result goes through a lock as well as through the continuation that resumes the
/// caller, so Thread Sanitizer sees the queue's writes happen before the caller's reads: it doesn't
/// always see the continuation order them.
private final class HandOff<T: Sendable>: Sendable {
    private let cancelled = Atomic(false)
    private let outcome = Mutex<Result<T, any Error>?>(nil)

    var isCancelled: Bool {
        cancelled.load(ordering: .acquiring)
    }

    func cancel() {
        cancelled.store(true, ordering: .releasing)
    }

    func finish(_ result: Result<T, any Error>) {
        outcome.withLock { $0 = result }
    }

    /// The result handed over, once the queue has resumed the caller.
    func result() throws -> T {
        guard let result = outcome.withLock({ $0.take() }) else {
            preconditionFailure("a caller resumed before its result was handed over")
        }
        return try result.get()
    }
}
