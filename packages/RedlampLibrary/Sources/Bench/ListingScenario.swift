import Foundation
import Synchronization

/// Lists every folder of the fixture through the simulated volume, as indexing and the folder
/// tree do, as many at once as the volume serves. On an SSD the photos must be listed at the
/// rate the folders design measured: 50,000 in under 300 ms
/// (docs/plans/2026-10-02-folders-design.md). Other volumes are measured without a budget.
public struct ListingScenario: BenchScenario {
    public let name = "listing"

    public init() {}

    public func run(_ context: BenchContext) async throws -> [BenchResult] {
        let found = Mutex((photos: 0, folders: 0))
        let clock = ContinuousClock()
        let started = clock.now
        try await FolderWalk
            .walk(context.fixture, fileSystem: context.fileSystem(), width: context.width) { _, entries in
                let photos = entries.count(where: FolderWalk.isPhoto)
                found.withLock {
                    $0.photos += photos
                    $0.folders += 1
                }
            }
        let elapsed = (clock.now - started).seconds
        let (photos, folders) = found.withLock { $0 }
        return [
            BenchResult(
                scenario: name, id: "library-list", name: "All \(BenchResult.grouped(photos)) photos listed",
                value: elapsed * 1000, unit: "ms",
                budget: context.profile == .ssd ? .below(300 * Double(photos) / 50000, "ms") : nil,
            ),
            BenchResult(
                scenario: name, id: "library-list-rate", name: "Photos listed a second",
                value: Double(photos) / max(elapsed, 1e-9), unit: "photos/s",
            ),
            BenchResult(
                scenario: name, id: "library-list-folders", name: "Folders listed, \(context.width) at once",
                value: Double(folders), unit: "folders",
            ),
        ]
    }
}
