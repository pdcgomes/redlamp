import Foundation
import SQLite3
import Synchronization
import Testing
@testable import RedlampLibrary

/// The text index's merging at a million photos (LIB-05), on two copies of lib-1m's index in turn, so they share the
/// load: merged as before, by FTS5's automerge in the commits of the writes, and as built, a step at a time after them
/// (`IndexTextMerges`). Each takes keyword batches of 1,000 photos spread across the library, then indexing batches of
/// 1,000 new photos. For each batch: how long its transaction held the writer up to its commit, FTS5's writing and
/// merging the text included (SQLite's commit hook), how long it took its caller, and how long another write asked
/// for every 20 ms meanwhile waited for the writer; every ten batches, searches of the text index for words and names
/// the fixture holds, with its segments. Skipped unless `REDLAMP_TEXT_MERGE_BENCH=1`
/// (`TEST_RUNNER_REDLAMP_TEXT_MERGE_BENCH=1` through xcodebuild) and lib-1m's index is on this Mac.
struct TextMergeBenchTests {
    static let keywordBatches = 100
    static let indexingBatches = 30
    static let batchSize = 1000
    static let terms = [
        "rain", "boats in", "festival", "autumn colours", "night lights", "dsc_1", "dji_10", "img_4", "dscf11",
        "forest", "birds", "garden", "bench batch",
    ]

    private static func report(_ line: String) {
        print("TEXT-MERGE-BENCH \(line)")
    }

