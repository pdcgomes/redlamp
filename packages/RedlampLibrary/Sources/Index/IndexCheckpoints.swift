import Dispatch
import Foundation
import SQLite3
import Synchronization

/// The write-ahead log's checkpoints, on a connection of their own (LIB-05). SQLite runs one in the writer's commit
/// once the log passes 1,000 pages, and Apple's SQLite syncs the log and then the database in each, with
/// `F_BARRIERFSYNC` (`checkpoint_fullfsync`): 100 ms and more on an external disk while other work writes to it, which
/// every write waiting for the writer waited for too. The writer's commits now only count the log's pages; this
/// connection copies them into the database as each `threshold` come, without waiting for the writer or the readers,
/// keeping those syncs.
///
/// macOS holds the writes to a file while it's synced (`fsync`, `F_BARRIERFSYNC` and `F_FULLFSYNC` alike, and not
/// those to other files), so a commit that comes while a checkpoint syncs the log waits for the sync to end; and the
/// log has to be synced before its pages are copied, so the copies never reach the disk before the pages they're
/// copied from. Checkpoints a quarter as far apart as SQLite's keep each sync of the log to the few pages written
/// since the last.
///
/// The log starts again from its beginning at the first write after a checkpoint has copied all of it. A writer that
/// never pauses leaves no time for one to, and outruns the checkpoints, whose syncs then hold up a commit that comes
/// meanwhile for as long as they take: the root sweep waits between its writes while the checkpoints are `pacing`
/// pages behind, and for the log to be copied whole once it holds `settling` (`settle`); once the log holds `limit`
/// pages a write waits for a checkpoint before it starts, as every write did each 1,000 pages before.
final class IndexCheckpoints: @unchecked Sendable {
    /// When checkpoints run and are waited for, in the log's pages.
    struct Limits: Sendable, Hashable {
        /// Pages written to the log since it was last checkpointed that ask for a checkpoint: 1 MB.
        var threshold = 256
        /// Pages not yet copied from which `settle` waits for the checkpoints: 8 MB.
        var pacing = 2048
        /// Pages in the log from which `settle` waits for the log to be copied whole: 32 MB.
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
        /// `settle`s waiting, each for the log's pages as it asked to be copied, or for the whole log (nil).
        var waiting: [(pages: Int?, continuation: CheckedContinuation<Void, Never>)] = []
    }

    /// Used only on `queue`.
    private var database: SQLiteDatabase?
    /// At the writer's priority: a checkpoint is how its log starts again.
    private let queue = DispatchQueue(label: "app.redlamp.library.index.checkpoints", qos: .userInitiated)
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

    /// Of `pages`, those a checkpoint has copied.
    var copied: Int {
        state.withLock { min($0.copied, $0.pages) }
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

    /// Returns once the checkpoints have copied the log as it is now, when they're `pacing` pages behind, or once they
    /// have copied it whole, when it holds `settling` pages, so the next write starts it again: between the writes of a
    /// writer that would otherwise never pause.
    func settle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let start = state.withLock { state -> Bool? in
                let behind = state.pages - state.copied
                guard !state.closed, behind > 0, behind >= limits.pacing || state.pages >= limits.settling else {
                    return nil
                }
                state.waiting.append((state.pages >= limits.settling ? nil : state.pages, continuation))
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

    /// Checkpoints until the pages that asked for one are copied, and those `settle`s wait for; a reader holding an
    /// older page back is waited for a little, then left to the next checkpoint.
    private func run() {
        var stalled = 0
        while true {
            let before = state.withLock { $0.copied }
            let succeeded = checkpoint()
            let (again, settled) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                stalled = state.copied > before ? 0 : stalled + 1
                let giveUp = !succeeded || stalled > 20
                // A log that started again is copied as far as anyone waited for.
                let (copied, pages) = (state.copied, state.pages)
                let done = state.waiting.map { giveUp || copied >= ($0.pages ?? pages) || pages < ($0.pages ?? 0) }
                let settled = zip(state.waiting, done).filter(\.1).map(\.0.continuation)
                state.waiting = zip(state.waiting, done).filter { !$0.1 }.map(\.0)
                let again = !giveUp && !state.closed
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
            return state.waiting.map(\.continuation)
        }
        for continuation in waiting {
            continuation.resume()
        }
    }
}
