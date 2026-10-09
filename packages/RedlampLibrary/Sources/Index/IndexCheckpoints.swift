import Dispatch
import Foundation
import SQLite3
import Synchronization

/// The write-ahead log's checkpoints, on a connection of their own (LIB-05). SQLite runs one in the writer's commit
/// once the log passes 1,000 pages, and Apple's SQLite flushes the drive's cache twice in each
/// (`checkpoint_fullfsync`): 100 ms and more on an external disk while other work writes to it, which every write
/// waiting for the writer waited for too. The writer's commits now only count the log's pages; this connection copies
/// them into the database as each 1,000 come, without waiting for the writer or the readers, keeping those flushes.
///
/// The log starts again from its beginning at the first write after a checkpoint has copied all of it. A writer that
/// never pauses leaves no time for one to: the root sweep lets one finish now and then (`settle`), and once the log
/// holds `limit` pages a write waits for one before it starts, as every write did each 1,000 pages before.
final class IndexCheckpoints: @unchecked Sendable {
    /// When checkpoints run and are waited for, in the log's pages.
    struct Limits: Sendable, Hashable {
        /// Pages written to the log since it was last checkpointed that ask for a checkpoint: SQLite's own.
        var threshold = 1000
        /// Pages in the log from which `settle` waits for a checkpoint: 32 MB.
        var settling = 8192
        /// Pages in the log from which a write waits for a checkpoint: 128 MB.
        var limit = 32768
    }

    let limits: Limits

    private struct State {
        /// The log's pages after the writer's last commit, and how many of them a checkpoint has copied.
        var pages = 0
        var copied = 0
        /// A checkpoint is asked for or running.
        var running = false
        var closed = false
        /// `settle`s waiting for the log to be copied whole.
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    /// Used only on `queue`.
    private var database: SQLiteDatabase?
    private let queue = DispatchQueue(label: "app.redlamp.library.index.checkpoints", qos: .utility)
    private let state = Mutex(State())

    /// Opens a connection to the database at `path`, which the writer has opened in WAL mode.
    init(path: String, limits: Limits = Limits()) throws {
        let database = try SQLiteDatabase(path: path, flags: .readWrite)
        // A connection finds its database in WAL mode only once it has read it; until then a checkpoint does nothing.
        try database.execute("SELECT 1 FROM sqlite_schema LIMIT 1")
        self.database = database
        self.limits = limits
    }

    /// Counts the pages in the writer's log after each of its commits, in place of SQLite's own checkpoints there.
    func follow(_ writer: SQLiteDatabase) {
        sqlite3_wal_hook(writer.handle, { context, _, _, pages in
            guard let context else { return SQLITE_OK }
            Unmanaged<IndexCheckpoints>.fromOpaque(context).takeUnretainedValue().committed(pages: Int(pages))
            return SQLITE_OK
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// The log's pages after the writer's last commit.
    var pages: Int {
        state.withLock { $0.pages }
    }

    /// On the writer's queue, after a commit: the log holds `pages` pages.
    private func committed(pages: Int) {
        let start = state.withLock { state -> Bool in
            if pages < state.copied {
                // The log started again.
                state.copied = 0
            }
            state.pages = pages
            guard !state.running, !state.closed, pages - state.copied >= limits.threshold else { return false }
            state.running = true
            return true
        }
        if start {
            queue.async { self.run() }
        }
    }

    /// Returns once a checkpoint has copied the whole log, when it holds `settling` pages or more, so the next write
    /// starts it again: between the writes of a writer that would otherwise never pause.
    func settle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let start = state.withLock { state -> Bool? in
                guard !state.closed, state.pages >= limits.settling, state.copied < state.pages else { return nil }
                state.waiting.append(continuation)
                guard !state.running else { return false }
                state.running = true
                return true
            }
            switch start {
            case nil: continuation.resume()
            case true?: queue.async { self.run() }
            case false?: break
            }
        }
    }

    /// On the writer's queue, before a transaction: once the log holds `limit` pages, waits for a checkpoint to copy
    /// all of them, so the transaction starts it again.
    func copyIfFull() {
        guard state.withLock({ $0.pages >= limits.limit && $0.copied < $0.pages }) else { return }
        queue.sync { _ = checkpoint() }
    }

    /// Checkpoints until the pages that asked for it are copied, and the log whole while `settle`s wait; a reader
    /// holding an older page back is waited for a little, then left to the next checkpoint.
    private func run() {
        var stalled = 0
        while true {
            let before = state.withLock { $0.copied }
            let succeeded = checkpoint()
            let (again, settled) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                stalled = state.copied > before ? 0 : stalled + 1
                let whole = state.copied >= state.pages
                let settled = whole || !succeeded || stalled > 20 ? state.waiting : []
                if !settled.isEmpty {
                    state.waiting = []
                }
                let again = succeeded && !state.closed && stalled <= 20
                    && (state.pages - state.copied >= limits.threshold || !state.waiting.isEmpty)
                state.running = again
                return (again, settled)
            }
            for waiting in settled {
                waiting.resume()
            }
            guard again else { return }
            if stalled > 0 {
                usleep(5000)
            }
        }
    }

    /// One checkpoint of as much of the log as no reader holds back, without waiting for the writer; whether SQLite
    /// ran it.
    private func checkpoint() -> Bool {
        guard let database else { return false }
        var log: Int32 = -1
        var copied: Int32 = -1
        guard sqlite3_wal_checkpoint_v2(database.handle, nil, SQLITE_CHECKPOINT_PASSIVE, &log, &copied) == SQLITE_OK,
              copied >= 0
        else { return false }
        state.withLock { $0.copied = Int(copied) }
        return true
    }

    /// Closes the connection once a checkpoint under way is done; `settle`s waiting return.
    func close() async {
        stop()
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                database = nil
                continuation.resume()
            }
        }
    }

    /// `close`, blocking: only ever off the main thread.
    func closeAndWait() {
        stop()
        queue.sync { database = nil }
    }

    private func stop() {
        let waiting = state.withLock { state in
            state.closed = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting {
            continuation.resume()
        }
    }
}
