import Foundation
import RedlampLibrary
import Testing
@testable import RedlampUI

/// An action on the whole of a selection at a million (LIB-10): how long until it has its first batch of photos'
/// URLs, and every one's, read off the main thread as `SelectedPhotos` reads them, against every row read and
/// mapped, which such an action waited for before; and the main thread's part, taking the selection's IDs. Skipped
/// unless `REDLAMP_SELECTION_BENCH=1` (`TEST_RUNNER_REDLAMP_SELECTION_BENCH=1` through xcodebuild) and lib-1m's index
/// is on this Mac; a copy of it is opened, and removed.
@MainActor
struct SelectionActionBenchTests {
    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.1f ms", duration / .milliseconds(1))
    }

    private static var load: String {
        var averages = [Double](repeating: 0, count: 3)
        getloadavg(&averages, 3)
        return String(format: "%.0f", averages[0])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_SELECTION_BENCH"] == "1"))
    func `an action on a million photos selected has its first photos at once and their URLs off the main thread`(
    ) async throws {
        try #require(FileManager.default.fileExists(atPath: SourceListRemovalBenchTests.master.path))
        let work = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/index-integrity", isDirectory: true)
            .appending(path: "selection-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let paths = LibraryPaths(root: work)
        try FileManager.default.copyItem(at: SourceListRemovalBenchTests.master, to: paths.index)
        let (core, _) = try await LibraryCore.open(paths: paths, check: false) { _, _ in nil }
        let all = try await core.engine.list(.allPhotographs, matching: .all)
        #expect(all.count == 1_000_000)
        let clock = ContinuousClock()
        for run in 1 ... 2 {
            // Every row read and mapped, as the action waited for.
            var start = clock.now
            let rows = try await LargeListRows(index: core.index, firstRead: LibrarySourceList.firstRead)
                .rows(of: Array(all.ids))
            let everyRow = clock.now - start
            // The selection's IDs taken on the main thread, every photo selected.
            start = clock.now
            var selection = PhotoSelection()
            selection.selectAll(in: all)
            let ids = selection.ids(in: all)
            let taken = clock.now - start
            // Its first batch's URLs, then every one's, each folder's path read afresh.
            let photos = SelectedPhotos(
                ids: ids, read: [:], source: LargeListRows(index: core.index, firstRead: LibrarySourceList.firstRead),
            )
            start = clock.now
            var batches = photos.batches(of: SettingsSync.batch)
            let first = await batches.next()
            let firstBatch = clock.now - start
            start = clock.now
            let urls = await photos.all()
            let everyURL = clock.now - start
            #expect(first?.count == SettingsSync.batch)
            #expect(urls.count == all.count)
            #expect(urls == all.ids.compactMap { rows.items[$0]?.url }, "the rows' own URLs, in order")
            print("""
            SELECTION-ACTION run \(run): \(all.count) photos selected; every row read and mapped in \
            \(Self.milliseconds(everyRow)); the selection's IDs taken in \(Self.milliseconds(taken)) on the main \
            thread; the first \(SettingsSync.batch) photos' URLs in \(Self.milliseconds(firstBatch)), every \
            one's in \(Self.milliseconds(everyURL)); load \(Self.load)
            """)
        }
        await core.index.close()
    }
}
