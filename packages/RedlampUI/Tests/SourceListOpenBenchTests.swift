import Foundation
import RedlampLibrary
import Synchronization
import Testing
@testable import RedlampUI

/// All Photographs opened at a million photos, as the grid shows it (LIB-10): how long until its first change reaches
/// the main thread, and where that time goes: LibraryLive's list, and the change a large source hands over, with the
/// rows of its first screens; and, for comparison, what reading every row and mapping it to a photo took when the
/// change carried them all. Skipped unless `REDLAMP_SOURCE_LIST_BENCH=1` (`TEST_RUNNER_REDLAMP_SOURCE_LIST_BENCH=1`
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

    /// A row's fields as the grid shows them, kept as the index has them.
    private struct BareRow {
        var id: Int64
        var folder: Int64
        var name: String
        var size: Int64
        var modified: Double
        var sidecarModified: Double
        var badges: Int64
        var key: Data?
    }

    /// Reads `ids`' rows in one pass over their range, `readers` parts at once, keeping their fields alone.
    private nonisolated static func bareRows(_ ids: [Int64], index: LibraryIndex, readers: Int) async throws -> Int {
        guard let low = ids.min(), let high = ids.max() else { return 0 }
        let part: Int64 = 1 << 15
        @Sendable func reading(from start: Int64) async throws -> [BareRow] {
            try await index.read { reader in
                let statement = try reader.database.cached("""
                SELECT \(LibrarySourceList.Mapping.shown) FROM photos WHERE id BETWEEN ? AND ?
                """)
                try statement.bind(start, at: 1)
                try statement.bind(min(start + part - 1, high), at: 2)
                var found: [BareRow] = []
                found.reserveCapacity(Int(part))
                try statement.forEachRow { row in
                    found.append(BareRow(
                        id: row.int64(at: 0), folder: row.int64(at: 1), name: row.string(at: 2) ?? "",
                        size: row.int64(at: 3), modified: row.double(at: 4), sidecarModified: row.double(at: 5),
                        badges: row.int64(at: 7) | row.int64(at: 8) << 3 | row.int64(at: 9) << 5
                            | row.int64(at: 11) << 8 | row.int64(at: 6) << 9 | row.int64(at: 12) << 10,
                        key: row.data(at: 13),
                    ))
                }
                return found
            }
        }
        var starts = stride(from: low, through: high, by: Int(part)).makeIterator()
        return try await withThrowingTaskGroup(of: [BareRow].self) { group in
            for _ in 0 ..< readers {
                if let start = starts.next() {
                    group.addTask { try await reading(from: start) }
                }
            }
            var count = 0
            while let found = try await group.next() {
                count += found.count
                if let start = starts.next() {
                    group.addTask { try await reading(from: start) }
                }
            }
            return count
        }
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
            #expect(rows.parts.reduce(0) { $0 + $1.count } == 1_000_000)
            // The same pass keeping each row's fields as they are, making no URL or item, on three readers and four.
            var bare: [Duration] = []
            for readers in [3, 4] {
                started = clock.now
                let count = try await Self.bareRows(ids, index: core.index, readers: readers)
                bare.append(clock.now - started)
                #expect(count == 1_000_000)
            }
            started = clock.now
            var every = LibrarySourceList.Mapping(largestRead: .max)
            try await every.take(update, index: core.index)
            let read = clock.now - started
            started = clock.now
            let whole = every.change(handing: every.ids, of: .allPhotographs)
            let made = clock.now - started
            #expect(whole.items.count == 1_000_000)
            // As a large source: the list alone, and its first screens' rows.
            started = clock.now
            var large = LibrarySourceList.Mapping()
            try await large.take(update, index: core.index)
            let change = large.change(handing: large.ids, of: .allPhotographs, whole: true)
            let handed = clock.now - started
            started = clock.now
            let first = try await LibrarySourceList.Mapping.read(
                Array(change.list.ids.prefix(LibrarySourceList.firstRead)), folders: [:], index: core.index,
            )
            let firstRows = clock.now - started
            updates.close()
            #expect(change.list.count == 1_000_000 && change.items.isEmpty && change.read != nil)
            #expect(first.parts.reduce(0) { $0 + $1.count } == LibrarySourceList.firstRead)
            print("""
            SOURCE-LIST-OPEN run \(run): \(change.list.count) photos; LibraryLive's list \
            \(Self.milliseconds(listed)), the large source's change \(Self.milliseconds(handed)), its first \
            \(LibrarySourceList.firstRead) rows \(Self.milliseconds(firstRows)); every row read into photos a row at a \
            time \(Self.milliseconds(byRow)), in one pass \(Self.milliseconds(alone)), their fields alone on three \
            readers \(Self.milliseconds(bare[0])) and four \(Self.milliseconds(bare[1])), read and kept by the mapping \
            \(Self.milliseconds(read)), its change made \(Self.milliseconds(made)); load \(Self.load)
            """)
            withExtendedLifetime((rows, every, whole, first)) {}
        }

        // The whole of it, to the change's arrival on the main thread.
        let arrived = Mutex<(count: Int, at: ContinuousClock.Instant)?>(nil)
        let started = clock.now
        let list = LibrarySourceList(core: core, source: .allPhotographs) { change in
            arrived.withLock { $0 = (change.list.count, clock.now) }
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
