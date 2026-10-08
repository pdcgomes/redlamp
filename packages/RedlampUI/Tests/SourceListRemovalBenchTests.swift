import Foundation
import RedlampLibrary
import Synchronization
import Testing
@testable import RedlampUI

/// All Photographs' list at a million photos as lib-1m's Clients (150,000 photos) leaves the library, as the grid
/// shows it: how long until its change reaches the main thread, and where that time goes, LibraryLive's update, the
/// list's mapping of it and the change it hands over. Skipped unless `REDLAMP_SOURCE_LIST_BENCH=1`
/// (`TEST_RUNNER_REDLAMP_SOURCE_LIST_BENCH=1` through xcodebuild) and lib-1m's index is on this Mac.
@MainActor
struct SourceListRemovalBenchTests {
    static let master = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/indexfix/lib-1m-master/Index.sqlite")
    static let fixture = "/Volumes/SSD/redlamp-tmp/library-fixtures/lib-1m.noindex"

    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1f ms", duration / .milliseconds(1))
    }

    private static var load: String {
        var averages = [Double](repeating: 0, count: 3)
        getloadavg(&averages, 3)
        return String(format: "%.0f", averages[0])
    }

    /// The changes handed over, when each reached the main thread.
    private final class Delivered: @unchecked Sendable {
        let changes = Mutex<[(count: Int, at: ContinuousClock.Instant, took: Duration)]>([])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_SOURCE_LIST_BENCH"] == "1"))
    func `All Photographs at a million photos leaving 150,000 out`() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.master.path), "lib-1m's index is on this Mac")
        let work = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/removed-folders", isDirectory: true)
            .appending(path: "list-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let paths = LibraryPaths(root: work)
        try FileManager.default.copyItem(at: Self.master, to: paths.index)
        let fixture = Self.fixture
        let split = try await LibraryIndex.open(at: paths.index, readers: 1)
        let tops = try await split.write { writer -> [String] in
            let listing = try writer.database.cached("""
            SELECT path FROM folders WHERE parent = (SELECT id FROM folders WHERE path = ?) ORDER BY path
            """)
            try listing.bind(fixture, at: 1)
            let tops = try listing.map { $0.string(at: 0) ?? "" }
            let volume = try #require(try writer.root(path: fixture)).volume
            let own = try writer.database
                .cached("UPDATE folders SET root = ?4 WHERE path = ?1 OR (path >= ?2 AND path < ?3)")
            let top = try writer.database.cached("UPDATE folders SET parent = NULL WHERE path = ?")
            for path in tops {
                try own.bind(path, at: 1)
                try own.bind(path + "/", at: 2)
                try own.bind(path + "0", at: 3)
                try own.bind(writer.upsertRoot(RootRecord(volume: volume, path: path)), at: 4)
                try own.run()
                try top.bind(path, at: 1)
                try top.run()
            }
            return tops
        }
        await split.close()
        let (core, _) = try await LibraryCore.open(paths: paths, check: false) { _, _ in nil }
        let clients = Self.fixture + "/Clients"
        let kept = tops.filter { $0 != clients }.map { URL(fileURLWithPath: $0, isDirectory: true) }

        let delivered = Delivered()
        let clock = ContinuousClock()
        let list = LibrarySourceList(core: core, source: .allPhotographs) { change in
            delivered.changes.withLock { $0.append((change.items.count, clock.now, change.took.list)) }
        }
        for _ in 0 ..< 6000 where delivered.changes.withLock({ $0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let total = try #require(delivered.changes.withLock { $0.last?.count })
        print("SOURCE-LIST-BENCH \(total) photos shown, load \(Self.load)")

        let started = clock.now
        let removal = try #require(try await core.roots.remove(URL(fileURLWithPath: clients), keeping: kept))
        let removed = clock.now - started
        let left = total - removal.photos.count
        for _ in 0 ..< 60000 where delivered.changes.withLock({ $0.last?.count }) != left {
            try await Task.sleep(for: .milliseconds(1))
        }
        let change = try #require(delivered.changes.withLock { $0.last })
        #expect(change.count == left)
        print("""
        SOURCE-LIST-BENCH \(removal.photos.count) photos out: the store and the counts' links by \
        \(Self.milliseconds(removed)), All Photographs' change on the main thread by \
        \(Self.milliseconds(change.at - started)), its list made in \(Self.milliseconds(change.took)); load \
        \(Self.load)
        """)
        list.close()
        await core.roots.swept()
        await core.index.close()
    }
}
