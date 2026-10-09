import Foundation
import Testing
@testable import RedlampLibrary

/// The index at a million photos. Skipped unless `REDLAMP_INDEX_BENCH=1`, which xcodebuild hands to
/// the tests from `TEST_RUNNER_REDLAMP_INDEX_BENCH=1`, so CI stays fast.
struct IndexBenchmarkTests {
    private static let photoCount = 1_000_000
    private static let batchSize = 1000
    private static let perFolder = 200
    private static let root = "/Volumes/Bench/Photos"

    private static func time<T>(_ body: () throws -> T) rethrows -> (T, Duration) {
        let start = ContinuousClock.now
        let result = try body()
        return (result, ContinuousClock.now - start)
    }

    private static func median(_ runs: Int, _ body: () throws -> Void) rethrows -> Duration {
        var durations: [Duration] = []
        for _ in 0 ..< runs {
            try durations.append(time(body).1)
        }
        return durations.sorted()[runs / 2]
    }

    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.2f ms", duration / .milliseconds(1))
    }

    private static func report(_ line: String) {
        print("INDEX-BENCH \(line)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_INDEX_BENCH"] == "1"))
    func `a million photos: inserting, scanning, looking up, searching and counting`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-index-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try await LibraryIndex.open(at: directory.appending(path: "Index.sqlite"))
        defer { index.closeAndWait() }

        let made = try await Self.makeFolders(in: index)
        let (folders, folderPaths, cameras, lenses) = (made.folders, made.paths, made.cameras, made.lenses)

        var synthetic = SyntheticIndexPhotos(seed: 2026, cameraIDs: cameras, lensIDs: lenses)
        var writing = Duration.zero
        var samplePaths: [String] = []
        var sampleFileIDs: [UInt64] = []
        var sampleKeys: [Data] = []
        for batch in 0 ..< Self.photoCount / Self.batchSize {
            let photos = (0 ..< Self.batchSize).map { offset in
                let number = batch * Self.batchSize + offset
                return synthetic.photo(number, in: folders[number / Self.perFolder])
            }
            let sample = batch % Self.batchSize
            samplePaths.append(
                folderPaths[(batch * Self.batchSize + sample) / Self.perFolder] + "/" + photos[sample].name,
            )
            sampleFileIDs.append(photos[sample].fileID ?? 0)
            sampleKeys.append(photos[sample].contentKey ?? Data())
            let start = ContinuousClock.now
            try await index.write { try $0.upsertPhotos(photos) }
            writing += ContinuousClock.now - start
        }
        let seconds = writing / .seconds(1)
        Self.report(String(
            format: "insert: %ld rows in %.1f s, %.0f rows/s (batches of %ld, one transaction each)",
            Self.photoCount, seconds, Double(Self.photoCount) / seconds, Self.batchSize,
        ))

        try index.onWriterAndWait { try $0.execute("PRAGMA wal_checkpoint(TRUNCATE)") }
        let size = try FileManager.default.attributesOfItem(atPath: index.url.path)[.size] as? Int ?? 0
        let tables = try await index.read { reader in
            try reader.database.prepare("SELECT name, sum(pgsize) FROM dbstat GROUP BY name ORDER BY 2 DESC LIMIT 8")
                .map { "\($0.string(at: 0) ?? "") \($0.int(at: 1) / 1_000_000) MB" }
        }
        Self.report("size: \(size / 1_000_000) MB; largest: \(tables.joined(separator: ", "))")

        for run in 1 ... 2 {
            let (rows, scan) = try await index.read { reader in
                try Self.time {
                    var rows = 0
                    try reader.scanHotColumns { _ in rows += 1 }
                    return rows
                }
            }
            #expect(rows == Self.photoCount)
            Self.report(String(
                format: "hot-column scan, run %ld: %@, %.0f rows/s", run, Self.milliseconds(scan),
                Double(rows) / (scan / .seconds(1)),
            ))
        }

        let lookups = samplePaths
        let (found, lookup) = try await index.read { reader in
            try Self.time { try lookups.filter { try reader.photo(path: $0) != nil }.count }
        }
        #expect(found == lookups.count)
        var roundTrips: [Duration] = []
        for path in lookups.prefix(100) {
            let start = ContinuousClock.now
            _ = try await index.read { try $0.photo(path: path) }
            roundTrips.append(ContinuousClock.now - start)
        }
        Self.report(String(
            format: "lookup by path: %.1f µs each over %ld paths in one read; %@ median for a read of one",
            lookup / .microseconds(1) / Double(lookups.count), lookups.count,
            Self.milliseconds(roundTrips.sorted()[50]),
        ))

        let (fileIDs, keys) = (sampleFileIDs, sampleKeys)
        let (byFileID, byKey, subtree, fileIDLookup, keyLookup, subtreeQuery) = try await index.read { reader in
            let volume = try #require(try reader.volume(uuid: "BENCH")?.id)
            let (byFileID, fileIDLookup) = try Self.time {
                try fileIDs.filter { try reader.photos(fileID: $0, volume: volume).count == 1 }.count
            }
            let (byKey, keyLookup) = try Self
                .time { try keys.filter { try reader.photos(contentKey: $0).count == 1 }.count }
            let yearFolder = try #require(try reader.folder(path: Self.root + "/2005"))
            let (subtree, subtreeQuery) = try Self.time { try reader.photoIDs(inSubtreeOf: yearFolder.id).count }
            return (byFileID, byKey, subtree, fileIDLookup, keyLookup, subtreeQuery)
        }
        #expect(byFileID == fileIDs.count && byKey == keys.count && subtree > 0)
        Self.report(String(
            format: "lookup by file identifier on a volume: %.1f µs each; by content key: %.1f µs each; "
                + "the %ld photos under one year's folder: %@",
            fileIDLookup / .microseconds(1) / Double(fileIDs.count), keyLookup / .microseconds(1) / Double(keys.count),
            subtree, Self.milliseconds(subtreeQuery),
        ))

        let substring = "4821"
        let (matches, names, allColumns, scanned, nameSearch, allSearch, scan) = try await index.read { reader in
            var matches: [Int64] = []
            var all: [Int64] = []
            let nameSearch = try Self.median(5) { matches = try reader.photoIDs(matching: substring, in: .name) }
            let allSearch = try Self.median(5) { all = try reader.photoIDs(matching: substring) }
            let like = try reader.database.prepare("SELECT count(*) FROM photos WHERE instr(name, ?) > 0")
            try like.bind(substring, at: 1)
            let (scanned, scan) = try Self.time { try like.first { $0.int(at: 0) } ?? 0 }
            return (matches, matches.count, all.count, scanned, nameSearch, allSearch, scan)
        }
        #expect(names == scanned && !matches.isEmpty)
        Self.report(
            "FTS5 trigram search for \"\(substring)\": \(names) names in \(Self.milliseconds(nameSearch)) (median of 5); "
                + "all columns \(allColumns) photos in \(Self.milliseconds(allSearch)); "
                + "a scan of names with instr() \(Self.milliseconds(scan))",
        )

        let camera = cameras[9]
        let (count, counting) = try await index.read { reader in
            let statement = try reader.database.prepare("SELECT count(*) FROM photos WHERE rating >= 3 AND camera = ?")
            try statement.bind(camera, at: 1)
            var count = 0
            let counting = try Self.median(5) { count = try statement.first { $0.int(at: 0) } ?? 0 }
            return (count, counting)
        }
        Self
            .report(
                "count(*) where rating >= 3 and camera = ?: \(count) in \(Self.milliseconds(counting)) (median of 5)",
            )

        for (pattern, culled) in [
            ("in a row", (500_001 ... 510_000).map { Int64($0) }),
            ("every 97th", (1 ... 10000).map { Int64($0 * 97) }),
        ] {
            let (updated, rating) = try await Self.time {
                try await index.write { try $0.setOrganising([.rating(5), .flag(.pick)], forPhotos: culled) }
            }
            #expect(updated == culled.count)
            Self
                .report(
                    "rating and flagging \(culled.count) photos \(pattern) in one write: \(Self.milliseconds(rating))",
                )
        }

        let (sound, check) = try await Self.time { try await index.quickCheck() }
        #expect(sound)
        Self.report("quick_check: \(Self.milliseconds(check))")

        let (snapshot, copying) = try await Self.time {
            try await index.snapshot(to: directory.appending(path: "Snapshots", directoryHint: .isDirectory))
        }
        let snapshotSize = try FileManager.default.attributesOfItem(atPath: snapshot.path)[.size] as? Int ?? 0
        Self.report("snapshot (VACUUM INTO): \(Self.milliseconds(copying)), \(snapshotSize / 1_000_000) MB")
    }
}

