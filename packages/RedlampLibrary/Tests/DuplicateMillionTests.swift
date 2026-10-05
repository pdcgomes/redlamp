import Foundation
import Testing
@testable import RedlampLibrary

/// Candidates at a million photos, grouped from the index. Skipped unless
/// `REDLAMP_DUPLICATES_BENCH=1`, which xcodebuild hands to the tests from
/// `TEST_RUNNER_REDLAMP_DUPLICATES_BENCH=1`; `REDLAMP_DUPLICATES_BENCH_INDEX` keeps the index at that
/// path, for `redlamp library duplicates` to run on.
struct DuplicateMillionTests {
    private static let photos = 1_000_000
    private static let perFolder = 200
    private static let root = "/Volumes/Bench/Photos"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_DUPLICATES_BENCH"] == "1"))
    func `a million photos' candidates are grouped from the index in one pass`() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-duplicates-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        let url = environment["REDLAMP_DUPLICATES_BENCH_INDEX"].map { URL(fileURLWithPath: $0) }
            ?? directory.appending(path: "Index.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try await LibraryIndex.open(at: url)
        defer { index.closeAndWait() }

        let library = SyntheticDuplicates(photos: Self.photos, share: 0.01, seed: 2026)
        if try await index.read({ try $0.photoCount() }) != Self.photos {
            let started = ContinuousClock.now
            // Straight into the photos table: the text index and keywords are the writer's, and the
            // grouping doesn't read them.
            try await index.write { writer in
                let volume = try writer.upsertVolume(VolumeRecord(uuid: "BENCH", kind: .ssd))
                let root = try writer.upsertRoot(RootRecord(volume: volume, path: Self.root))
                let folders = try (0 ..< Self.photos / Self.perFolder).map { number in
                    try writer.upsertFolder(FolderRecord(root: root, path: "\(Self.root)/\(number)"))
                }
                let insert = try writer.database.prepare("""
                INSERT INTO photos (id, folder, name, kind, size, modified, content_key, indexed)
                VALUES (?, ?, ?, 2, ?, 0, ?, 1)
                """)
                for photo in 0 ..< Self.photos {
                    let (high, low, size) = library.content(of: photo)
                    try insert.bind(Int64(photo + 1), at: 1)
                    try insert.bind(folders[photo / Self.perFolder], at: 2)
                    try insert.bind("IMG_\(photo).JPG", at: 3)
                    try insert.bind(size, at: 4)
                    try insert.bind(withUnsafeBytes(of: (high.bigEndian, low.bigEndian)) { Data($0) }, at: 5)
                    try insert.run()
                }
            }
            print(
                "DUPLICATES-BENCH rows written in \(String(format: "%.1f", (ContinuousClock.now - started).seconds)) s",
            )
        }
        let copies = library.copies
        for run in 1 ... 2 {
            let started = ContinuousClock.now
            let candidates = try await DuplicateFinder(index: index).candidates()
            let elapsed = ContinuousClock.now - started
            #expect(candidates.photosGrouped == Self.photos && candidates.copyCount == copies)
            print(String(
                format: "DUPLICATES-BENCH run %ld: %ld photos grouped from the index in %.0f ms, %ld groups, "
                    + "%ld copies; %.1f MB, %.1f bytes a photo",
                run, Self.photos, elapsed.seconds * 1000, candidates.groups.count, candidates.copyCount,
                Double(candidates.memoryFootprint) / 1_000_000,
                Double(candidates.memoryFootprint) / Double(Self.photos),
            ))
        }
    }
}
