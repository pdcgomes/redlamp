import Foundation
import Testing
@testable import RedlampLibrary

/// The index built at a million photos, four ways at once so they share the load: as it's built now, every
/// transaction that gives IDs writing and syncing `Index.ids` beside the index (A); the same transactions run on the
/// writer's queue directly, without that file, as before 28633ac4 (B), and with it (D), so the file is all that
/// differs; and at schema version 7, without version 8's index of the photos with sidecars (C).
/// Each takes ten batches of 1,000 photos in turn, one in seven with a sidecar as lib-1m's. On the external disk, in
/// `/Volumes/SSD/redlamp-tmp`. Skipped unless `REDLAMP_INDEX_BUILD_BENCH=1` (`TEST_RUNNER_REDLAMP_INDEX_BUILD_BENCH=1`
/// through xcodebuild).
struct IndexBuildBenchTests {
    private static let photoCount = 1_000_000
    private static let batchSize = 1000
    private static let perFolder = 200
    private static let turn = 10
    private static let root = "/Volumes/Bench/Photos"

    private static func report(_ line: String) {
        print("INDEX-BUILD-BENCH \(line)")
    }

    /// The load average over the last minute.
    private static var load: Double {
        var averages = [Double](repeating: 0, count: 3)
        getloadavg(&averages, 3)
        return averages[0]
    }

    /// An index with the bench's folders, cameras and lenses; its folders' IDs and the photos' maker.
    private static func make(
        at url: URL, migrations: [LibraryIndex.Migration],
    ) async throws -> (index: LibraryIndex, folders: [Int64], photos: SyntheticIndexPhotos) {
        let index = try await LibraryIndex.open(at: url, migrations: migrations)
        let (folders, cameras, lenses) = try await index.write { writer in
            let volume = try writer.upsertVolume(VolumeRecord(uuid: "BENCH", kind: .ssd))
            let root = try writer.upsertRoot(RootRecord(volume: volume, path: Self.root))
            let folders = try (0 ..< Self.photoCount / Self.perFolder).map { number in
                try writer.upsertFolder(FolderRecord(root: root, path: "\(Self.root)/Job \(number)"))
            }
            return try (
                folders, SyntheticIndexPhotos.cameras.map { try writer.cameraID(for: $0) },
                SyntheticIndexPhotos.lenses.map { try writer.lensID(for: $0) },
            )
        }
        return (index, folders, SyntheticIndexPhotos(seed: 2026, cameraIDs: cameras, lensIDs: lenses))
    }

    /// Batch `batch`'s photos for `folders`, one in seven with a sidecar.
    private static func batch(_ batch: Int, _ folders: [Int64], _ photos: inout SyntheticIndexPhotos) -> [PhotoRecord] {
        (0 ..< batchSize).map { offset in
            let number = batch * Self.batchSize + offset
            var photo = photos.photo(number, in: folders[number / Self.perFolder])
            if number % 7 == 0 {
                photo.sidecarModified = photo.modified
            }
            return photo
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_INDEX_BUILD_BENCH"] == "1"))
    func `a million photos indexed with and without Index.ids synced, and without the index of photos with sidecars`(
    ) async throws {
        let work = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/index-build", isDirectory: true)
            .appending(path: "bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        var arms: [(name: String, index: LibraryIndex, folders: [Int64], photos: SyntheticIndexPhotos)] = []
        for (name, migrations) in [
            ("A", LibraryIndex.migrations), ("B", LibraryIndex.migrations),
            ("C", Array(LibraryIndex.migrations.prefix(7))), ("D", LibraryIndex.migrations),
        ] {
            let folder = work.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let made = try await Self.make(at: folder.appending(path: "Index.sqlite"), migrations: migrations)
            arms.append((name, made.index, made.folders, made.photos))
        }
        defer {
            for arm in arms {
                arm.index.closeAndWait()
            }
        }
        var times = [Duration](repeating: .zero, count: arms.count)
        var loads: [Double] = []
        for start in stride(from: 0, to: Self.photoCount / Self.batchSize, by: Self.turn) {
            loads.append(Self.load)
            for number in arms.indices {
                let (index, folders) = (arms[number].index, arms[number].folders)
                for batch in start ..< start + Self.turn {
                    let photos = Self.batch(batch, folders, &arms[number].photos)
                    let started = ContinuousClock.now
                    if ["B", "D"].contains(arms[number].name) {
                        // The transaction `write` makes, the IDs given kept beside the index only in D.
                        let marks = arms[number].name == "D" ? index.marks : nil
                        try index.onWriterAndWait { database in
                            try database.transaction(.immediate) {
                                index.journal.begin()
                                marks?.begin()
                                _ = try LibraryIndex.Writer(database: database, journal: index.journal, marks: marks)
                                    .upsertPhotos(photos)
                                try marks?.save()
                                _ = try index.journal.stage(on: database)
                            }
                        }
                        index.journal.committed()
                    } else {
                        try await index.write { try $0.upsertPhotos(photos) }
                    }
                    times[number] += ContinuousClock.now - started
                }
            }
        }
        for (number, arm) in arms.enumerated() {
            let count = try await arm.index.read { try $0.photoCount() }
            #expect(count == Self.photoCount)
            let seconds = times[number] / .seconds(1)
            Self.report(String(
                format: "%@: %.1f s, %.0f photos a second, %.2f ms a transaction of %ld", arm.name, seconds,
                Double(count) / seconds, seconds * 1000 / Double(Self.photoCount / Self.batchSize), Self.batchSize,
            ))
        }
        let (a, b, c, d) = (
            times[0] / .seconds(1), times[1] / .seconds(1), times[2] / .seconds(1), times[3] / .seconds(1),
        )
        let transactions = Double(Self.photoCount / Self.batchSize)
        Self.report(String(
            format: "Index.ids synced (D against B): %+.1f s (%+.1f%%), %+.2f ms a transaction; as built (A against "
                + "B): %+.1f s (%+.1f%%); the index of photos with sidecars (A against C): %+.1f s (%+.1f%%); load "
                + "%.0f to %.0f",
            d - b, (d - b) / b * 100, (d - b) * 1000 / transactions, a - b, (a - b) / b * 100, a - c, (a - c) / c * 100,
            loads.min() ?? 0, loads.max() ?? 0,
        ))
        let marks = IndexIDMarks(index: arms[0].index.url).read()
        #expect(marks["photos"] == Int64(Self.photoCount))
    }
}
