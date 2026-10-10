import Dispatch
import Foundation
import SQLite3
import Synchronization

/// The library's index: the volumes, roots, folders and photos the library knows, how the photos
/// are organised, and a trigram index of their text, in SQLite on the Mac's own disk
/// (`LibraryPaths.index`). It's rebuilt from the photos and their sidecars whenever it's lost.
///
/// One connection writes, on a serial queue of its own, each `write` in one transaction. A few
/// read-only connections read, each on its own serial queue, so a read never waits for a write
/// (WAL), and one more checkpoints the write-ahead log, so a write doesn't wait for that either
/// (`IndexCheckpoints`). The text index is merged after the writes, between them (`IndexTextMerges`).
/// Nothing here runs SQLite on the caller's thread, so the main thread never waits on it.
public final class LibraryIndex: Sendable {
    public let url: URL
    private let writer: Connection
    private let readers: [Connection]
    private let checkpoints: IndexCheckpoints
    private let merges: IndexTextMerges
    /// Reads waiting or running on each reader, so the next goes to the least busy.
    private let readerLoad: Mutex<[Int]>
    /// What this process's transactions changed, by the generation each made (LIB-44).
    let journal = IndexJournal()
    /// The folders file batches are changing, which the indexer lists once their index is written (LIB-26).
    let folderHolds = FolderHolds()
    /// The photos the library's batches are writing, whose reads the indexer writes only once they're done (LIB-07).
    let photoWrites = PhotoWrites()
    /// Marks at or above the last IDs given, kept beside the index too (LIB-05).
    let marks: IndexIDMarks
    /// How long after the last write that gave IDs the marks are brought down to them (`IndexIDMarks.settle`).
    private let idSettling: Duration
    private let settlingIDs = Mutex<Task<Void, Never>?>(nil)

    /// Opens the index at `url`, creating it and its folder if there's none, and brings its
    /// schema up to date and its last IDs into step with those kept beside it (`IndexIDMarks`).
    public static func open(at url: URL, readers: Int = 4) async throws -> LibraryIndex {
        try await open(at: url, readers: readers, migrations: migrations)
    }

    static func open(at url: URL, readers: Int = 4, migrations: [Migration]) async throws -> LibraryIndex {
        try await offCaller { try LibraryIndex(url: url, readers: readers, migrations: migrations) }
    }

