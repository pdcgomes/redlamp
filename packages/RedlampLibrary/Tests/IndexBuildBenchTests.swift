import Foundation
import Testing
@testable import RedlampLibrary

/// The index built at a million photos, three ways in turn so they share the load: as it was built before, FTS5's
/// automerge merging the text index in the commits and every transaction that gives IDs writing and syncing
/// `Index.ids`; the same with `Index.ids` reserved a block ahead (`IndexIDMarks`), so the file is all that differs; and
/// as it's built now, with the text index merged a step at a time after the writes too (`IndexTextMerges`), its time
/// including the merges it waits for, and those left at the end of each turn. Each takes ten batches of 1,000 photos
/// in turn, one in seven with a sidecar as lib-1m's; every 100,000 photos, searches of the text index and its
/// segments. On the external disk, in `/Volumes/SSD/redlamp-tmp`. Skipped unless `REDLAMP_INDEX_BUILD_BENCH=1`
/// (`TEST_RUNNER_REDLAMP_INDEX_BUILD_BENCH=1` through xcodebuild).
struct IndexBuildBenchTests {
    private static let photoCount = 1_000_000
    private static let batchSize = 1000
    private static let perFolder = 200
    private static let turn = 10
    private static let searchEvery = 100_000
    private static let root = "/Volumes/Bench/Photos"

    private static func report(_ line: String) {
        print("INDEX-BUILD-BENCH \(line)")
    }

    /// An index with the bench's folders, cameras and lenses; its folders' IDs and the photos' maker.
    private static func make(
        at url: URL, stepped: Bool, idBlocks: [IndexIDs: Int64]?,
    ) async throws -> (index: LibraryIndex, folders: [Int64], photos: SyntheticIndexPhotos) {
        let index = try await LibraryIndex.offCaller {
            try LibraryIndex(
                url: url, readers: 2, migrations: LibraryIndex.migrations,
                textMerges: IndexTextMerges.Limits(following: stepped), idBlocks: idBlocks,
            )
        }
        if !stepped {
            try index
                .onWriterAndWait { try $0.execute("INSERT INTO photo_text (photo_text, rank) VALUES ('automerge', 4)") }
        }
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
    func `a million photos indexed with Index.ids synced or reserved, merged in the commits or a step at a time`(
    ) async throws {
        let work = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/index-build", isDirectory: true)
            .appending(path: "bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        let ways: [(name: String, stepped: Bool, idBlocks: [IndexIDs: Int64]?)] = [
            ("before", false, [:]), ("ids reserved", false, nil), ("as built", true, nil),
        ]
        struct Built {
            let arm: TextMergeBenchTests.Arm, folders: [Int64]
            var photos: SyntheticIndexPhotos
            let stepped: Bool
        }
        var arms: [Built] = []
        for way in ways {
            let folder = work.appending(path: way.name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let made = try await Self.make(
                at: folder.appending(path: "Index.sqlite"), stepped: way.stepped, idBlocks: way.idBlocks,
            )
            try arms.append(Built(
                arm: TextMergeBenchTests.Arm(name: way.name, index: made.index),
                folders: made.folders,
                photos: made.photos,
                stepped: way.stepped,
            ))
        }
        defer {
            for arm in arms {
                arm.arm.index.closeAndWait()
            }
        }
        var times = [Duration](repeating: .zero, count: arms.count)
        var merging = [Duration](repeating: .zero, count: arms.count)
        var loads: [Double] = []
        for start in stride(from: 0, to: Self.photoCount / Self.batchSize, by: Self.turn) {
            loads.append(TextMergeBenchTests.loadAverage)
            for number in arms.indices {
                let (arm, folders) = (arms[number].arm, arms[number].folders)
                let started = ContinuousClock.now
                for batch in start ..< start + Self.turn {
                    let photos = Self.batch(batch, folders, &arms[number].photos)
                    try await arm.batch { try $0.upsertPhotos(photos) }
                }
                if arms[number].stepped {
                    let merged = ContinuousClock.now
                    await arm.index.mergeText()
                    merging[number] += ContinuousClock.now - merged
                }
                times[number] += ContinuousClock.now - started
                let indexed = (start + Self.turn) * Self.batchSize
                if indexed % Self.searchEvery == 0 {
                    try await arm.search(after: indexed)
                }
            }
        }
        let transactions = Double(Self.photoCount / Self.batchSize)
        for (number, way) in arms.enumerated() {
            let count = try await way.arm.index.read { try $0.photoCount() }
            #expect(count == Self.photoCount)
            let seconds = times[number] / .seconds(1)
            Self.report(String(
                format: "%@: %.1f s, %.0f photos a second, %.2f ms a transaction of %ld, %.1f s of it the merges "
                    + "left after its turns",
                way.arm.name, seconds, Double(count) / seconds, seconds * 1000 / transactions, Self.batchSize,
                merging[number] / .seconds(1),
            ))
            way.arm.reportPhase("building")
        }
        let (before, reserved, built) = (times[0] / .seconds(1), times[1] / .seconds(1), times[2] / .seconds(1))
        Self.report(String(
            format: "Index.ids reserved (against before): %+.1f s (%+.1f%%), %+.2f ms a transaction; as built (against "
                + "before): %+.1f s (%+.1f%%); load %.0f to %.0f",
            reserved - before, (reserved - before) / before * 100, (reserved - before) * 1000 / transactions,
            built - before, (built - before) / before * 100, loads.min() ?? 0, loads.max() ?? 0,
        ))
        let marks = arms[2].arm.index.marks.read()
        #expect(marks["photos"] ?? 0 >= Int64(Self.photoCount))
    }
}
