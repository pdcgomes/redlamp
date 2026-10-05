import Foundation
import Synchronization

/// Indexes the fixture through a volume that stops answering partway, its operations hanging, and
/// then comes back: no caller waits much beyond the readers' timeout, the photos indexed before it
/// went are marked offline, and once it's back indexing resumes, reading only the photos it hadn't
/// written.
public struct VanishingVolumeScenario: BenchScenario {
    public let name = "vanishing-volume"
    /// The readers' timeout. Operations on the volume once it has gone hang for `hang`, then fail.
    static let timeout = Duration.seconds(1)
    static let hang = Duration.seconds(10)
    static let probeIntervals = Duration.milliseconds(100) ... Duration.seconds(1)

    public init() {}

    public func run(_ context: BenchContext) async throws -> [BenchResult] {
        let folder = try IndexingScenario.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = try await LibraryIndex.open(at: folder.appending(path: "Index.sqlite"))
        let total = context.manifest.totals.photos
        let gone = context.profile.disconnecting(.init(
            .afterOperations(max(total / 2, 1)),
            failure: .timeout(Self.hang),
        ))
        let volume = ReconnectingFileSystem(SimulatedFileSystem(profile: gone, seed: context.manifest.spec.seed))
        let volumes = VolumeIORegistry(fileSystem: volume, configuration: .init(
            timeout: Self.timeout, probeIntervals: Self.probeIntervals,
        ))
        let indexer = LibraryIndexer(index: index, volumes: volumes)
        let first = await IndexingScenario.timed(indexer.index([context.fixture]))
        let (written, offline) = try await index.read { try ($0.photoCount(), $0.photoCount(withState: .offline)) }
        let longestWait = volumes.all.map(\.statistics.longestWait).max() ?? .zero

        volume.reconnect(to: context.fileSystem())
        let clock = ContinuousClock()
        let reconnected = clock.now
        var back = true
        for io in volumes.all {
            back = await IndexingScenario.waitUntilReachable(io, limit: .seconds(30)) && back
        }
        let found = back ? clock.now - reconnected : .seconds(30)
        let second = await IndexingScenario.timed(indexer.index([context.fixture]))
        let (photos, stillOffline) = try await index.read {
            try ($0.photoCount(), $0.photoCount(withState: .offline))
        }
        await index.close()
        let timeout = Self.timeout.seconds * 1000
        return [
            BenchResult(
                scenario: name, id: "library-vanish-wait",
                name: "Longest wait for the volume, its timeout \(BenchResult.format(timeout, "ms"))",
                value: longestWait.seconds * 1000, unit: "ms", budget: .below(timeout * 1.25, "ms"),
            ),
            BenchResult(
                scenario: name, id: "library-vanish-run", name: "Indexing until the volume went",
                value: first.elapsed.seconds, unit: "s",
            ),
            BenchResult(
                scenario: name, id: "library-vanish-written", name: "Photos indexed before it went",
                value: Double(written), unit: "photos",
            ),
            BenchResult(
                scenario: name, id: "library-vanish-offline", name: "Of those, marked offline", value: Double(offline),
                unit: "photos", budget: .exactly(Double(written), "photos"),
            ),
            BenchResult(
                scenario: name, id: "library-vanish-back", name: "Volume found again once back",
                value: found.seconds * 1000, unit: "ms",
                budget: .below((Self.probeIntervals.upperBound + Self.timeout).seconds * 1000 * 1.5, "ms"),
            ),
            BenchResult(
                scenario: name, id: "library-vanish-reread", name: "Photos read once it was back",
                value: Double(second.summary.headsRead), unit: "photos", budget: .exactly(
                    Double(total - written),
                    "photos",
                ),
            ),
            BenchResult(
                scenario: name, id: "library-vanish-photos", name: "Photos in the index", value: Double(photos),
                unit: "photos", budget: .exactly(Double(total), "photos"),
            ),
            BenchResult(
                scenario: name, id: "library-vanish-online", name: "Photos still offline", value: Double(stillOffline),
                unit: "photos", budget: .exactly(0, "photos"),
            ),
        ]
    }
}

/// A volume that's one file system until it's reconnected to another: a volume that goes, then
/// comes back.
final class ReconnectingFileSystem: LibraryFileSystem {
    private let current: Mutex<any LibraryFileSystem>

    init(_ initial: any LibraryFileSystem) {
        current = Mutex(initial)
    }

    func reconnect(to fileSystem: any LibraryFileSystem) {
        current.withLock { $0 = fileSystem }
    }

    private var base: any LibraryFileSystem {
        current.withLock { $0 }
    }

    func contentsOfDirectory(at url: URL) throws -> [FileEntry] {
        try base.contentsOfDirectory(at: url)
    }

    func attributes(of url: URL) throws -> FileEntry {
        try base.attributes(of: url)
    }

    func read(_ url: URL, range: Range<Int>) throws -> Data {
        try base.read(url, range: range)
    }

    func volume(of url: URL) throws -> VolumeInfo {
        try base.volume(of: url)
    }
}
