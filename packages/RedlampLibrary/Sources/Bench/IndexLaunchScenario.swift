import Foundation

/// Opens an index of the fixture again with nothing changed and reconciles it with the disk through
/// the simulated volume, as a launch does when the volume's event history can't be replayed: every
/// folder listed and compared by signature, and nothing read. The library is up to date within the
/// design's launch budget, 1 s.
public struct IndexLaunchScenario: BenchScenario {
    public let name = "warm-launch"

    public init() {}

    public func run(_ context: BenchContext) async throws -> [BenchResult] {
        let folder = try IndexingScenario.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Index.sqlite")
        try await IndexingScenario.build([context.fixture], at: url)

        let clock = ContinuousClock()
        let started = clock.now
        let index = try await LibraryIndex.open(at: url)
        let opened = clock.now - started
        let indexer = LibraryIndexer(index: index, fileSystem: context.fileSystem())
        let run = await IndexingScenario.timed(indexer.index([context.fixture]))
        let elapsed = clock.now - started
        await index.close()
        let summary = run.summary
        let changed = summary.photosInserted + summary.photosUpdated + summary.photosMoved + summary.photosRemoved
        return [
            BenchResult(
                scenario: name, id: "library-launch", name: "Opened and reconciled, nothing changed",
                value: elapsed.seconds * 1000, unit: "ms", budget: .below(1000, "ms"),
            ),
            BenchResult(
                scenario: name, id: "library-launch-open", name: "Index opened", value: opened.seconds * 1000,
                unit: "ms",
            ),
            BenchResult(
                scenario: name, id: "library-launch-listed", name: "Folders listed",
                value: Double(summary.foldersListed),
                unit: "folders", budget: .exactly(Double(context.manifest.totals.folders + 1), "folders"),
            ),
            BenchResult(
                scenario: name, id: "library-launch-read", name: "Photos read again", value: Double(summary.headsRead),
                unit: "photos", budget: .exactly(0, "photos"),
            ),
            BenchResult(
                scenario: name, id: "library-launch-changed", name: "Photos whose rows changed", value: Double(changed),
                unit: "photos", budget: .exactly(0, "photos"),
            ),
        ]
    }
}
