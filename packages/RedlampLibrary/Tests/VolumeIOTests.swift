import Foundation
import RedlampDocument
import Synchronization
import Testing
@testable import RedlampLibrary

/// The readers of a volume: how wide they settle on each kind of volume, measured on simulated time,
/// and how they give up on one that stops answering.
struct VolumeIOTests {
    /// The width readers settle at on `profile`, each operation moving `bytes`: operations are issued
    /// as fast as the width allows, as the indexer does, and finish when the volume's model says,
    /// with time moving only from one finish to the next.
    static func settle(
        on profile: VolumeProfile, bytes: Int, initial: Int, operations: Int = 6000, waited: Bool = true,
    ) -> (concurrency: VolumeConcurrency, widths: [Int]) {
        settle(on: profile, sizes: { _ in bytes }, initial: initial, operations: operations, waited: waited)
    }

    /// As `settle(on:bytes:…)`, with operation `n` moving `sizes(n)` bytes.
    static func settle(
        on profile: VolumeProfile, sizes: (Int) -> Int, initial: Int, operations: Int, waited: Bool = true,
    ) -> (concurrency: VolumeConcurrency, widths: [Int]) {
        var model = VolumeModel(profile: profile, seed: 3)
        var concurrency = VolumeConcurrency(initial: initial, range: 1 ... 16)
        struct Operation {
            let start: Duration, end: Duration, generation: Int, bytes: Int
        }
        var inFlight: [Operation] = []
        var now = Duration.zero
        var issued = 0
        var widths: [Int] = []
        while issued < operations || !inFlight.isEmpty {
            while inFlight.count < concurrency.width, issued < operations {
                let bytes = sizes(issued)
                let outcome = model.schedule("/IMG_\(issued).JPG", bytes: bytes, arriving: now)
                inFlight.append(Operation(
                    start: now,
                    end: outcome.at,
                    generation: concurrency.generation,
                    bytes: bytes,
                ))
                issued += 1
            }
            let next = inFlight.indices.min { inFlight[$0].end < inFlight[$1].end }!
            let done = inFlight.remove(at: next)
            now = done.end
            concurrency.record(
                generation: done.generation,
                start: done.start,
                end: done.end,
                bytes: done.bytes,
                waited: waited,
            )
            if widths.last != concurrency.width {
                widths.append(concurrency.width)
            }
        }
        return (concurrency, widths)
    }

    @Test func `readers start at the width their kind of volume serves`() {
        let network = VolumeInfo(uuid: "N", name: nil, isLocal: false, isInternal: false)
        let onBoard = VolumeInfo(uuid: "I", name: nil, isLocal: true, isInternal: true)
        let external = VolumeInfo(uuid: "E", name: nil, isLocal: true, isInternal: false)
        #expect(VolumeIO.initialWidth(for: network) == 4)
        #expect(VolumeIO.initialWidth(for: onBoard) == CoreCounts.performance)
        #expect(VolumeIO.initialWidth(for: external) == 2)
        let io = VolumeIO(volume: network, fileSystem: LocalFileSystem(), probe: URL(fileURLWithPath: "/"))
        #expect(io.width == min(4, CoreCounts.performance) && io.throughput == 0 && io.isReachable)
    }

    @Test func `on a spinning disk the readers narrow, since another reader only queues behind the head`() throws {
        let (concurrency, widths) = Self.settle(on: .spinning, bytes: 256 * 1024, initial: 2)
        #expect(concurrency.width <= 2, "\(widths)")
        #expect(widths.allSatisfy { $0 <= 3 }, "\(widths)")
        // One head, a seek and 1.6 ms of bytes per file: about 100 reads a second, however many wait.
        let throughput = try #require(concurrency.last).operationsPerSecond
        #expect((90 ... 110).contains(throughput), "\(throughput)")
    }

