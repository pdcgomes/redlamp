import Foundation
import Synchronization
import Testing
@testable import RedlampLibrary

/// Taking lib-1m's Clients (150,000 photos) out of a copy of its index split into a root per top folder, as Folders
/// would hold them: how long the mark takes, then the store, a list of every photo and a search to leave its photos
/// out, the counts' links to go, and the sweep of its rows, with the longest any other write waited meanwhile; with
/// `REDLAMP_ROOT_REMOVAL_BENCH_RECORDS=1`, every photo has a finding, a hash and an XMP merge record for the sweep to
/// take too. Skipped unless `REDLAMP_ROOT_REMOVAL_BENCH=1` (`TEST_RUNNER_REDLAMP_ROOT_REMOVAL_BENCH=1` through
/// xcodebuild) and lib-1m's index is on this Mac.
struct RootRemovalBenchTests {
    static let master = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/indexfix/lib-1m-master/Index.sqlite")
    static let fixture = "/Volumes/SSD/redlamp-tmp/library-fixtures/lib-1m.noindex"

    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1f ms", duration / .milliseconds(1))
    }

    /// The load average over the last minute.
    private static var load: String {
        var averages = [Double](repeating: 0, count: 3)
        getloadavg(&averages, 3)
        return String(format: "%.0f", averages[0])
    }

    private static func report(_ line: String) {
        print("ROOT-REMOVAL-BENCH \(line)")
    }

    /// Makes each of the fixture's top folders a root of its own; returns their paths.
    static func split(_ index: LibraryIndex) async throws -> [String] {
        let root = fixture
        return try await index.write { writer in
            let listing = try writer.database.cached("""
            SELECT path FROM folders WHERE parent = (SELECT id FROM folders WHERE path = ?) ORDER BY path
            """)
            try listing.bind(root, at: 1)
            let tops = try listing.map { $0.string(at: 0) ?? "" }
            let volume = try #require(try writer.root(path: root)).volume
            let own = try writer.database
                .cached("UPDATE folders SET root = ?4 WHERE path = ?1 OR (path >= ?2 AND path < ?3)")
            let top = try writer.database.cached("UPDATE folders SET parent = NULL WHERE path = ?")
            for path in tops {
                try own.bindSubtree(of: path)
                try own.bind(writer.upsertRoot(RootRecord(volume: volume, path: path)), at: 4)
                try own.run()
                try top.bind(path, at: 1)
                try top.run()
            }
            return tops
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_ROOT_REMOVAL_BENCH"] == "1"))
    func `taking 150,000 photos of a million out of the library`() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.master.path), "lib-1m's index is on this Mac")
        let work = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/removed-folders", isDirectory: true)
            .appending(path: "bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let url = work.appending(path: "Index.sqlite")
        try FileManager.default.copyItem(at: Self.master, to: url)
        var limits = IndexCheckpoints.Limits()
        if let threshold = ProcessInfo.processInfo.environment["REDLAMP_ROOT_REMOVAL_BENCH_THRESHOLD"]
            .flatMap(Int.init) {
            limits.threshold = threshold
        }
        let index = try await LibraryIndex.offCaller { [limits] in
            try LibraryIndex(url: url, readers: 4, migrations: LibraryIndex.migrations, logLimits: limits)
        }
        defer { index.closeAndWait() }
        Self.report("checkpoints every \(limits.threshold) pages")
        let tops = try await Self.split(index)
        if ProcessInfo.processInfo.environment["REDLAMP_ROOT_REMOVAL_BENCH_RECORDS"] == "1" {
            // Every photo with a finding, a full hash and an XMP merge record, which the sweep takes with it.
            try await index.write { writer in
                try writer.database.execute("""
                INSERT INTO photo_health (photo, size, modified, damage) SELECT id, size, modified, 2 FROM photos;
                INSERT INTO photo_hashes (photo, size, modified, content_key, sha256)
                  SELECT id, size, modified, coalesce(content_key, x'00'), x'00' FROM photos;
                INSERT INTO settings (key, value) SELECT 'library.xmp.merged.' || id, '{}' FROM photos;
                """)
            }
            Self.report("every photo has a finding, a hash and an XMP merge record")
        }
        // The copy's text index as FTS5's automerge left it, merged as the index now keeps it.
        let merging = ContinuousClock.now
        await index.mergeText()
        Self.report("the text index merged as it opened in \(Self.milliseconds(ContinuousClock.now - merging))")
        let clients = Self.fixture + "/Clients"
        let kept = tops.filter { $0 != clients }
        let engine = QueryEngine(index: index)
        try await engine.load()
        let live = LibraryLive(engine: engine)
        var all = live.open(.allPhotographs, sort: QuerySort(.captured)).makeAsyncIterator()
        let total = try #require(await all.next()).list.count
        Self.report("\(total) photos in \(tops.count) roots, load \(Self.load)")

        let clock = ContinuousClock()
        let started = clock.now
        let removal = try #require(try await index.write { try $0.markRemoved(clients, keeping: kept) })
        let marked = clock.now - started
        await live.remove(removal.photos)
        let stored = clock.now - started
        let list = try #require(await all.next())
        let listed = clock.now - started
        let found = try await engine.list(.query(LibraryQuery(parsing: "folder:Clients"))).count
        let searched = clock.now - started
        try await index.write { try $0.unlinkPhotos(removal.photos) }
        let unlinked = clock.now - started
        #expect(list.list.count == total - removal.photos.count && found == 0)

        // The sweep, with another write asked for every 20 ms meanwhile: none waits longer than a batch. Its wait is
        // until its transaction starts on the writer's queue, then until its caller has its result.
        // Each wait is kept with the log as the write found it (its pages, those copied) and left it: a log that
        // started again at the write had its header synced in its commit.
        let waits = Mutex<[Duration]>([])
        let returns = Mutex<[Duration]>([])
        struct SlowWrite {
            let wait: Duration, back: Duration, asked: (Int, Int), began: (Int, Int), after: Int
        }
        let slow = Mutex<[SlowWrite]>([])
        let sweeping = Mutex(true)
        let writing = Task.detached {
            while sweeping.withLock({ $0 }) {
                let asked = ContinuousClock.now
                let log = (index.logPages, index.logPagesCopied)
                let began = try? await index.write { writer in
                    try writer.setSetting("1", for: "bench.write")
                    return (ContinuousClock.now, index.logPages, index.logPagesCopied)
                }
                let returned = ContinuousClock.now - asked
                let wait = (began?.0 ?? .now) - asked
                waits.withLock { $0.append(wait) }
                returns.withLock { $0.append(returned) }
                if wait > .milliseconds(33.3) || returned > .milliseconds(33.3) {
                    let found = (began?.1 ?? -1, began?.2 ?? -1)
                    slow.withLock { $0.append(SlowWrite(
                        wait: wait,
                        back: returned,
                        asked: log,
                        began: found,
                        after: index.logPages,
                    )) }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let indexer = LibraryIndexer(index: index)
        var batches: [Duration] = []
        var last = clock.now
        var logPages = 0
        for await event in indexer.sweepRemovedRoots() {
            if case let .photosRemoved(ids) = event {
                batches.append(clock.now - last)
                logPages = max(logPages, index.logPages)
                try await engine.update(photos: ids)
                last = clock.now
            }
        }
        let slowest = batches.enumerated().sorted { $0.element > $1.element }.prefix(5)
        Self.report("slowest batches: " + slowest.map { "#\($0.offset) \(Self.milliseconds($0.element))" }
            .joined(separator: ", ") + "; median \(Self.milliseconds(batches.sorted()[batches.count / 2]))")
        let swept = clock.now - started
        let merged = clock.now - last
        sweeping.withLock { $0 = false }
        await writing.value
        let waited = waits.withLock { $0.sorted() }
        let returned = returns.withLock { $0.sorted() }
        let longest = waited.last ?? .zero
        let left = try await index.read { reader in try (reader.photoCount(), reader.removedRoots().count) }
        #expect(left.0 == total - removal.photos.count && left.1 == 0)

        let (frame, frames) = (waited.count { $0 > .milliseconds(16.7) }, waited.count { $0 > .milliseconds(33.3) })
        let (median, p99) = (waited[waited.count / 2], waited[waited.count * 99 / 100])
        let longestFive = waited.suffix(5).reversed().map(Self.milliseconds).joined(separator: ", ")
        let (back, backMost) = (returned[returned.count * 99 / 100], returned.last ?? .zero)
        Self.report("""
        another write's waits for the writer: median \(Self.milliseconds(median)), p99 \(Self.milliseconds(p99)), \
        \(frame) over 16.7 ms and \(frames) over 33.3 ms of \(waited.count), the longest five \(longestFive); back \
        with its caller in p99 \(Self.milliseconds(back)), at most \(Self.milliseconds(backMost)); the log at most \
        \(logPages) pages after a batch; the text index merged after the batches in \(Self.milliseconds(merged))
        """)
        for write in slow.withLock({ $0.sorted { max($0.wait, $0.back) > max($1.wait, $1.back) } }).prefix(8) {
            Self.report("""
            a slow write: waited \(Self.milliseconds(write.wait)), back in \(Self.milliseconds(write.back)); the log \
            \(write.asked.0) pages (\(write.asked.1) copied) as it was asked for, \(write.began.0) (\(write.began.1) \
            copied) as it began, \(write.after) after it
            """)
        }
        Self.report("""
        \(removal.photos.count) photos in \(removal.folders.count) folders, from the removal: marked by \
        \(Self.milliseconds(marked)), out of the store by \(Self.milliseconds(stored)), of the list of every photo \
        by \(Self.milliseconds(listed)), a search for them done by \(Self.milliseconds(searched)), their links gone \
        by \(Self.milliseconds(unlinked)), swept in \(batches.count) batches by \(Self.milliseconds(swept)); another \
        write waited at most \(Self.milliseconds(longest)) of \(waited.count), load \
        \(Self.load)
        """)
    }
}
