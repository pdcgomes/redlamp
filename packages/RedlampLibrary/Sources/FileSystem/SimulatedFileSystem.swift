import Foundation
import Synchronization

/// A volume as slow as `profile` says. Each operation runs on `base`, so its listings and bytes
/// are the real ones, and then waits on `clock` until the simulated volume would have answered.
/// Its writes can be made to fail, folders put on volumes of their own and the Trash kept in a
/// folder (`SimulatedFileSystem+Writing.swift`).
public final class SimulatedFileSystem: LibraryFileSystem {
    /// What a listing moves for each entry: a name and its attributes, as a network file
    /// system's directory reply carries them.
    static let entryBytes = 128

    public let base: any LibraryFileSystem
    public let profile: VolumeProfile
    private let clock: any SimulationClock
    private let model: Mutex<VolumeModel>
    let writing = Mutex(WriteState())

    public init(
        base: any LibraryFileSystem = LocalFileSystem(), profile: VolumeProfile, seed: UInt64 = 0,
        clock: any SimulationClock = SystemClock(),
    ) {
        self.base = base
        self.profile = profile
        self.clock = clock
        model = Mutex(VolumeModel(profile: profile, seed: seed))
    }

    /// Operations made so far, failed ones included.
    public var operations: Int {
        model.withLock { $0.operations }
    }

    public func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        try simulate(url, bytes: { $0.count * Self.entryBytes }) { try base.contentsOfDirectory(at: url) }
    }

    public func attributes(of url: URL) throws -> FileEntry {
        try simulate(url, bytes: { _ in Self.entryBytes }) { try base.attributes(of: url) }
    }

    public func read(_ url: URL, range: Range<Int>) throws -> Data {
        try simulate(url, bytes: \.count) { try base.read(url, range: range) }
    }

    public func volume(of url: URL) throws -> VolumeInfo {
        let info = try simulate(url, bytes: { _ in 0 }) { try base.volume(of: url) }
        if let mounted = mount(of: url) {
            return VolumeInfo(
                uuid: mounted.uuid, name: mounted.name,
                isLocal: profile.isLocal ?? info.isLocal, isInternal: profile.isInternal ?? info.isInternal,
            )
        }
        return VolumeInfo(
            uuid: info.uuid, name: info.name,
            isLocal: profile.isLocal ?? info.isLocal, isInternal: profile.isInternal ?? info.isInternal,
        )
    }

    /// Runs `operation`, then waits for the volume as though the operation reached it only then,
    /// so the volume's time comes on top of the time of the disk underneath. An operation that
    /// fails on `base` costs the volume's time too; one made after the volume has gone fails
    /// however `base` answered.
    func simulate<T>(_ url: URL, bytes: (T) -> Int, _ operation: () throws -> T) throws -> T {
        let result = Result(catching: operation)
        let arrived = clock.now
        let size = (try? result.get()).map(bytes) ?? 0
        let outcome = model.withLock { $0.schedule(url.path, bytes: size, arriving: arrived) }
        clock.sleep(until: outcome.at)
        switch outcome.failure {
        case nil: return try result.get()
        case .unreachable: throw LibraryFileSystemError.unreachable(url)
        case .timeout: throw LibraryFileSystemError.timedOut(url)
        }
    }
}

/// A simulated volume's arithmetic: when each operation finishes, from when it arrived, which
/// file it's for and how many bytes it moves. Operations are served in the order they're
/// scheduled: each takes the place in flight that frees first, then waits its latency (and a
/// seek, when it moves to another file), then its bytes queue for the volume's bandwidth.
struct VolumeModel: Sendable {
    /// When an operation returns, and why it fails, if the volume has gone.
    struct Outcome: Equatable, Sendable {
        var at: Duration
        var failure: VolumeProfile.Disconnect.Failure?
    }

    let profile: VolumeProfile
    private var random: SeededRandom
    private(set) var operations = 0
    /// When each place in flight is next free; empty when the volume has no limit.
    private var places: [Duration]
    /// When the volume's bandwidth is next free.
    private var transferring: Duration = .zero
    private var lastFile: String?

    init(profile: VolumeProfile, seed: UInt64) {
        self.profile = profile
        random = SeededRandom(seed: seed)
        places = Array(repeating: .zero, count: profile.maxInFlight ?? 0)
    }

    mutating func schedule(_ file: String, bytes: Int, arriving now: Duration) -> Outcome {
        operations += 1
        let latency = jittered(profile.latency)
        let place = places.indices.min { places[$0] < places[$1] }
        let start = place.map { max(now, places[$0]) } ?? now
        let seek = profile.seek > .zero && file != lastFile ? profile.seek : .zero
        var finish = start + seek + latency
        var transferring = transferring
        if let bandwidth = profile.bandwidth, bytes > 0 {
            finish = max(finish, transferring) + .seconds(Double(bytes) / bandwidth)
            transferring = finish
        }
        if let disconnect = profile.disconnect {
            switch disconnect.trigger {
            case let .afterOperations(count) where operations > count:
                return failed(disconnect.failure, arriving: now, gone: now)
            case let .after(time) where finish > time:
                return failed(disconnect.failure, arriving: now, gone: max(now, time))
            default:
                break
            }
        }
        if let place {
            places[place] = finish
        }
        self.transferring = transferring
        lastFile = file
        return Outcome(at: finish)
    }

    /// An operation on a volume that has gone fails when it's gone, or after its timeout.
    private func failed(
        _ failure: VolumeProfile.Disconnect.Failure, arriving now: Duration, gone: Duration,
    ) -> Outcome {
        switch failure {
        case .unreachable: Outcome(at: gone, failure: failure)
        case let .timeout(limit): Outcome(at: max(now + limit, gone), failure: failure)
        }
    }

    private mutating func jittered(_ latency: Duration) -> Duration {
        guard profile.jitter > 0, latency > .zero else { return latency }
        let sigma = profile.jitter
        return latency * exp(sigma * random.normal() - sigma * sigma / 2)
    }
}

/// The time a simulated volume keeps, and how it waits.
public protocol SimulationClock: Sendable {
    /// Time since the clock started.
    var now: Duration { get }
    /// Blocks the calling thread until `now` reaches `deadline`.
    func sleep(until deadline: Duration)
}

/// Real time: a simulated volume's waits are real sleeps, so what's measured through it is what
/// the volume would cost.
public struct SystemClock: SimulationClock {
    private let origin = ContinuousClock.now

    public init() {}

    public var now: Duration {
        ContinuousClock.now - origin
    }

    public func sleep(until deadline: Duration) {
        let remaining = deadline - now
        guard remaining > .zero else { return }
        let (seconds, attoseconds) = remaining.components
        var request = timespec(tv_sec: Int(seconds), tv_nsec: Int(attoseconds / 1_000_000_000))
        var left = timespec()
        while nanosleep(&request, &left) == -1, errno == EINTR {
            request = left
        }
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