    @Test func `on a NAS small reads widen the readers while throughput rises`() {
        let (concurrency, widths) = Self.settle(on: .nas, bytes: 1500, initial: 4, operations: 40000)
        #expect(concurrency.width >= 12, "\(widths)")
        #expect(Array(widths.prefix(13)) == Array(4 ... 16), "\(widths)")
    }

    @Test func `when bandwidth is the limit, readers added only add latency and are taken away`() throws {
        let (concurrency, widths) = Self.settle(on: .nas, bytes: 256 * 1024, initial: 4)
        #expect((1 ... 3).contains(concurrency.width), "\(widths)")
        #expect(widths.allSatisfy { $0 <= 5 }, "\(widths)")
        let throughput = try #require(concurrency.last).throughput
        #expect(throughput > 0.7 * 110_000_000, "\(throughput)")
    }

    @Test func `stretches of larger files don't narrow the readers of a volume that serves them side by side`() {
        // Raws' heads after small JPEGs, as a library's folders go: bytes a second jump with each
        // stretch whatever the width, but each read's latency doesn't grow with the width.
        let parallel = VolumeProfile(name: "parallel", latency: .milliseconds(1), jitter: 0.3, maxInFlight: 32)
        let (concurrency, widths) = Self.settle(
            on: parallel, sizes: { ($0 / 300) % 3 == 2 ? 256 * 1024 : 40000 }, initial: 2, operations: 30000,
        )
        #expect(concurrency.width >= 12, "\(widths)")
        #expect(widths.drop { $0 < 12 }.allSatisfy { $0 >= 10 }, "\(widths)")
    }

    @Test func `when operations don't wait for a place, the volume isn't the limit and the width stays`() {
        let (concurrency, widths) = Self.settle(on: .spinning, bytes: 256 * 1024, initial: 2, waited: false)
        #expect(concurrency.width == 2 && widths == [2])
        #expect(concurrency.throughput > 0)
    }

    @Test func `widths stay between one and the performance cores`() {
        var concurrency = VolumeConcurrency(initial: 40, range: 1 ... 16)
        #expect(concurrency.width == 16)
        concurrency = VolumeConcurrency(initial: 0, range: 1 ... 16)
        #expect(concurrency.width == 1)
        let (wide, _) = Self.settle(on: .ssd, bytes: 1500, initial: 16, operations: 20000)
        #expect(wide.width == 16)
    }

    // MARK: - Real operations

    /// A file system whose reads wait at a gate until the test opens it, and then answer.
    final class GatedFileSystem: LibraryFileSystem {
        let gate = IndexGate()
        let closed = Mutex(true)

        func contentsOfDirectory(at _: URL) throws -> [FileEntry] {
            []
        }

        func attributes(of url: URL) throws -> FileEntry {
            if closed.withLock({ $0 }) {
                throw LibraryFileSystemError.unreachable(url)
            }
            return FileEntry(name: url.lastPathComponent, isDirectory: true)
        }

        func read(_: URL, range: Range<Int>) throws -> Data {
            if closed.withLock({ $0 }) {
                gate.wait()
            }
            return Data(count: range.count)
        }

        func volume(of _: URL) throws -> VolumeInfo {
            VolumeInfo(uuid: "GATED", name: nil, isLocal: false, isInternal: false)
        }

        func open() {
            closed.withLock { $0 = false }
            for _ in 0 ..< 8 {
                gate.open()
            }
        }
    }

    /// A file system whose reads each take `delay`.
    final class SlowFileSystem: LibraryFileSystem {
        let delay: Duration

        init(delay: Duration) {
            self.delay = delay
        }

        func contentsOfDirectory(at _: URL) throws -> [FileEntry] {
            []
        }

        func attributes(of url: URL) throws -> FileEntry {
            FileEntry(name: url.lastPathComponent)
        }

        func read(_: URL, range: Range<Int>) throws -> Data {
            Thread.sleep(forTimeInterval: delay.seconds)
            return Data(count: range.count)
        }

        func volume(of _: URL) throws -> VolumeInfo {
            VolumeInfo(uuid: "SLOW", name: nil, isLocal: true, isInternal: false)
        }
    }