private extension IndexBenchmarkTests {
    /// The bench's folders, by year and job, with their paths, and the synthetic photos' cameras and lenses.
    struct BenchFolders: Sendable {
        let folders: [Int64], paths: [String], cameras: [Int64], lenses: [Int64]
    }

    static func makeFolders(in index: LibraryIndex) async throws -> BenchFolders {
        let folderCount = photoCount / perFolder
        return try await index.write { writer in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "BENCH", kind: .ssd))
            let root = try writer.upsertRoot(RootRecord(volume: volume, path: Self.root))
            var years: [Int: Int64] = [:]
            var folders: [Int64] = []
            var paths: [String] = []
            for number in 0 ..< folderCount {
                let year = 2005 + number * 20 / folderCount
                if years[year] == nil {
                    years[year] = try writer.upsertFolder(FolderRecord(root: root, path: "\(Self.root)/\(year)"))
                }
                let path = String(
                    format: "%@/%ld/%ld-%02ld-%02ld Job %04ld", Self.root, year, year, 1 + number % 12, 1 + number % 28,
                    number,
                )
                try folders.append(writer.upsertFolder(FolderRecord(root: root, parent: years[year], path: path)))
                paths.append(path)
            }
            return try BenchFolders(
                folders: folders, paths: paths,
                cameras: SyntheticIndexPhotos.cameras.map { try writer.cameraID(for: $0) },
                lenses: SyntheticIndexPhotos.lenses.map { try writer.lensID(for: $0) },
            )
        }
    }

    static func time<T>(_ body: () async throws -> T) async rethrows -> (T, Duration) {
        let start = ContinuousClock.now
        let result = try await body()
        return (result, ContinuousClock.now - start)
    }
}
