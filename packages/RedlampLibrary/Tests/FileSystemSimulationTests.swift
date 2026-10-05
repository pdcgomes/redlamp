import Foundation
import Synchronization
import Testing
@testable import RedlampLibrary

/// The simulated volumes' arithmetic, on a clock that moves only when it's told to.
struct FileSystemSimulationTests {
    @Test func `a spinning disk serves one operation at a time and seeks when the file changes`() {
        var model = VolumeModel(profile: .spinning, seed: 1)
        // 1.6 MB is 10 ms at 160 MB/s; each move to another file is an 8 ms seek.
        let first = model.schedule("/a", bytes: 1_600_000, arriving: .zero)
        let second = model.schedule("/b", bytes: 1_600_000, arriving: .zero)
        let sameFile = model.schedule("/b", bytes: 1_600_000, arriving: .zero)
        let later = model.schedule("/c", bytes: 0, arriving: .milliseconds(100))
        #expect(isAbout(milliseconds(first.at), 18))
        #expect(isAbout(milliseconds(second.at), 36))
        #expect(isAbout(milliseconds(sameFile.at), 46))
        #expect(isAbout(milliseconds(later.at), 108))
        #expect([first, second, sameFile, later].allSatisfy { $0.failure == nil })
    }

    @Test func `a NAS serves sixteen operations at once and queues the seventeenth`() {
        var model = VolumeModel(profile: .nas, seed: 1)
        let finishes = (0 ..< 17).map { model.schedule("/\($0)", bytes: 0, arriving: .zero).at }
        #expect(finishes.prefix(16).allSatisfy { isAbout(milliseconds($0), 0.8) })
        #expect(isAbout(milliseconds(finishes[16]), 1.6))
    }

    @Test func `operations in flight share the volume's bandwidth`() {
        var model = VolumeModel(profile: .nas, seed: 1)
        // 11 MB is 100 ms at 110 MB/s: together, the second arrives 100 ms after the first.
        let first = model.schedule("/a", bytes: 11_000_000, arriving: .zero)
        let second = model.schedule("/b", bytes: 11_000_000, arriving: .zero)
        #expect(isAbout(milliseconds(first.at), 100.8))
        #expect(isAbout(milliseconds(second.at), 200.8))
    }

    @Test func `jitter keeps the average latency and repeats with its seed`() {
        func latencies(seed: UInt64) -> [Double] {
            var model = VolumeModel(profile: .wifi, seed: seed)
            return (0 ..< 4000).map { index in
                let arrival = Duration.seconds(index)
                return milliseconds(model.schedule("/\(index)", bytes: 0, arriving: arrival).at - arrival)
            }
        }
        let wifi = latencies(seed: 7)
        let mean = wifi.reduce(0, +) / Double(wifi.count)
        #expect(abs(mean - 12) < 0.4)
        let within = wifi.count(where: { (6 ... 18).contains($0) })
        #expect(Double(within) / Double(wifi.count) > 0.6)
        #expect(wifi.contains { $0 < 6 } && wifi.contains { $0 > 18 })
        #expect(latencies(seed: 7) == wifi)
        #expect(latencies(seed: 8) != wifi)
    }

    @Test func `a volume that disconnects after some operations fails the ones after them`() {
        var model = VolumeModel(profile: .nas.disconnecting(.init(.afterOperations(3))), seed: 1)
        let outcomes = (0 ..< 5).map { model.schedule("/\($0)", bytes: 0, arriving: .milliseconds(10 * $0)) }
        #expect(outcomes.prefix(3).allSatisfy { $0.failure == nil })
        #expect(outcomes[3] == VolumeModel.Outcome(at: .milliseconds(30), failure: .unreachable))
        #expect(outcomes[4] == VolumeModel.Outcome(at: .milliseconds(40), failure: .unreachable))
    }

    @Test func `a volume that stops answering fails operations after their timeout, in flight or not`() {
        let gone = VolumeProfile.Disconnect(.after(.seconds(1)), failure: .timeout(.seconds(5)))
        var model = VolumeModel(profile: .vpn.disconnecting(gone), seed: 1)
        let before = model.schedule("/a", bytes: 0, arriving: .milliseconds(500))
        let inFlight = model.schedule("/b", bytes: 0, arriving: .milliseconds(990))
        let after = model.schedule("/c", bytes: 0, arriving: .seconds(2))
        #expect(before == VolumeModel.Outcome(at: .milliseconds(540)))
        #expect(inFlight == VolumeModel.Outcome(at: .milliseconds(5990), failure: .timeout(.seconds(5))))
        #expect(after == VolumeModel.Outcome(at: .seconds(7), failure: .timeout(.seconds(5))))
    }

    @Test func `a simulated volume answers with the real files after waiting on its clock`() throws {
        let folder = try TemporaryFolder()
        try folder.write("IMG_0001.JPG", bytes: 1000)
        try folder.write("IMG_0002.JPG", bytes: 2000)
        let clock = ManualClock()
        let volume = SimulatedFileSystem(profile: .vpn, seed: 1, clock: clock)

        let entries = try volume.contentsOfDirectory(at: folder.url)
        #expect(entries.map(\.name).sorted() == ["IMG_0001.JPG", "IMG_0002.JPG"])
        // 40 ms, then two entries' attributes at 5 MB/s.
        #expect(isAbout(milliseconds(clock.now), 40 + 2 * 128 / 5000))
        let bytes = try volume.read(folder.url.appending(path: "IMG_0002.JPG"), range: 0 ..< 1500)
        #expect(bytes == Data((0 ..< 1500).map { UInt8($0 % 251) }))
        #expect(isAbout(milliseconds(clock.now), 80 + 2 * 128 / 5000 + 1500.0 / 5000))
        #expect(volume.operations == 2)
    }

