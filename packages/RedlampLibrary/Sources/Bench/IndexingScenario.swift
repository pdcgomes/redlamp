import Foundation

public extension BenchScenarios {
    /// Adds indexing's and change detection's scenarios (LIB-07, LIB-08) after the others: a cold
    /// build, a warm launch, reconciling changes made while the library was closed, and a volume
    /// vanishing partway.
    static func registerIndexing() {
        let scenarios: [any BenchScenario] = [
            IndexBuildScenario(), IndexLaunchScenario(), ReconcileScenario(), VanishingVolumeScenario(),
        ]
        for scenario in scenarios {
            register(scenario)
        }
    }
}

/// What indexing's scenarios share: an index of their own on the Mac's disk, as the library keeps
/// it, and runs timed as their events come.
enum IndexingScenario {
    /// A folder of its own in the temporary folder, for an index.
    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-bench-index-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Indexes `roots` into a new index at `url` straight from the disk, as a scenario's starting
    /// point, and closes it.
    static func build(_ roots: [URL], at url: URL) async throws {
        let index = try await LibraryIndex.open(at: url)
        _ = await timed(LibraryIndexer(index: index).index(roots))
        await index.close()
    }

    /// A run, as its events came.
    struct Run {
        var summary = LibraryIndexerSummary()
        var elapsed = Duration.zero
        /// When the photos inserted reached `firstPhotos`, from the run's start.
        var first: Duration?
        var failures = 0
    }

    /// Follows `run` to its end, timing it from now.
    static func timed(_ run: AsyncStream<LibraryIndexerEvent>, firstPhotos: Int = 0) async -> Run {
        let clock = ContinuousClock()
        let started = clock.now
        var result = Run()
        var inserted = 0
        for await event in run {
            switch event {
            case let .photosInserted(ids):
                inserted += ids.count
                if result.first == nil, inserted >= firstPhotos {
                    result.first = clock.now - started
                }
            case .failed:
                result.failures += 1
            case let .finished(summary):
                result.summary = summary
            default:
                break
            }
        }
        result.elapsed = clock.now - started
        return result
    }

    /// Clones `source`, a folder, to `destination` on the same volume, falling back to copying.
    static func clone(_ source: URL, to destination: URL) throws {
        let cloned = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return false }
                return clonefile(from, to, 0) == 0
            }
        }
        if !cloned {
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    /// Waits for `io` to answer again, at most `limit`; returns whether it did.
    static func waitUntilReachable(_ io: VolumeIO, limit: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await io.waitUntilReachable()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
