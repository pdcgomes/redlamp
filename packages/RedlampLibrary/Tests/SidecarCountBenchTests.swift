import Foundation
import Testing
@testable import RedlampLibrary

/// Move Edits and Metadata…'s count as the first read of a launch (LIB-11): a copy of lib-1m's index split into a root
/// per top folder, as Folders would hold them, opened afresh for each count, at schema version 7, which counted
/// through `(folder, name)`, then once migrated to version 8, whose index of the photos with sidecars answers it; with
/// the migration's time at a million photos. Skipped unless `REDLAMP_SIDECAR_COUNT_BENCH=1`
/// (`TEST_RUNNER_REDLAMP_SIDECAR_COUNT_BENCH=1` through xcodebuild) and lib-1m's index is on this Mac.
struct SidecarCountBenchTests {
    private static func report(_ line: String) {
        print("SIDECAR-COUNT-BENCH \(line)")
    }

    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.2f ms", duration / .milliseconds(1))
    }

    /// Each root's count, the first read of a fresh index and the next, by root, `runs` times.
    private static func counts(
        at url: URL, migrations: [LibraryIndex.Migration], roots: [(id: Int64, name: String)], runs: Int,
    ) async throws -> [String: (first: [Duration], next: [Duration], count: Int)] {
        var found: [String: (first: [Duration], next: [Duration], count: Int)] = [:]
        for _ in 0 ..< runs {
            for root in roots {
                let index = try await LibraryIndex.open(at: url, migrations: migrations)
                var times: [Duration] = []
                var count = 0
                for _ in 0 ..< 2 {
                    let started = ContinuousClock.now
                    count = try await index.read { reader in
                        let statement = try reader.database.cached(SidecarCountTests.query)
                        try statement.bind(root.id, at: 1)
                        return try statement.first { $0.int(at: 0) } ?? 0
                    }
                    times.append(ContinuousClock.now - started)
                }
                await index.close()
                var entry = found[root.name] ?? ([], [], count)
                entry.first.append(times[0])
                entry.next.append(times[1])
                found[root.name] = entry
            }
        }
        return found
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_SIDECAR_COUNT_BENCH"] == "1"))
    func `the sheet's count as a launch's first read, before and after the index of photos with sidecars`(
    ) async throws {
        try #require(FileManager.default.fileExists(atPath: RootRemovalBenchTests.master.path), "lib-1m's index")
        let work = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/sidecar-count", isDirectory: true)
            .appending(path: "bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let url = work.appending(path: "Index.sqlite")
        try FileManager.default.copyItem(at: RootRemovalBenchTests.master, to: url)
        let older = Array(LibraryIndex.migrations.prefix(7))
        let split = try await LibraryIndex.open(at: url, migrations: older)
        let tops = try await RootRemovalBenchTests.split(split)
        let roots = try await split.read { reader in
            try tops
                .compactMap { path in
                    try reader.root(path: path).map { ($0.id, (path as NSString).lastPathComponent) }
                }
        }.filter { ["Clients", "2024", "2015", "Imports"].contains($0.1) }
        let sizes = try await split.read { reader in
            try roots.map { root in try "\(root.1) \(reader.photoCount(inRoot: root.0)) photos" }
        }
        await split.close()
        Self.report(sizes.joined(separator: ", "))

        let before = try await Self.counts(at: url, migrations: older, roots: roots, runs: 3)
        let opening = ContinuousClock.now
        let unmigrated = try await LibraryIndex.open(at: url, migrations: older)
        let opened = ContinuousClock.now - opening
        // The index alone, on the writer's connection, rolled back.
        let built = try unmigrated.onWriterAndWait { database in
            let started = ContinuousClock.now
            try database.execute("BEGIN IMMEDIATE")
            try database.execute(LibraryIndex.schemaVersion8)
            let built = ContinuousClock.now - started
            try database.execute("ROLLBACK")
            return built
        }
        await unmigrated.close()
        let started = ContinuousClock.now
        let migrated = try await LibraryIndex.open(at: url)
        let migration = ContinuousClock.now - started
        await migrated.close()
        let reopening = ContinuousClock.now
        try await LibraryIndex.open(at: url).close()
        let reopened = ContinuousClock.now - reopening
        let after = try await Self.counts(at: url, migrations: LibraryIndex.migrations, roots: roots, runs: 3)
        Self.report("""
        a million photos: opening at version 7 \(Self.milliseconds(opened)); the index alone \
        \(Self.milliseconds(built)); opening and migrating to version 8 \(Self.milliseconds(migration)); opening at \
        version 8 \(Self.milliseconds(reopened))
        """)
        for root in roots.map(\.1) {
            guard let old = before[root], let new = after[root] else { continue }
            #expect(old.count == new.count)
            let median = { (times: [Duration]) in Self.milliseconds(times.sorted()[times.count / 2]) }
            Self.report("""
            \(root), \(new.count) with sidecars: first read \(median(old.first)) before, \(median(new.first)) after \
            (median of 3); next \(median(old.next)) before, \(median(new.next)) after
            """)
        }
    }
}
