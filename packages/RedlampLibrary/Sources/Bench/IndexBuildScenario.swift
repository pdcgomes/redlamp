import Foundation

/// Indexes the fixture into a new index through the simulated volume, as adding a library's folders
/// does: how soon the first 1,000 photos are searchable (2 s at most: the design's first results
/// within seconds), how fast photos are indexed, and that every photo and folder of the manifest is
/// in the index.
public struct IndexBuildScenario: BenchScenario {
    public let name = "index-build"
    /// The photos the first results are counted to.
    static let first = 1000

    public init() {}

    public func run(_ context: BenchContext) async throws -> [BenchResult] {
        let folder = try IndexingScenario.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = try await LibraryIndex.open(at: folder.appending(path: "Index.sqlite"))
        let totals = context.manifest.totals
        let first = min(Self.first, totals.photos)
        let indexer = LibraryIndexer(index: index, fileSystem: context.fileSystem())
        let run = await IndexingScenario.timed(indexer.index([context.fixture]), firstPhotos: first)
        let (photos, folders) = try await index.read { try ($0.photoCount(), $0.folderCount()) }
        await index.close()
        let seconds = max(run.elapsed.seconds, 1e-9)
        return [
            BenchResult(
                scenario: name, id: "library-index-first",
                name: "First \(BenchResult.grouped(first)) photos searchable",
                value: (run.first ?? run.elapsed).seconds * 1000, unit: "ms", budget: .below(2000, "ms"),
            ),
            BenchResult(
                scenario: name, id: "library-index", name: "All \(BenchResult.grouped(totals.photos)) photos indexed",
                value: seconds, unit: "s",
            ),
            BenchResult(
                scenario: name, id: "library-index-rate", name: "Photos indexed a second",
                value: Double(photos) / seconds, unit: "photos/s",
            ),
            BenchResult(
                scenario: name, id: "library-index-photos", name: "Photos in the index", value: Double(photos),
                unit: "photos", budget: .exactly(Double(totals.photos), "photos"),
            ),
            BenchResult(
                scenario: name, id: "library-index-folders", name: "Folders in the index", value: Double(folders),
                unit: "folders", budget: .exactly(Double(totals.folders + 1), "folders"),
            ),
            BenchResult(
                scenario: name, id: "library-index-failures", name: "Photos and folders that failed",
                value: Double(run.failures), unit: "failures", budget: .exactly(0, "failures"),
            ),
        ]
    }
}
