import Foundation
import RedlampLibrary
import Synchronization
import Testing
@testable import RedlampUI

/// lib-1m's folders of more than 50,000 photos opened from the library with their subfolders, as Folders shows them
/// (LIB-10): how long until their first change reaches the main thread with every row read, as before, and as a large
/// folder whose rows are read as its cells appear; and how many photos the two place differently. Skipped unless
/// `REDLAMP_FOLDER_LIST_BENCH=1` (`TEST_RUNNER_REDLAMP_FOLDER_LIST_BENCH=1` through xcodebuild) and lib-1m's index is
/// on
/// this Mac; a copy of it is opened, and removed.
@MainActor
struct FolderListOpenBenchTests {
    static let fixture = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/library-fixtures/lib-1m.noindex")

    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.0f ms", duration / .milliseconds(1))
    }

    private static var load: String {
        var averages = [Double](repeating: 0, count: 3)
        getloadavg(&averages, 3)
        return String(format: "%.0f", averages[0])
    }

    /// `folder`'s first change with its subfolders, and how long it took to reach the main thread.
    private func opened(
        _ folder: URL, core: LibraryCore, largestRead: Int,
    ) async throws -> (change: LibraryFolderList.Change, took: Duration) {
        let clock = ContinuousClock()
        let arrived = Mutex<(change: LibraryFolderList.Change, at: ContinuousClock.Instant)?>(nil)
        let started = clock.now
        let list = LibraryFolderList(
            core: core, folder: folder, includingSubfolders: true, largestRead: largestRead,
        ) { change in
            arrived.withLock { $0 = $0 ?? (change, clock.now) }
        }
        defer { list.close() }
        let deadline = clock.now + .seconds(120)
        while arrived.withLock({ $0 == nil }), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let first = try #require(arrived.withLock { $0 })
        return (first.change, first.at - started)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_FOLDER_LIST_BENCH"] == "1"))
    func `lib-1m's folders of more than 50,000 photos, opened`() async throws {
        try #require(FileManager.default.fileExists(atPath: SourceListRemovalBenchTests.master.path))
        let work = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/index-integrity", isDirectory: true)
            .appending(path: "folder-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let paths = LibraryPaths(root: work)
        try FileManager.default.copyItem(at: SourceListRemovalBenchTests.master, to: paths.index)
        let (core, _) = try await LibraryCore.open(paths: paths, check: false) { _, _ in nil }
        let folders = [
            (Self.fixture.appending(path: "2024", directoryHint: .isDirectory), 50066),
            (Self.fixture.appending(path: "Clients", directoryHint: .isDirectory), 150_000),
            (Self.fixture, 1_000_000),
        ]
        for (folder, count) in folders {
            for run in 1 ... 2 {
                let (every, before) = try await opened(folder, core: core, largestRead: .max)
                let all = try #require(every.all)
                #expect(all.ids.count == count)
                let (large, after) = try await opened(folder, core: core, largestRead: LibrarySourceList.largestRead)
                let change = try #require(large.large)
                #expect(change.list.count == count && change.read?.count == LibrarySourceList.firstRead)
                #expect(Set(change.list.ids) == Set(all.ids))
                let placed = zip(all.ids, change.list.ids).count { $0 != $1 }
                #expect(placed == 0, "the same order as with every row read")
                print("""
                FOLDER-LIST-OPEN \(folder.lastPathComponent) run \(run): \(count) photos with their subfolders; \
                on the main thread by \(Self.milliseconds(before)) with every row read, \
                \(Self.milliseconds(after)) as a large folder; \(placed) placed otherwise; load \(Self.load)
                """)
            }
        }
        await core.index.close()
    }
}
