import Dispatch
import Foundation
import RedlampDocument
import Synchronization

/// One set of readers per volume, by the volume's UUID, shared by the indexer and change tracking
/// so they agree on how wide each volume is and whether it's there.
public final class VolumeIORegistry: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// The longest an operation waits, from when it's asked for.
        public var timeout: Duration
        /// How long an unreachable volume waits before its first probe, doubling up to the last.
        public var probeIntervals: ClosedRange<Duration>
        public var maximumWidth: Int

        public init(
            timeout: Duration = .seconds(10), probeIntervals: ClosedRange<Duration> = .seconds(1) ... .seconds(30),
            maximumWidth: Int = CoreCounts.performance,
        ) {
            self.timeout = timeout
            self.probeIntervals = probeIntervals
            self.maximumWidth = maximumWidth
        }
    }

    public let fileSystem: any LibraryFileSystem
    public let configuration: Configuration
    private let clock: any SimulationClock
    private let readers = Mutex<[String: VolumeIO]>([:])

    public init(
        fileSystem: any LibraryFileSystem, configuration: Configuration = Configuration(),
        clock: any SimulationClock = SystemClock(),
    ) {
        self.fileSystem = fileSystem
        self.configuration = configuration
        self.clock = clock
    }

    /// The readers of `volume`, made the first time they're asked for, with `probe` (one of its
    /// roots) what's asked about while the volume is unreachable.
    public func io(for volume: VolumeInfo, probe: URL) -> VolumeIO {
        readers.withLock { readers in
            let key = Self.key(for: volume, probe: probe)
            if let io = readers[key] {
                return io
            }
            let io = VolumeIO(
                volume: volume, fileSystem: fileSystem, probe: probe, timeout: configuration.timeout,
                probeIntervals: configuration.probeIntervals, clock: clock, maximumWidth: configuration.maximumWidth,
            )
            readers[key] = io
            return io
        }
    }

    public var all: [VolumeIO] {
        readers.withLock { Array($0.values) }
    }

    /// The index's name for a volume: its UUID, or for a volume without one (some network shares)
    /// its name, or else the root it was found by.
    public static func key(for volume: VolumeInfo, probe: URL) -> String {
        volume.uuid ?? volume.name.map { "name:" + $0 } ?? "path:" + probe.path
    }

    /// `fileSystem.volume(of:)`, given up after the timeout: which volume `url` is on, asked before
    /// its readers are known.
    public func volume(of url: URL) async throws -> VolumeInfo {
        let fileSystem = fileSystem
        let timeout = configuration.timeout
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            let resume: @Sendable (Result<VolumeInfo, any Error>) -> Void = { result in
                guard resumed.withLock({ done in
                    defer { done = true }
                    return !done
                }) else { return }
                continuation.resume(with: result)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                resume(Result { try fileSystem.volume(of: url) })
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout.seconds) {
                resume(.failure(LibraryFileSystemError.timedOut(url)))
            }
        }
    }
}