    @Test func `waiting for a place doesn't count towards the timeout, so a slow volume that answers isn't gone`(
    ) async throws {
        let fileSystem = SlowFileSystem(delay: .milliseconds(30))
        let probe = URL(fileURLWithPath: "/Volumes/Slow")
        let io = try VolumeIO(
            volume: fileSystem.volume(of: probe), fileSystem: fileSystem, probe: probe, timeout: .milliseconds(300),
            maximumWidth: 1,
        )
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0 ..< 12 {
                group.addTask { try await io.read(probe.appending(path: "IMG_\(index).JPG"), range: 0 ..< 100).count }
            }
            for try await count in group {
                #expect(count == 100)
            }
        }
        let statistics = io.statistics
        #expect(statistics.timeouts == 0 && statistics.isReachable)
        #expect(statistics.longestWait > .milliseconds(300), "\(statistics.longestWait)")
        #expect(statistics.longestOperation < .milliseconds(300), "\(statistics.longestOperation)")
    }

    @Test func `an operation that outlives its timeout on a volume that still answers goes on, and the volume stays`(
    ) async throws {
        let fileSystem = SlowFileSystem(delay: .milliseconds(600))
        let probe = URL(fileURLWithPath: "/Volumes/Slow")
        let io = try VolumeIO(
            volume: fileSystem.volume(of: probe), fileSystem: fileSystem, probe: probe, timeout: .milliseconds(100),
        )
        let changes = io.reachabilityChanges()
        let seen = Mutex<[Bool]>([])
        let watching = Task {
            for await reachable in changes {
                seen.withLock { $0.append(reachable) }
            }
        }
        #expect(try await io.read(probe.appending(path: "IMG_0001.JPG"), range: 0 ..< 100).count == 100)
        watching.cancel()
        let statistics = io.statistics
        #expect(statistics.timeouts == 0 && statistics.isReachable && seen.withLock { $0 }.isEmpty)
        #expect(statistics.longestOperation >= .milliseconds(600), "\(statistics.longestOperation)")
        #expect(statistics.longestUnanswered == .zero)
    }

    @Test func `an operation still going after thirty timeouts on a volume that answers fails alone`() async throws {
        let fileSystem = SlowFileSystem(delay: .seconds(5))
        let probe = URL(fileURLWithPath: "/Volumes/Slow")
        let io = try VolumeIO(
            volume: fileSystem.volume(of: probe), fileSystem: fileSystem, probe: probe, timeout: .milliseconds(30),
        )
        let file = probe.appending(path: "IMG_0001.JPG")
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: VolumeOperationTimedOut(url: file)) {
            try await io.read(file, range: 0 ..< 100)
        }
        let waited = clock.now - started
        #expect(waited >= io.operationLimit && waited < .seconds(4), "\(waited)")
        let statistics = io.statistics
        #expect(statistics.isReachable && statistics.timeouts == 1 && statistics.longestUnanswered == .zero)
        #expect(try await io.attributes(of: file).name == "IMG_0001.JPG")
    }

    /// A file system whose reads hang until released, then fail as a network that stopped answering,
    /// and which doesn't answer the first time it's asked about a folder: a volume that goes and
    /// comes back while a read hangs.
    final class HangingFileSystem: LibraryFileSystem {
        let gate = IndexGate()
        private let asked = Mutex(0)

        func contentsOfDirectory(at _: URL) throws -> [FileEntry] {
            []
        }

        func attributes(of url: URL) throws -> FileEntry {
            let first = asked.withLock { asked in
                asked += 1
                return asked == 1
            }
            if first {
                throw LibraryFileSystemError.unreachable(url)
            }
            return FileEntry(name: url.lastPathComponent, isDirectory: true)
        }

        func read(_ url: URL, range _: Range<Int>) throws -> Data {
            gate.wait()
            throw LibraryFileSystemError.timedOut(url)
        }

        func volume(of _: URL) throws -> VolumeInfo {
            VolumeInfo(uuid: "HANGING", name: nil, isLocal: false, isInternal: false)
        }
    }

    @Test func `an operation given up on that fails later doesn't take away a volume that's back`() async throws {
        let fileSystem = HangingFileSystem()
        let probe = URL(fileURLWithPath: "/Volumes/Hanging")
        let io = try VolumeIO(
            volume: fileSystem.volume(of: probe), fileSystem: fileSystem, probe: probe, timeout: .milliseconds(100),
            probeIntervals: .milliseconds(20) ... .milliseconds(40),
        )
        let file = probe.appending(path: "IMG_0001.JPG")
        await #expect(throws: LibraryFileSystemError.timedOut(file)) {
            try await io.read(file, range: 0 ..< 10)
        }
        await io.waitUntilReachable()
        let seen = Mutex<[Bool]>([])
        let changes = io.reachabilityChanges()
        let watching = Task {
            for await reachable in changes {
                seen.withLock { $0.append(reachable) }
            }
        }
        fileSystem.gate.open()
        try await Task.sleep(for: .milliseconds(200))
        watching.cancel()
        #expect(seen.withLock { $0 }.isEmpty && io.isReachable)
        #expect(io.statistics.timeouts == 1)
    }

    @Test func `reads go through the volume's file system, and are counted`() async throws {
        let folder = try TemporaryFolder()
        try folder.write("IMG_0001.JPG", bytes: 3000)
        let volume = VolumeInfo(uuid: "LOCAL", name: nil, isLocal: true, isInternal: true)
        let io = VolumeIO(volume: volume, fileSystem: LocalFileSystem(), probe: folder.url)
        let data = try await io.read(folder.url.appending(path: "IMG_0001.JPG"), range: 0 ..< 1000)
        #expect(data == Data((0 ..< 1000).map { UInt8($0 % 251) }))
        let entries = try await io.contentsOfDirectory(at: folder.url)
        #expect(entries.map(\.name) == ["IMG_0001.JPG"])
        let statistics = io.statistics
        #expect(statistics.operations == 2 && statistics.bytes == 1000 + SimulatedFileSystem.entryBytes)
        #expect(statistics.timeouts == 0 && statistics.isReachable)
        await #expect(throws: (any Error).self) {
            try await io.attributes(of: folder.url.appending(path: "missing.JPG"))
        }
        #expect(io.isReachable, "a missing file isn't a missing volume")
    }

    @Test func `a volume that stops answering times out its callers, fails the rest at once, and comes back`(
    ) async throws {
        let fileSystem = GatedFileSystem()
        let probe = URL(fileURLWithPath: "/Volumes/Gated")
        let io = try VolumeIO(
            volume: fileSystem.volume(of: probe), fileSystem: fileSystem, probe: probe,
            timeout: .seconds(1), probeIntervals: .milliseconds(20) ... .milliseconds(80),
        )
        let changes = io.reachabilityChanges()
        let file = probe.appending(path: "IMG_0001.JPG")
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: LibraryFileSystemError.timedOut(file)) {
            try await io.read(file, range: 0 ..< 10)
        }
        let waited = clock.now - started
        #expect(waited >= .seconds(1) && waited < .seconds(5), "\(waited)")
        #expect(!io.isReachable)
        let refused = clock.now
        await #expect(throws: LibraryFileSystemError.unreachable(file)) {
            try await io.read(file, range: 0 ..< 10)
        }
        #expect(clock.now - refused < .milliseconds(500))
        #expect(io.statistics.timeouts == 1 && io.statistics.longestWait < .seconds(5))

        fileSystem.open()
        var seen: [Bool] = []
        for await reachable in changes {
            seen.append(reachable)
            if reachable {
                break
            }
        }
        #expect(seen == [false, true])
        #expect(io.isReachable)
        #expect(try await io.read(file, range: 0 ..< 10).count == 10)
    }
}