    @Test func `a volume's time comes on top of the time of the disk underneath`() throws {
        struct SlowDisk: LibraryFileSystem {
            let clock: ManualClock

            func contentsOfDirectory(at _: URL) throws -> [FileEntry] {
                wait()
                return [FileEntry(name: "IMG_0001.JPG")]
            }

            func attributes(of url: URL) throws -> FileEntry {
                wait()
                return FileEntry(name: url.lastPathComponent)
            }

            func read(_: URL, range _: Range<Int>) throws -> Data {
                wait()
                return Data(count: 11000)
            }

            func volume(of _: URL) throws -> VolumeInfo {
                VolumeInfo(uuid: nil, name: nil, isLocal: true, isInternal: true)
            }

            private func wait() {
                clock.sleep(until: clock.now + .milliseconds(5))
            }
        }
        let clock = ManualClock()
        let volume = SimulatedFileSystem(base: SlowDisk(clock: clock), profile: .nas, clock: clock)
        _ = try volume.read(URL(fileURLWithPath: "/IMG_0001.JPG"), range: 0 ..< 11000)
        // 5 ms on the disk, then 0.8 ms of latency and 11 KB at 110 MB/s.
        #expect(isAbout(milliseconds(clock.now), 5 + 0.8 + 0.1))
    }

    @Test func `a missing file costs the volume's time before it fails`() throws {
        let folder = try TemporaryFolder()
        let clock = ManualClock()
        let volume = SimulatedFileSystem(profile: .wifi, seed: 1, clock: clock)
        #expect(throws: (any Error).self) { try volume.attributes(of: folder.url.appending(path: "missing.JPG")) }
        #expect(clock.now > .milliseconds(1))
    }

    @Test func `a simulated volume that has gone throws unreachable, or times out`() throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "IMG_0001.JPG")
        try folder.write("IMG_0001.JPG", bytes: 10)

        let clock = ManualClock()
        let unplugged = SimulatedFileSystem(
            profile: .spinning.disconnecting(.init(.afterOperations(1))), seed: 1, clock: clock,
        )
        #expect(try unplugged.attributes(of: file).size == 10)
        #expect(throws: LibraryFileSystemError.unreachable(file)) { try unplugged.read(file, range: 0 ..< 10) }

        let hanging = SimulatedFileSystem(
            profile: .wifi.disconnecting(.init(.after(.zero), failure: .timeout(.seconds(30)))), seed: 1, clock: clock,
        )
        let started = clock.now
        #expect(throws: LibraryFileSystemError.timedOut(file)) { try hanging.read(file, range: 0 ..< 10) }
        #expect(clock.now - started == .seconds(30))
    }

    @Test func `a simulated volume reports itself as a network volume where the profile says so`() throws {
        let folder = try TemporaryFolder()
        let local = try LocalFileSystem().volume(of: folder.url)
        let nas = try SimulatedFileSystem(profile: .nas, clock: ManualClock()).volume(of: folder.url)
        let spinning = try SimulatedFileSystem(profile: .spinning, clock: ManualClock()).volume(of: folder.url)
        #expect(nas.uuid == local.uuid)
        #expect(!nas.isLocal && !nas.isInternal)
        #expect(spinning.isLocal == local.isLocal && !spinning.isInternal)
    }

    @Test func `waits are real sleeps, overlapping up to the volume's limit`() throws {
        let folder = try TemporaryFolder()
        try folder.write("IMG_0001.JPG", bytes: 10)
        let file = folder.url.appending(path: "IMG_0001.JPG")
        let profile = VolumeProfile(name: "slow", latency: .milliseconds(20), maxInFlight: 4)
        let volume = SimulatedFileSystem(profile: profile, seed: 1)
        let clock = ContinuousClock()
        let started = clock.now
        // Eight at once in four places: two rounds of 20 ms.
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            _ = try? volume.attributes(of: file)
        }
        let elapsed = milliseconds(clock.now - started)
        #expect(elapsed >= 40)
        #expect(elapsed < 140)
    }
}

func milliseconds(_ duration: Duration) -> Double {
    duration.seconds * 1000
}

/// Within a millionth of a millisecond: what converting between seconds and `Duration` loses.
func isAbout(_ value: Double, _ expected: Double) -> Bool {
    abs(value - expected) < 1e-6
}

/// Time that moves only when something waits on it: each wait jumps to its deadline.
final class ManualClock: SimulationClock {
    private let time = Mutex(Duration.zero)

    var now: Duration {
        time.withLock { $0 }
    }

    func sleep(until deadline: Duration) {
        time.withLock { $0 = max($0, deadline) }
    }
}

/// A folder removed when the test ends.
final class TemporaryFolder {
    let url: URL

    init(on volume: URL? = nil) throws {
        if let volume {
            url = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: volume, create: true,
            )
        } else {
            url = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// A file of `bytes` bytes counting up, wrapping at 251.
    func write(_ path: String, bytes: Int) throws {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0 ..< bytes).map { UInt8($0 % 251) }).write(to: file)
    }
}