    /// Opens the index, blocking: only ever off the main thread.
    init(
        url: URL, readers: Int, migrations: [Migration], logLimits: IndexCheckpoints.Limits = .init(),
        textMerges: IndexTextMerges.Limits = .init(), idBlocks: [IndexIDs: Int64]? = nil,
        idSettling: Duration = .seconds(2),
    ) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try SQLiteDatabase(path: url.path)
        try Self.configure(database, writing: true)
        try Self.migrate(database, with: migrations)
        try Self.leaveMergingToSteps(database)
        merges = IndexTextMerges(limits: textMerges)
        let marks = IndexIDMarks(index: url, blocks: idBlocks)
        self.idSettling = idSettling
        // The tables the last IDs are worked out from are this build's schema's.
        if migrations.count == Self.migrations.count {
            try database.transaction(.immediate) { try marks.reconcile(Writer(database: database)) }
        }
        self.marks = marks
        sqlite3_update_hook(database.handle, { context, _, _, table, row in
            guard let context, let table else { return }
            Unmanaged<IndexJournal>.fromOpaque(context).takeUnretainedValue().record(table: table, row: row)
        }, Unmanaged.passUnretained(journal).toOpaque())
        let checkpoints = try IndexCheckpoints(path: url.path, limits: logLimits)
        checkpoints.follow(database)
        self.checkpoints = checkpoints
        self.url = url
        writer = Connection(database, label: "writer")
        self.readers = try (0 ..< max(readers, 1)).map { _ in
            let reader = try SQLiteDatabase(path: url.path, flags: .readOnly)
            try Self.configure(reader, writing: false)
            return Connection(reader, label: "reader")
        }
        readerLoad = Mutex(Array(repeating: 0, count: self.readers.count))
        // What a session before this one left to merge.
        if textMerges.following, merges.begin() {
            startMerging()
        }
    }

    /// Turns FTS5's automerge off for the text index, for every connection and process, which keeps the setting in
    /// the table: the merges follow the writes instead (`IndexTextMerges`).
    private static func leaveMergingToSteps(_ database: SQLiteDatabase) throws {
        let automerge = try database.prepare("SELECT v FROM photo_text_config WHERE k = 'automerge'")
            .first { $0.int(at: 0) }
        guard automerge != 0 else { return }
        try database.transaction(.immediate) {
            try database.execute("INSERT INTO photo_text (photo_text, rank) VALUES ('automerge', 0)")
        }
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
    /// a write runs even if the calling task is cancelled. A transaction that changes the index bumps
    /// its generation (`IndexGeneration`), and one that gives IDs past the marks beside the index sets them
    /// ahead before it commits (`IndexIDMarks`). One that writes photos' text has the text index merged after,
    /// and returns once none of its levels is crowded with segments (`IndexTextMerges`).
    @discardableResult
    public func write<T: Sendable>(_ body: @escaping @Sendable (Writer) throws -> T) async throws -> T {
        let result = try await writer.run { [journal, marks, checkpoints, merges] database -> Written<T> in
            checkpoints.copyIfFull()
            var staged: IndexGeneration?
            var gave = false
            var wroteText = false
            do {
                let result = try database.transaction(.immediate) {
                    let before = database.totalChanges
                    journal.begin()
                    marks.begin()
                    let writer = Writer(database: database, journal: journal, marks: marks)
                    let result = try body(writer)
                    wroteText = writer.wroteText
                    gave = try marks.save()
                    if database.totalChanges != before {
                        staged = try journal.stage(on: database)
                    }
                    return result
                }
                // A transaction that only took text out leaves no new segment: what it deleted is merged after the
                // next write of text, at the next open, or when asked (`mergeText`), as the root sweep asks.
                return Written(
                    result: result, changed: staged != nil, gaveIDs: gave && marks.ahead, wroteText: wroteText,
                    structure: wroteText ? (try? Reader(database: database).textStructure()) : nil,
                    number: wroteText ? merges.numbered() : 0,
                )
            } catch {
                if let staged {
                    journal.unstage(staged)
                }
                throw error
            }
        }
        if result.changed {
            journal.committed()
        }
        if result.gaveIDs {
            settleIDsLater()
        }
        if result.wroteText {
            let (start, wait) = merges.wrote(result.structure, number: result.number)
            if start {
                startMerging()
            }
            if wait {
                await merges.caughtUp()
            }
        }
        return result.result
    }

    /// What a write's transaction did, beside its result.
    private struct Written<T: Sendable>: Sendable {
        var result: T
        var changed: Bool
        var gaveIDs: Bool
        var wroteText: Bool
        /// The text index's segments after it, when it wrote any text, and its number on the writer's queue
        /// (`IndexTextMerges.numbered`).
        var structure: TextIndexStructure?
        var number: UInt64
    }

    /// Merges the text index a step at a time on the writer's queue, each step after the writes asked for
    /// before it, until FTS5 finds nothing to merge (`IndexTextMerges`); between steps, waits while the
    /// checkpoints are behind, as the root sweep does.
    private func startMerging() {
        let limits = merges.limits
        Task.detached(priority: .utility) { [weak self] in
            while let index = self {
                let (checkpoints, merges) = (index.checkpoints, index.merges)
                let step = try? await index.writer.run { database in
                    checkpoints.copyIfFull()
                    let (pages, structure) = try Self.mergeStep(database, limits)
                    return (pages: pages, structure: structure, number: merges.numbered())
                }
                guard merges.stepped(step?.pages, leaving: step?.structure, number: step?.number) else { return }
                await index.checkpoints.settle()
            }
        }
    }

    /// One step of merging, in a transaction of its own: FTS5 merges `limits.pages` at a time until
    /// `limits.step` has passed or it finds nothing to merge. The pages it asked for, 0 when there was nothing,
    /// and the segments it left.
    private static func mergeStep(
        _ database: SQLiteDatabase, _ limits: IndexTextMerges.Limits,
    ) throws -> (pages: Int, structure: TextIndexStructure?) {
        let deadline = ContinuousClock.now + limits.step
        return try database.transaction(.immediate) {
            let writer = Writer(database: database)
            var merged = 0
            while try writer.mergeText(pages: limits.pages) {
                merged += limits.pages
                guard ContinuousClock.now < deadline else { break }
            }
            return try (merged, writer.textStructure())
        }
    }

    /// Returns once the text index has nothing left to merge, merging it if no write has started the merges:
    /// for a writer that has finished writing, and tests.
    func mergeText() async {
        if merges.begin() {
            startMerging()
        }
        await merges.finished()
    }

    /// The text index's segments as the writer sees them now; nil when its structure can't be read.
    func textStructure() async throws -> TextIndexStructure? {
        try await writer.run { try Reader(database: $0).textStructure() }
    }

    /// Brings the marks beside the index down to the last IDs given once `idSettling` passes with no write giving
    /// any, so the next open skips none of them.
    private func settleIDsLater() {
        let wait = idSettling
        let task = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            try? await settleIDs()
        }
        settlingIDs.withLock { settling in
            settling?.cancel()
            settling = task
        }
    }

    /// Brings the marks beside the index down to the last IDs given, when this process set them ahead
    /// (`IndexIDMarks.settle`).
    func settleIDs() async throws {
        try await writer.run { [marks] database in try Self.settle(marks, on: database) }
    }

    private static func settle(_ marks: IndexIDMarks, on database: SQLiteDatabase) throws {
        guard marks.ahead else { return }
        try database.transaction(.immediate) { try marks.settle(Writer(database: database)) }
    }

    /// Runs `body` on one of the read connections, in a read transaction: everything it reads is
    /// from one moment, and a write in progress neither holds it up nor shows in it. Cancelling
    /// the calling task drops the read if it hasn't started (throwing `CancellationError`).
    public func read<T: Sendable>(_ body: @escaping @Sendable (Reader) throws -> T) async throws -> T {
        try await onReader { database in
            try database.transaction { try body(Reader(database: database)) }
        }
    }

    /// Returns once the write-ahead log has been copied into the database whole, when it has grown long, so the next
    /// write starts it again (`IndexCheckpoints.settle`): for a writer that writes without pausing, between its
    /// writes, which other writes go on around.
    func settle() async {
        await checkpoints.settle()
    }

    /// The pages in the write-ahead log after the last write.
    var logPages: Int {
        checkpoints.pages
    }

    /// Of `logPages`, those checkpointed into the database.
    var logPagesCopied: Int {
        checkpoints.copied
    }

    /// When the write-ahead log is checkpointed, and checkpoints are waited for.
    var checkpointLimits: IndexCheckpoints.Limits {
        checkpoints.limits
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

    /// Closes the connections once the work queued on them is done: the readers and the
    /// checkpoints first, then the writer, which brings the marks beside the index down to the last
    /// IDs given and folds the write-ahead log into the database as it closes. The text index's merges
    /// stop after the step under way; what's left is merged after the next write. Reads and writes called
    /// afterwards throw `LibraryIndexError.closed`.
    public func close() async {
        settlingIDs.withLock { $0?.cancel() }
        merges.close()
        for reader in readers {
            await reader.close()
        }
        await checkpoints.close()
        try? await settleIDs()
        await writer.close()
    }

    /// `close`, blocking: only ever off the main thread.
    func closeAndWait() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        settlingIDs.withLock { $0?.cancel() }
        merges.close()
        for reader in readers {
            reader.closeAndWait()
        }
        checkpoints.closeAndWait()
        try? writer.runAndWait { try Self.settle(marks, on: $0) }
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
