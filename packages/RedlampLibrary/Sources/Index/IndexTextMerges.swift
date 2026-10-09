import Foundation
import Synchronization

/// The text index's merging (LIB-05). FTS5 writes each transaction's text as a segment and, with its automerge, merges
/// segments inside the commit of whichever write finds a merge due, counting each row deleted from a contentless
/// table as a page written: a commit of 1,000 photos' keywords merged about 3,000 pages, a second or more at a million
/// photos, and every write waiting for the writer waited with it. Automerge is off for every writer (`photo_text`'s
/// own setting, set as the index opens), and after each transaction that writes the text index the merges follow
/// on the writer's queue, a step at a time, each a transaction of its own of about `Limits.step`, so another write
/// waits at most a step. They go on while FTS5 finds segments to merge, as automerge would have: four on a level
/// (its `usermerge`), a merge under way, or a level a tenth deleted.
///
/// A write of text returns only once no level holds `Limits.crowded` segments: a writer writing text without pausing,
/// an index build or a keyword batch of many transactions, goes at the merges' pace, searches look in few segments,
/// and no level reaches FTS5's crisis merge (16 on a level), which merges the level whole inside a commit.
final class IndexTextMerges: Sendable {
    struct Limits: Sendable, Hashable {
        /// How long a step merges for, about: a merge stops only between terms, so a step merging the trigrams most
        /// names share in a large level runs past it.
        var step = Duration.milliseconds(8)
        /// Pages asked of each of FTS5's merges in a step.
        var pages = 16
        /// Segments on a level from which a write of text waits for the merges before it returns.
        var crowded = 8
        /// The merges follow writes; off, they run only when asked (`LibraryIndex.mergeText`).
        var following = true
    }

    let limits: Limits

    private struct State {
        var running = false
        var closed = false
        /// A level of the text index holds `limits.crowded` segments, as the last write or step left it.
        var crowded = false
        /// Writes waiting for no level to be crowded.
        var waiting: [CheckedContinuation<Void, Never>] = []
        /// Callers waiting for nothing to be left to merge.
        var idle: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Whether `structure` has a level of `limits.crowded` segments; not when it can't be read.
    func isCrowded(_ structure: TextIndexStructure?) -> Bool {
        structure?.levels.contains { $0.segments >= limits.crowded } ?? false
    }

    /// After a transaction that wrote the text index, leaving `structure`: whether the merges should start, which the
    /// caller does, and whether it should wait for them (`caughtUp`). They don't start while they're running, or when
    /// they don't follow writes.
    func wrote(_ structure: TextIndexStructure?) -> (start: Bool, wait: Bool) {
        guard limits.following else { return (false, false) }
        let crowded = isCrowded(structure)
        return state.withLock { state in
            guard !state.closed else { return (false, false) }
            state.crowded = crowded
            let start = !state.running
            state.running = true
            return (start, crowded)
        }
    }

    /// Returns once no level of the text index is crowded, or the merges have stopped.
    func caughtUp() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waits = state.withLock { state -> Bool in
                guard state.running, !state.closed, state.crowded else { return false }
                state.waiting.append(continuation)
                return true
            }
            if !waits {
                continuation.resume()
            }
        }
    }

    /// Returns once the merges have found nothing left to merge, or have stopped.
    func finished() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waits = state.withLock { state -> Bool in
                guard state.running, !state.closed else { return false }
                state.idle.append(continuation)
                return true
            }
            if !waits {
                continuation.resume()
            }
        }
    }

    /// Asks for the merges to run though no write started them (`LibraryIndex.mergeText`); whether they should start.
    func begin() -> Bool {
        state.withLock { state in
            guard !state.closed, !state.running else { return false }
            state.running = true
            return true
        }
    }

    /// After a step that merged `pages`, 0 when nothing was left to merge and nil when it failed, leaving `structure`:
    /// whether to take another.
    func stepped(_ pages: Int?, leaving structure: TextIndexStructure?) -> Bool {
        let crowded = isCrowded(structure)
        let (again, resumed) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
            state.crowded = crowded
            if pages ?? 0 == 0 || state.closed {
                state.running = false
            }
            var resumed: [CheckedContinuation<Void, Never>] = []
            if !state.crowded || !state.running {
                resumed = state.waiting
                state.waiting = []
            }
            if !state.running {
                resumed += state.idle
                state.idle = []
            }
            return (state.running, resumed)
        }
        for continuation in resumed {
            continuation.resume()
        }
        return again
    }

    /// Stops the merges after the step under way; the writes and callers waiting for them return.
    func close() {
        let waiting = state.withLock { state in
            state.closed = true
            defer {
                state.waiting = []
                state.idle = []
            }
            return state.waiting + state.idle
        }
        for continuation in waiting {
            continuation.resume()
        }
    }
}

/// What FTS5's structure record says of a text index's segments (row 10 of its `_data` table, as `fts5_index.c`
/// writes it): a cookie, a version's mark when the table keeps tombstones, how many levels and segments there are and
/// a write counter, then each level's segments being merged and its segments, each with its ID and pages and, with
/// the version's mark, its origins, tombstones and rows. All but the cookie and the mark are SQLite's varints.
struct TextIndexStructure: Sendable, Hashable {
    struct Level: Sendable, Hashable {
        var segments: Int
        /// Of `segments`, those a merge under way reads from.
        var merging: Int
    }

    /// The first level holds the newest, smallest segments.
    var levels: [Level]

    var segments: Int {
        levels.reduce(0) { $0 + $1.segments }
    }
}

extension TextIndexStructure {
    /// The structure `record` holds; nil when it isn't one this build can read.
    init?(_ record: Data) {
        let bytes = [UInt8](record)
        var offset = 4
        let tombstones = bytes.count >= 8 && bytes[4 ..< 8] == [0xFF, 0, 0, 1]
        if tombstones {
            offset = 8
        }
        guard let count = Self.varint(bytes, &offset), let total = Self.varint(bytes, &offset),
              Self.varint(bytes, &offset) != nil, count < 1 << 16
        else { return nil }
        var levels: [Level] = []
        for _ in 0 ..< count {
            guard let merging = Self.varint(bytes, &offset), let segments = Self.varint(bytes, &offset),
                  merging <= segments, segments <= total
            else { return nil }
            for _ in 0 ..< segments * (tombstones ? 8 : 3) {
                guard Self.varint(bytes, &offset) != nil else { return nil }
            }
            levels.append(Level(segments: Int(segments), merging: Int(merging)))
        }
        guard levels.reduce(0, { $0 + $1.segments }) == total else { return nil }
        self.levels = levels
    }

    /// SQLite's varint at `offset`, moving past it: seven bits a byte, high first, the ninth byte's eight whole.
    private static func varint(_ bytes: [UInt8], _ offset: inout Int) -> UInt64? {
        var value: UInt64 = 0
        for count in 0 ..< 9 {
            guard offset + count < bytes.count else { return nil }
            let byte = bytes[offset + count]
            if count == 8 {
                offset += 9
                return value << 8 | UInt64(byte)
            }
            value = value << 7 | UInt64(byte & 0x7F)
            if byte < 0x80 {
                offset += count + 1
                return value
            }
        }
        return nil
    }
}

extension IndexQueries {
    /// The text index's segments as its structure record holds them; nil when it can't be read.
    func textStructure() throws -> TextIndexStructure? {
        try database.cached("SELECT block FROM photo_text_data WHERE id = 10").first { row in
            row.data(at: 0).flatMap(TextIndexStructure.init)
        } ?? nil
    }
}
