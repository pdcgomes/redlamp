import Foundation
import Testing
@testable import RedlampLibrary

/// The edits whose renders the store holds, at a million photos (LIB-17): a copy of lib-1m's index migrated to schema
/// version 10, every edited photo's edit recorded as rendered, then what a list reads beside its rows to show those
/// renders from the start: for a large source's first read (1,000 photos in capture order), for the folder with the
/// most photos, and for every edited photo at once. Skipped unless `REDLAMP_PHOTO_EDITS_BENCH=1`
/// (`TEST_RUNNER_REDLAMP_PHOTO_EDITS_BENCH=1` through xcodebuild) and lib-1m's index is on this Mac.
struct PhotoEditBenchTests {
    private static func report(_ line: String) {
        print("PHOTO-EDITS-BENCH \(line)")
    }

    private static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.2f ms", duration / .milliseconds(1))
    }

    /// The median of `runs` timings of `body`.
    private static func median(runs: Int = 5, _ body: () async throws -> Void) async rethrows -> Duration {
        var times: [Duration] = []
        for _ in 0 ..< runs {
            let started = ContinuousClock.now
            try await body()
            times.append(ContinuousClock.now - started)
        }
        return times.sorted()[runs / 2]
    }

    /// The rows of `ids` with the columns a list shows, and the IDs of the edited among them.
    private static func rows(_ ids: [Int64], in reader: some IndexQueries) throws -> [Int64] {
        let statement = try reader.database.cached("""
        SELECT id, folder, name, size, modified, sidecar_modified, edited, rating, flag, label, custom_label, marked, \
        other_fields, content_key FROM photos WHERE id = ?
        """)
        var edited: [Int64] = []
        for id in ids {
            try statement.bind(id, at: 1)
            try statement.forEachRow { row in
                if row.bool(at: 6), !row.isNull(at: 5) {
                    edited.append(row.int64(at: 0))
                }
            }
        }
        return edited
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_PHOTO_EDITS_BENCH"] == "1"))
    func `every edited photo's edit recorded at a million photos, and read beside the rows a list reads`(
    ) async throws {
        try #require(FileManager.default.fileExists(atPath: RootRemovalBenchTests.master.path), "lib-1m's index")
        let work = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/renders-launch", isDirectory: true)
            .appending(path: "bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let url = work.appending(path: "Index.sqlite")
        try FileManager.default.copyItem(at: RootRemovalBenchTests.master, to: url)

        let opening = ContinuousClock.now
        let index = try await LibraryIndex.open(at: url)
        let migration = ContinuousClock.now - opening
        defer { index.closeAndWait() }
        let edited = try await index.read { reader in
            try reader.database
                .prepare("SELECT id, sidecar_modified FROM photos WHERE edited != 0 AND sidecar_modified IS NOT NULL")
                .map { ($0.int64(at: 0), Date(timeIntervalSince1970: $0.double(at: 1))) }
        }
        let bytes = { try await index.read { reader in
            let count = try reader.database.prepare("PRAGMA page_count").first { $0.int(at: 0) } ?? 0
            return try count * (reader.database.prepare("PRAGMA page_size").first { $0.int(at: 0) } ?? 0)
        } }
        let before = try await bytes()
        let recording = ContinuousClock.now
        for start in stride(from: 0, to: edited.count, by: 1000) {
            let batch = edited[start ..< min(start + 1000, edited.count)]
            try await index.write { writer in
                for (id, modified) in batch {
                    var digest = withUnsafeBytes(of: id.bigEndian) { Data($0) }
                    digest.append(Data(repeating: 1, count: 8))
                    try writer.setPhotoEdit(
                        #require(EditDigest(data: digest)), ofPhoto: id, sidecarModified: modified, renderer: 1,
                    )
                }
            }
        }
        let recorded = Self.milliseconds(ContinuousClock.now - recording)
        let grown = try await (bytes() - before) / 1024
        Self.report("""
        opening and migrating lib-1m's index to version 10 \(Self.milliseconds(migration)); recording \(edited.count) \
        edited photos' edits in writes of 1,000 \(recorded), the index \(grown) KB larger
        """)

        let first = try await index.read { reader in
            try reader.database.prepare("SELECT id FROM photos ORDER BY captured LIMIT 1000").map { $0.int64(at: 0) }
        }
        let folder = try await index.read { reader in
            try reader.database.prepare("SELECT folder, count(*) AS n FROM photos GROUP BY folder ORDER BY n DESC")
                .first { ($0.int64(at: 0), $0.int(at: 1)) }
        }
        let (largest, photos) = try #require(folder)
        var found = (first: 0, folder: 0, all: 0)
        let firstRows = try await Self.median { _ = try await index.read { try Self.rows(first, in: $0) } }
        let firstEdits = try await Self.median {
            found.first = try await index.read { reader in
                try reader.standingPhotoEdits(ofPhotos: Self.rows(first, in: reader), renderer: 1).count
            }
        }
        let folderRows = try await Self.median { _ = try await index.read { try $0.photos(inFolder: largest) } }
        let folderEdits = try await Self.median {
            found.folder = try await index.read { reader in
                let rows = try reader.photos(inFolder: largest)
                return try reader.standingPhotoEdits(
                    ofPhotos: rows.filter { $0.edited && $0.sidecarModified != nil }.map(\.id), renderer: 1,
                ).count
            }
        }
        var byFolder = 0
        let folderEditsAtOnce = try await Self.median {
            byFolder = try await index.read { reader in
                _ = try reader.photos(inFolder: largest)
                return try reader.standingPhotoEdits(inFolders: [largest], renderer: 1).count
            }
        }
        #expect(byFolder == found.folder)
        Self.report("""
        the same folder's records in one statement: the rows and their \(byFolder) records \
        \(Self.milliseconds(folderEditsAtOnce)) (median of 5)
        """)
        let all = try await Self.median(runs: 3) {
            found.all = try await index.read { try $0.standingPhotoEdits(ofPhotos: edited.map(\.0), renderer: 1).count }
        }
        #expect(found.all == edited.count, "every record stands")
        Self.report("""
        a large source's first read, 1,000 photos: the rows \(Self.milliseconds(firstRows)), with their \(found.first) \
        edited photos' records \(Self.milliseconds(firstEdits)) (median of 5)
        """)
        Self.report("""
        the folder with the most photos, \(photos): the rows \(Self.milliseconds(folderRows)), with their \
        \(found.folder) edited photos' records \(Self.milliseconds(folderEdits)) (median of 5)
        """)
        Self.report("every edited photo's record, \(found.all): \(Self.milliseconds(all)) (median of 3)")
    }
}
