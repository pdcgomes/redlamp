import Foundation
import RedlampLibrary
import Synchronization
import Testing
@testable import RedlampUI

/// All Photographs opened at a million photos, as the grid shows it (LIB-10): how long until its first change reaches
/// the main thread, and where that time goes: LibraryLive's list, the list's rows read and mapped to photos, and the
/// change it hands over. Skipped unless `REDLAMP_SOURCE_LIST_BENCH=1` (`TEST_RUNNER_REDLAMP_SOURCE_LIST_BENCH=1`
/// through xcodebuild) and lib-1m's index is on this Mac.
@MainActor
struct SourceListOpenBenchTests {
    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.0f ms", duration / .milliseconds(1))
    }

    private static var load: String {
        var averages = [Double](repeating: 0, count: 3)
        getloadavg(&averages, 3)
        return String(format: "%.0f", averages[0])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_SOURCE_LIST_BENCH"] == "1"))
    func `All Photographs at a million photos, opened`() async throws {
        try #require(FileManager.default.fileExists(atPath: SourceListRemovalBenchTests.master.path))
        let work = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/index-integrity", isDirectory: true)
            .appending(path: "open-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let paths = LibraryPaths(root: work)
        try FileManager.default.copyItem(at: SourceListRemovalBenchTests.master, to: paths.index)
        let (core, _) = try await LibraryCore.open(paths: paths, check: false) { _, _ in nil }
        let clock = ContinuousClock()

        for run in 1 ... 2 {
            // LibraryLive's list of every photo, as the source's list opens it.
            var started = clock.now
            await core.live.settle()
            let updates = core.live.open(.allPhotographs, sort: QuerySort(.captured))
            var iterator = updates.makeAsyncIterator()
            let update = try #require(await iterator.next())
            let listed = clock.now - started
            // Its photos' rows read a row at a time, as the list read them before, and made into the grid's photos.
            started = clock.now
            let ids = Array(update.list)
            let one = try await core.index.read { reader -> Int in
                var folders: [Int64: String] = [:]
                var made = 0
                for id in ids {
                    guard let row = try reader.photo(id: id) else { continue }
                    if folders[row.folder] == nil {
                        folders[row.folder] = try reader.folder(id: row.folder)?.path
                    }
                    guard let folder = folders[row.folder] else { continue }
                    let url = URL(fileURLWithPath: folder + "/" + row.name, isDirectory: false)
                    made += LibraryFolderList.Mapping.item(row, url: url).url == url ? 1 : 0
                }
                return made
            }
            let byRow = clock.now - started
            #expect(one == 1_000_000)
            // Read in one pass, as the list reads them now.
            started = clock.now
            let rows = try await LibrarySourceList.Mapping.read(ids, folders: [:], index: core.index)
            let alone = clock.now - started
            #expect(rows.photos.count == 1_000_000)
            started = clock.now
            var mapping = LibrarySourceList.Mapping()
            try await mapping.take(update, index: core.index)
            let read = clock.now - started
            // The change handed over.
            started = clock.now
            let change = mapping.change(handing: mapping.ids)
            let made = clock.now - started
            updates.close()
            #expect(change.items.count == 1_000_000)
            print("""
            SOURCE-LIST-OPEN run \(run): \(change.items.count) photos; LibraryLive's list \
            \(Self.milliseconds(listed)), rows read into photos a row at a time \(Self.milliseconds(byRow)), in one \
            pass \(Self.milliseconds(alone)), read and kept by the mapping \(Self.milliseconds(read)), change made \
            \(Self.milliseconds(made)); load \(Self.load)
            """)
            withExtendedLifetime((rows, mapping, change)) {}
        }

        // The whole of it, to the change's arrival on the main thread.
        let arrived = Mutex<(count: Int, at: ContinuousClock.Instant)?>(nil)
        let started = clock.now
        let list = LibrarySourceList(core: core, source: .allPhotographs) { change in
            arrived.withLock { $0 = (change.items.count, clock.now) }
        }
        for _ in 0 ..< 12000 where arrived.withLock({ $0 == nil }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let first = try #require(arrived.withLock { $0 })
        #expect(first.count == 1_000_000)
        print(
            "SOURCE-LIST-OPEN opened: \(first.count) photos on the main thread by \(Self.milliseconds(first.at - started))",
        )
        list.close()
        await core.index.close()
    }
}
