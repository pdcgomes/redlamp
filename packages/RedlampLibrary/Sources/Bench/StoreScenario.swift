import Foundation
import RedlampDocument
import Synchronization

public extension BenchScenarios {
    /// Adds the store's scenario (LIB-09) after the others, for `photos` keys of `payloadBytes`
    /// each, in a store under `root` (the temporary folder by default).
    static func registerStore(
        photos: Int = StoreScenario.defaultPhotos, payloadBytes: Int = StoreScenario.defaultPayloadBytes,
        root: URL? = nil,
    ) {
        register(StoreScenario(photos: photos, payloadBytes: payloadBytes, root: root))
    }
}

/// Stores a grid thumbnail for each of `photos` synthetic content keys in a new store, from as many
/// writers as there are performance cores (as the indexer does), then opens the store again and
/// reads random keys back, one at a time and from every core: writes and reads a second, the
/// slowest reads, and what the store takes in memory and on disk. The payloads are random bytes,
/// `payloadBytes` long. Every read must come back whole: the folders design measured 6,210 random
/// reads a second from its packs, so 2,000 is the floor, and the 99th percentile read is under a
/// millisecond. The store is on the Mac's own disk, so the fixture's volume doesn't matter.
public struct StoreScenario: BenchScenario {
    public static let defaultPhotos = 100_000
    /// A JPEG grid thumbnail's mean size, on the CC0 raws' previews.
    public static let defaultPayloadBytes = 22 * 1024
    /// Reads timed one at a time, at most.
    static let reads = 100_000

    public let name = "store"
    public let photos: Int
    public let payloadBytes: Int
    public let root: URL?

    public init(
        photos: Int = StoreScenario.defaultPhotos, payloadBytes: Int = StoreScenario.defaultPayloadBytes,
        root: URL? = nil,
    ) {
        self.photos = max(photos, 1)
        self.payloadBytes = max(payloadBytes, 1)
        self.root = root
    }

    public func run(_: BenchContext) async throws -> [BenchResult] {
        try measure()
    }

    public func measure() throws -> [BenchResult] {
        let folder = (root ?? FileManager.default.temporaryDirectory)
            .appending(path: "redlamp-bench-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var random = SeededRandom(seed: 2026)
        let keys = (0 ..< photos).map { _ in
            ContentKey(data: withUnsafeBytes(of: (random.next(), random.next())) { Data($0) })!
        }
        let pool = Data((0 ..< (payloadBytes + 64 * 1024)).map { _ in UInt8(truncatingIfNeeded: random.next()) })
        let payloadBytes = payloadBytes
        let payload = { @Sendable (index: Int) in
            pool[(index * 61) % (64 * 1024) ..< (index * 61) % (64 * 1024) + payloadBytes]
        }
        let writers = CoreCounts.performance
        let modified = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let clock = ContinuousClock()

        let store = PhotoStore(root: folder)
        let failedWrites = Atomic(0)
        let writing = clock.now
        DispatchQueue.concurrentPerform(iterations: writers) { writer in
            for index in stride(from: writer, to: keys.count, by: writers) where !store.store(
                payload(index), for: keys[index], tier: .grid, size: Int64(payloadBytes), modified: modified,
            ) {
                failedWrites.add(1, ordering: .relaxed)
            }
        }
        let written = clock.now - writing
        let closing = clock.now
        store.close()
        let closed = clock.now - closing

        let reopened = PhotoStore(root: folder)
        let opening = clock.now
        reopened.open()
        let opened = clock.now - opening
        let statistics = reopened.statistics()

        var order = SeededRandom(seed: 7)
        let sample = (0 ..< min(Self.reads, keys.count)).map { _ in order.int(below: keys.count) }
        var durations: [Duration] = []
        durations.reserveCapacity(sample.count)
        var failedReads = 0
        let reading = clock.now
        for index in sample {
            let started = clock.now
            let data = reopened.data(for: keys[index], tier: .grid)
            durations.append(clock.now - started)
            if data != payload(index) {
                failedReads += 1
            }
        }
        let read = clock.now - reading
        var lookups: [Duration] = []
        lookups.reserveCapacity(sample.count)
        for index in sample {
            let started = clock.now
            _ = reopened.contains(keys[index], tier: .grid)
            lookups.append(clock.now - started)
        }
        let concurrentReads = sample.count * 4
        let concurrentStart = clock.now
        DispatchQueue.concurrentPerform(iterations: writers) { reader in
            for step in stride(from: reader, to: concurrentReads, by: writers) {
                _ = reopened.data(for: keys[sample[step % sample.count]], tier: .grid)
            }
        }
        let concurrent = clock.now - concurrentStart
        reopened.close()

        let mb = { (bytes: Int64) in Double(bytes) / 1_000_000 }
        let packs = Self.bytes(in: folder, withExtension: PhotoStore.packExtension)
        let indexes = Self.bytes(in: folder, withExtension: PhotoStore.indexExtension)
        return [
            BenchResult(
                scenario: name, id: "library-store-write-rate",
                name: "\(BenchResult.grouped(photos)) records of \(BenchResult.grouped(payloadBytes)) bytes stored, "
                    + "\(writers) writers, a second",
                value: Double(photos) / max(written.seconds, 1e-9), unit: "records/s",
            ),
            BenchResult(
                scenario: name, id: "library-store-write-failures", name: "Records that weren't stored",
                value: Double(failedWrites.load(ordering: .relaxed)), unit: "records", budget: .exactly(0, "records"),
            ),
            BenchResult(
                scenario: name, id: "library-store-close", name: "Closed: index files written",
                value: closed.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-store-open", name: "Opened again: every shard's table read",
                value: opened.seconds * 1000, unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-store-read-rate", name: "Random reads, one at a time, a second",
                value: Double(sample.count) / max(read.seconds, 1e-9), unit: "reads/s",
                budget: .atLeast(2000, "reads/s"),
            ),
            BenchResult(
                scenario: name, id: "library-store-read-p50", name: "Random read, p50",
                value: QueryScenario.percentile(durations, 0.5) * 1000, unit: "µs",
            ),
            BenchResult(
                scenario: name, id: "library-store-read-p99", name: "Random read, p99",
                value: QueryScenario.percentile(durations, 0.99) * 1000, unit: "µs", budget: .below(1000, "µs"),
            ),
            BenchResult(
                scenario: name, id: "library-store-read-failures", name: "Reads that didn't return their record",
                value: Double(failedReads), unit: "reads", budget: .exactly(0, "reads"),
            ),
            BenchResult(
                scenario: name, id: "library-store-lookup-p99", name: "Lookup without reading, p99",
                value: QueryScenario.percentile(lookups, 0.99) * 1000, unit: "µs",
            ),
            BenchResult(
                scenario: name, id: "library-store-concurrent-read-rate",
                name: "Random reads from \(writers) readers, a second",
                value: Double(concurrentReads) / max(concurrent.seconds, 1e-9), unit: "reads/s",
            ),
            BenchResult(
                scenario: name, id: "library-store-table", name: "Tables in memory, a record",
                value: statistics.tableBytesPerRecord, unit: "bytes",
            ),
            BenchResult(
                scenario: name, id: "library-store-packs", name: "Packs on disk", value: mb(packs), unit: "MB",
            ),
            BenchResult(
                scenario: name, id: "library-store-indexes", name: "Index files on disk", value: mb(indexes),
                unit: "MB",
            ),
        ]
    }

    private static func bytes(in folder: URL, withExtension pathExtension: String) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey],
        )) ?? []
        return files.filter { $0.pathExtension == pathExtension }.reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }
}