    static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1f", duration / .milliseconds(1))
    }

    /// Median, p95, p99 and the longest, in milliseconds.
    static func spread(_ durations: [Duration]) -> String {
        let sorted = durations.sorted()
        guard !sorted.isEmpty else { return "none" }
        func at(_ fraction: Double) -> String {
            milliseconds(sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))])
        }
        return "median \(at(0.5)), p95 \(at(0.95)), p99 \(at(0.99)), max \(at(1)) ms of \(sorted.count)"
    }

    /// The load average over the last minute.
    static var loadAverage: Double {
        var averages = [Double](repeating: 0, count: 3)
        getloadavg(&averages, 3)
        return averages[0]
    }

    static var load: String {
        String(format: "%.0f", loadAverage)
    }

    /// When the writer's transaction a batch armed reaches its commit, after FTS5 has written the transaction's text
    /// and, as before, merged in it (SQLite's commit hook): the merges' own transactions don't count.
    final class CommitClock: @unchecked Sendable {
        private let state = Mutex<(armed: UInt64?, reached: UInt64?)>((nil, nil))

        func arm() {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            state.withLock { $0 = (now, nil) }
        }

        func committing() {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            state.withLock { state in
                if state.armed != nil, state.reached == nil {
                    state.reached = now
                }
            }
        }

        /// From the armed transaction's start to its commit.
        var held: Duration? {
            state.withLock { state in
                guard let armed = state.armed, let reached = state.reached else { return nil }
                return .nanoseconds(Int64(reached - armed))
            }
        }

        func follow(_ index: LibraryIndex) throws {
            _ = try index.onWriterAndWait { database in
                sqlite3_commit_hook(database.handle, { context in
                    guard let context else { return 0 }
                    Unmanaged<CommitClock>.fromOpaque(context).takeUnretainedValue().committing()
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
            }
        }
    }

    /// Another write every 20 ms while `body` runs: how long each waited for the writer before its transaction began.
    static func probing(_ index: LibraryIndex, _ body: () async throws -> Void) async rethrows -> [Duration] {
        let waits = Mutex<[Duration]>([])
        let probing = Mutex(true)
        let probe = Task.detached {
            while probing.withLock({ $0 }) {
                let asked = ContinuousClock.now
                let began = try? await index.write { writer in
                    try writer.setSetting("1", for: "bench.probe")
                    return ContinuousClock.now
                }
                waits.withLock { $0.append((began ?? .now) - asked) }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer {
            probing.withLock { $0 = false }
        }
        try await body()
        probing.withLock { $0 = false }
        await probe.value
        return waits.withLock { $0 }
    }

    final class Arm: @unchecked Sendable {
        let name: String
        let index: LibraryIndex
        let clock = CommitClock()
        var held: [Duration] = []
        var returned: [Duration] = []
        var waits: [Duration] = []
        /// The write-ahead log's pages after each batch.
        var logPages: [Int] = []
        var searches: [(photos: Int, durations: [Duration], segments: String)] = []
        /// The root and the maker of the new photos the indexing batches add.
        var newPhotos: (root: Int64, maker: SyntheticIndexPhotos)?

        init(name: String, index: LibraryIndex) throws {
            self.name = name
            self.index = index
            try clock.follow(index)
        }

        /// Runs `write` as a batch, timed.
        func batch(_ write: @escaping @Sendable (LibraryIndex.Writer) throws -> Void) async throws {
            let started = ContinuousClock.now
            try await index.write { [clock] writer in
                clock.arm()
                try write(writer)
            }
            returned.append(ContinuousClock.now - started)
            held.append(clock.held ?? .zero)
            logPages.append(index.logPages)
        }

        func search(after photos: Int) async throws {
            var durations: [Duration] = []
            for _ in 0 ..< 3 {
                for term in TextMergeBenchTests.terms {
                    let started = ContinuousClock.now
                    _ = try await index.read { try $0.photoIDs(matching: QueryText.match(term)) }
                    durations.append(ContinuousClock.now - started)
                }
            }
            let structure = try await index.textStructure()
            let segments = structure.map { "\($0.segments) segments, by level \($0.levels.map(\.segments))" } ?? "?"
            searches.append((photos, durations, segments))
        }

        func reportPhase(_ phase: String) {
            TextMergeBenchTests.report("\(name) \(phase): held to its commit \(TextMergeBenchTests.spread(held))")
            TextMergeBenchTests.report("\(name) \(phase): back with its caller \(TextMergeBenchTests.spread(returned))")
            TextMergeBenchTests.report("""
            \(name) \(phase): another write's wait \(TextMergeBenchTests.spread(waits)), \
            \(waits.count { $0 > .milliseconds(16.7) }) over 16.7 ms; the log at most \(logPages.max() ?? 0) pages \
            after a batch
            """)
            for search in searches {
                TextMergeBenchTests.report("""
                \(name) \(phase) after \(search.photos): searches \(TextMergeBenchTests.spread(search.durations)); \
                \(search.segments)
                """)
            }
            held = []
            returned = []
            waits = []
            logPages = []
            searches = []
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_TEXT_MERGE_BENCH"] == "1"))
    func `keyword and indexing batches at a million photos, merged in their commits and a step at a time after`(
    ) async throws {
        let master = RootRemovalBenchTests.master
        try #require(FileManager.default.fileExists(atPath: master.path), "lib-1m's index is on this Mac")
        let work = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/text-merges", isDirectory: true)
            .appending(path: "bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        var arms: [Arm] = []
        for name in ["in commits", "in steps"] {
            let folder = work.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: "Index.sqlite")
            try FileManager.default.copyItem(at: master, to: url)
            let stepped = name == "in steps"
            let index = try await LibraryIndex.offCaller {
                try LibraryIndex(
                    url: url, readers: 2, migrations: LibraryIndex.migrations,
                    textMerges: IndexTextMerges.Limits(following: stepped),
                )
            }
            if !stepped {
                // As the index was before: FTS5's own automerge, in the commits.
                try index
                    .onWriterAndWait {
                        try $0.execute("INSERT INTO photo_text (photo_text, rank) VALUES ('automerge', 4)")
                    }
            } else {
                await index.mergeText()
            }
            try arms.append(Arm(name: name, index: index))
        }
        defer {
            for arm in arms {
                arm.index.closeAndWait()
            }
        }
        let ids = try await arms[0].index.read { reader in
            try reader.database.prepare("SELECT id FROM photos ORDER BY id").map { $0.int64(at: 0) }
        }
        var generator = SystemRandomNumberGenerator()
        var spread = ids
        spread.shuffle(using: &generator)
        Self.report("\(ids.count) photos, load \(Self.load)")

        for arm in arms {
            try await arm.search(after: 0)
        }
        for start in stride(from: 0, to: Self.keywordBatches, by: 10) {
            for arm in arms {
                arm.waits += try await Self.probing(arm.index) {
                    for batch in start ..< start + 10 {
                        let photos = spread[batch * Self.batchSize ..< (batch + 1) * Self.batchSize].sorted()
                        try await arm.batch { try $0.addKeyword("Bench/Batch \(batch)", toPhotos: photos) }
                    }
                }
                try await arm.search(after: (start + 10) * Self.batchSize)
            }
        }
        Self.report("load \(Self.load)")
        for arm in arms {
            arm.reportPhase("keyword batches")
        }

        // New photos, in folders of 200 under a root of their own.
        for arm in arms {
            let made = try await arm.index.write { writer -> (Int64, [Int64], [Int64]) in
                let volume = try writer.upsertVolume(VolumeRecord(uuid: "BENCH", kind: .ssd))
                let root = try writer.upsertRoot(RootRecord(volume: volume, path: "/Volumes/Bench/New"))
                return try (
                    root, SyntheticIndexPhotos.cameras.map { try writer.cameraID(for: $0) },
                    SyntheticIndexPhotos.lenses.map { try writer.lensID(for: $0) },
                )
            }
            arm.newPhotos = (made.0, SyntheticIndexPhotos(seed: 2026, cameraIDs: made.1, lensIDs: made.2))
        }
        for start in stride(from: 0, to: Self.indexingBatches, by: 10) {
            for arm in arms {
                arm.waits += try await Self.probing(arm.index) {
                    for batch in start ..< start + 10 {
                        guard let (root, made) = arm.newPhotos else { return }
                        var maker = made
                        let records = (0 ..< Self.batchSize).map { offset in
                            maker.photo(batch * Self.batchSize + offset, in: 0)
                        }
                        arm.newPhotos = (root, maker)
                        try await arm.batch { writer in
                            var folders: [Int: Int64] = [:]
                            let photos = try records.enumerated().map { offset, record -> PhotoRecord in
                                let number = (batch * Self.batchSize + offset) / 200
                                if folders[number] == nil {
                                    folders[number] = try writer.upsertFolder(FolderRecord(
                                        root: root, path: "/Volumes/Bench/New/Job \(number)",
                                    ))
                                }
                                var photo = record
                                photo.folder = folders[number] ?? 0
                                return photo
                            }
                            try writer.upsertPhotos(photos)
                        }
                    }
                }
                try await arm.search(after: ids.count + (start + 10) * Self.batchSize)
            }
        }
        Self.report("load \(Self.load)")
        for arm in arms {
            arm.reportPhase("indexing batches")
        }
        let started = ContinuousClock.now
        await arms[1].index.mergeText()
        Self.report("in steps: merged after its last batch in \(Self.milliseconds(ContinuousClock.now - started)) ms")
        for arm in arms {
            try await arm.search(after: ids.count + Self.indexingBatches * Self.batchSize)
            arm.reportPhase("at the end")
        }
    }
}
