import Foundation
import SQLite3
import Synchronization

/// Which moment of the index something reflects (LIB-44): the schema's version, a counter the writer
/// bumps in every transaction that changes the index, and a number drawn at random in each, so an
/// index put back from an older copy, or made again from nothing, never passes for a moment of
/// another history when it counts up to the same number.
struct IndexGeneration: Sendable, Hashable {
    var schema: Int
    var counter: Int64
    var token: Int64

    static let counterKey = "index.generation"
    static let tokenKey = "index.generationToken"
}

extension IndexQueries {
    /// The index's generation as this connection sees it: 0 before its first change.
    func generation() throws -> IndexGeneration {
        let statement = try database.cached("""
        SELECT (SELECT value FROM settings WHERE key = '\(IndexGeneration.counterKey)'),
          (SELECT value FROM settings WHERE key = '\(IndexGeneration.tokenKey)')
        """)
        let (counter, token) = try statement.first { ($0.int64(at: 0), $0.int64(at: 1)) } ?? (0, 0)
        return try IndexGeneration(schema: database.userVersion, counter: counter, token: token)
    }
}

/// What each of this process's transactions changed that the column store holds: the photos whose
/// rows it wrote, and whether it wrote a table the store's names come from (folders, cameras, lenses,
/// keywords, collections). A store that reflects one generation is brought up to a later one by
/// reading those photos and names again, as long as every transaction between was this process's
/// and is still kept: another process's write leaves a gap.
///
/// Photos are noted from SQLite's update hook on the write connection, and from the writer's text,
/// which every change of a photo's keywords writes again (`photo_keywords` has no row IDs, so the
/// hook doesn't see it). Keywords' links and collections' photos aren't columns of the store.
final class IndexJournal: @unchecked Sendable {
    struct Changes: Sendable, Hashable {
        var photos: Set<Int64> = []
        var names = false
    }

    private struct Entry {
        let generation: IndexGeneration
        let photos: [Int64]
        let names: Bool
    }

    /// The transactions kept, oldest first, and the photos they name.
    private struct Kept {
        var entries: [Entry] = []
        var photos = 0
    }

    /// Kept, at most: older transactions are dropped, and a store from before them can't catch up.
    static let keptPhotos = 1 << 18
    static let keptTransactions = 1 << 14

    private let kept = Mutex(Kept())
    private let observers = Mutex<[UUID: @Sendable () -> Void]>([:])
    /// The transaction in progress, used only on the writer's queue.
    private var photos: [Int64] = []
    private var names = false

    // MARK: - On the writer's queue

    /// Starts noting a transaction's changes.
    func begin() {
        photos.removeAll(keepingCapacity: true)
        names = false
    }

    /// Notes a row SQLite's update hook reports.
    func record(table: UnsafePointer<CChar>, row: Int64) {
        if strcmp(table, Self.photosTable) == 0 {
            photos.append(row)
        } else if !names, Self.namedTables.contains(where: { strcmp(table, $0) == 0 }) {
            names = true
        }
    }

    /// Notes photos whose keywords may have changed.
    func touch(photos ids: some Sequence<Int64>) {
        photos.append(contentsOf: ids)
    }

    /// Bumps the generation in the transaction in progress, as its last statement, and keeps what it
    /// changed under it before it commits: a reader can see the new generation only once it has.
    func stage(on database: SQLiteDatabase) throws -> IndexGeneration {
        let bump = try database.cached("""
        UPDATE settings SET value = value + 1 WHERE key = '\(IndexGeneration.counterKey)' RETURNING value
        """)
        let counter: Int64
        if let bumped = try bump.first({ $0.int64(at: 0) }) {
            counter = bumped
        } else {
            counter = 1
            let insert = try database.cached("INSERT INTO settings (key, value) VALUES (?, ?)")
            try insert.bind(IndexGeneration.counterKey, at: 1)
            try insert.bind(counter, at: 2)
            try insert.run()
        }
        let token = Int64.random(in: .min ... .max)
        let set = try database.cached("""
        INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value
        """)
        try set.bind(IndexGeneration.tokenKey, at: 1)
        try set.bind(token, at: 2)
        try set.run()
        let generation = try IndexGeneration(schema: database.userVersion, counter: counter, token: token)
        let entry = Entry(generation: generation, photos: Array(Set(photos)), names: names)
        kept.withLock { kept in
            kept.entries.append(entry)
            kept.photos += entry.photos.count
            var dropped = 0
            while kept.entries.count - dropped > 1,
                  kept.photos > Self.keptPhotos || kept.entries.count - dropped > Self.keptTransactions {
                kept.photos -= kept.entries[dropped].photos.count
                dropped += 1
            }
            kept.entries.removeFirst(dropped)
        }
        return generation
    }

    /// Forgets the transaction staged as `generation`, which didn't commit.
    func unstage(_ generation: IndexGeneration) {
        kept.withLock { kept in
            guard kept.entries.last?.generation == generation else { return }
            kept.photos -= kept.entries.removeLast().photos.count
        }
    }

    /// Tells the observers a transaction committed.
    func committed() {
        for observer in observers.withLock({ Array($0.values) }) {
            observer()
        }
    }

    // MARK: - Anywhere

    /// What this process's transactions changed after `start` up to and including `end`, both read
    /// from the index; nil when that isn't known: another process wrote in between, the transactions
    /// are no longer kept, or the index isn't the one they were made in.
    func changes(after start: IndexGeneration, through end: IndexGeneration) -> Changes? {
        guard start.schema == end.schema, start.counter <= end.counter else { return nil }
        guard start != end else { return Changes() }
        return kept.withLock { kept -> Changes? in
            let entries = kept.entries
            var index = entries.count - 1
            while index >= 0, entries[index].generation.counter > end.counter {
                index -= 1
            }
            guard index >= 0, entries[index].generation == end else { return nil }
            var changes = Changes()
            var expected = end.counter
            while index >= 0, entries[index].generation.counter > start.counter {
                let entry = entries[index]
                guard entry.generation.counter == expected else { return nil }
                changes.photos.formUnion(entry.photos)
                changes.names = changes.names || entry.names
                expected -= 1
                index -= 1
            }
            guard expected == start.counter else { return nil }
            if index >= 0, entries[index].generation.counter == start.counter, entries[index].generation != start {
                return nil
            }
            return changes
        }
    }

    /// Calls `observer` after each transaction that changed the index commits, until it's removed.
    func observe(_ observer: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        observers.withLock { $0[id] = observer }
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.withLock { _ = $0.removeValue(forKey: id) }
    }

    private static let photosTable: [CChar] = Array("photos".utf8CString)
    private static let namedTables: [[CChar]] = ["folders", "cameras", "lenses", "keywords", "collections"]
        .map { Array($0.utf8CString) }
}
