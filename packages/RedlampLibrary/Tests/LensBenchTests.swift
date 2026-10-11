import Foundation
import Testing
@testable import RedlampLibrary

/// The traits Wide Open, Telephoto and Ultra Wide at a million photos, within the query engine's budgets (p95 16 ms
/// for the first page and the count as each character is typed, 100 ms for facets), and schema version 12's
/// migration at a million photos.
struct LensBenchTests {
    static let photoCount = 1_000_000

    private static func report(_ line: String) {
        print("LENS-BENCH \(line)")
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        duration / .milliseconds(1)
    }

    private static func percentile(_ durations: [Duration], _ fraction: Double) -> Double {
        let sorted = durations.sorted()
        return milliseconds(sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))])
    }

    /// What each query finds of `photos`, counted as it's built.
    struct Library {
        var store: ColumnStore
        var counts: [String: Int]
    }

    static let queries: [(text: String, matches: @Sendable (ColumnStore.Row) -> Bool)] = [
        ("is:wide-open", { isWideOpen($0) }),
        ("is:telephoto", { ColumnEncoding.focal($0.focal35) >= 700 }),
        ("is:ultra-wide", { (1 ..< 240).contains(ColumnEncoding.focal($0.focal35)) }),
        ("focal35:24..70", { (240 ... 700).contains(ColumnEncoding.focal($0.focal35)) }),
        ("widest<=1.8", { (1 ... 180).contains(ColumnEncoding.aperture($0.widestAperture)) }),
        ("is:wide-open is:telephoto -rating:0", { row in
            isWideOpen(row) && ColumnEncoding.focal(row.focal35) >= 700 && row.hot.rating != 0
        }),
        ("is:telephoto,ultra-wide", { row in
            let focal = ColumnEncoding.focal(row.focal35)
            return focal >= 700 || (1 ..< 240).contains(focal)
        }),
    ]

    private static func isWideOpen(_ row: ColumnStore.Row) -> Bool {
        ColumnEncoding.isWideOpen(
            aperture: ColumnEncoding.aperture(row.hot.aperture), widest: ColumnEncoding.aperture(row.widestAperture),
        )
    }

    /// A million photos: nine in ten with a lens's widest aperture, shot at it a third of the time and otherwise a
    /// sixth of a stop to two stops down, and ten in eleven with a 35 mm focal length from 13 to 600 mm.
    static func library() -> Library {
        var builder = ColumnStore.Builder(capacity: photoCount)
        var counts = [String: Int]()
        let widests: [Double] = [1.2, 1.4, 1.8, 2, 2.8, 4, 4.5, 5.6]
        let focals: [Double] = [13, 16, 20, 24, 28, 35, 50, 70, 85, 105, 135, 200, 300, 400, 600]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in 0 ..< photoCount {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let random = Int(truncatingIfNeeded: state >> 33)
            let widest = random % 10 == 0 ? nil : widests[random % widests.count]
            let sixths = (random >> 4) % 3 == 0 ? 0 : (random >> 6) % 12 + 1
            let focal35 = random % 11 == 0 ? nil : focals[(random >> 8) % focals.count]
            let row = ColumnStore.Row(
                HotColumns(
                    id: Int64(index + 1), folder: Int64(index % 1000 + 1), captured: 1.5e9 + Double(index) * 60,
                    camera: nil, lens: nil, rating: random % 6, flag: 0, label: 0, marked: false, edited: false,
                    iso: 400, aperture: widest.map { $0 * pow(2, Double(sixths) / 12) },
                    focal: focal35.map { $0 / 1.5 },
                    kind: PhotoRecord.Kind.jpeg.rawValue, name: "IMG_\(index).JPG",
                ),
                widestAperture: widest, focal35: focal35,
            )
            for query in queries where query.matches(row) {
                counts[query.text, default: 0] += 1
            }
            builder.add(row)
        }
        return Library(store: builder.finish(), counts: counts)
    }

    @Test(.measuresSpeed)
    func `a million photos: the traits' first page and count as each character is typed, their counts and facets`(
    ) async throws {
        let clock = ContinuousClock()
        let building = clock.now
        let library = Self.library()
        Self.report(String(
            format: "store: %ld photos in %.0f ms, %.1f bytes a photo", library.store.count,
            Self.milliseconds(clock.now - building),
            Double(library.store.memoryFootprint) / Double(library.store.count),
        ))
        let source = SyntheticSource(store: library.store, names: QueryNames(), text: SyntheticText())
        let warm = QueryEngine(source: source, timeZone: .gmt)
        try await warm.load()
        for query in Self.queries {
            for typed in QueryMillionTests.typed(query.text) {
                _ = try await warm.results(LibraryQuery(parsing: typed, asYouType: true))
            }
        }

        let engine = QueryEngine(source: source, timeZone: .gmt)
        try await engine.load()
        var firsts: [Duration] = []
        var slowest: [(Duration, String)] = []
        for query in Self.queries {
            for typed in QueryMillionTests.typed(query.text) {
                let started = clock.now
                var first: Duration?
                var last: QueryResult?
                for try await result in try engine.search(LibraryQuery(parsing: typed, asYouType: true)) {
                    first = first ?? clock.now - started
                    last = result
                }
                let time = first ?? clock.now - started
                firsts.append(time)
                slowest.append((time, typed))
                if typed == query.text {
                    #expect(last?.count == library.counts[query.text], "\(query.text)")
                }
            }
        }
        let worst = slowest.sorted { $0.0 > $1.0 }.prefix(3)
            .map { String(format: "%@ %.2f ms", $0.1, Self.milliseconds($0.0)) }.joined(separator: ", ")
        Self.report(String(
            format: "%ld keystrokes: first page and count p50 %.2f ms, p95 %.2f ms; slowest: %@", firsts.count,
            Self.percentile(firsts, 0.5), Self.percentile(firsts, 0.95), worst,
        ))
        #expect(Self.percentile(firsts, 0.95) < 16)

        var counted: [Duration] = []
        for _ in 0 ..< 5 {
            for (typed, trait) in [("wide", "wide-open"), ("tele", "telephoto"), ("ultra", "ultra-wide")] {
                let started = clock.now
                let offered = await engine.completions(typed, field: .trait)
                counted.append(clock.now - started)
                let count = offered.first { $0.value == trait }?.count
                #expect(count == library.counts["is:\(trait)"], "\(trait)")
            }
        }
        Self.report(String(
            format: "%ld completions with the traits' counts: p50 %.2f ms, p95 %.2f ms", counted.count,
            Self.percentile(counted, 0.5), Self.percentile(counted, 0.95),
        ))
        #expect(Self.percentile(counted, 0.95) < 16)

        var facets: [Duration] = []
        for query in Self.queries.map(\.text) + [""] {
            let parsed = try LibraryQuery(parsing: query)
            for facet in [Facet.focal35, .widestAperture] {
                let started = clock.now
                for try await counts in engine.facets([facet], for: parsed) {
                    let total = query.isEmpty ? Self.photoCount : library.counts[query]
                    #expect(counts.total == total, "\(query) by \(facet)")
                }
                facets.append(clock.now - started)
            }
        }
        Self.report(String(
            format: "%ld facet passes by 35 mm focal length and widest aperture: p50 %.2f ms, p95 %.2f ms",
            facets.count, Self.percentile(facets, 0.5), Self.percentile(facets, 0.95),
        ))
        #expect(Self.percentile(facets, 0.95) < 100)
    }

    /// An index of version 11 at `url` holding `photos` photos read before version 12, from the fixture's cameras and
    /// lenses, in folders of a thousand.
    static func olderIndex(at url: URL, photos: Int) async throws {
        let older = try await LibraryIndex.open(at: url, migrations: Array(LibraryIndex.migrations.prefix(11)))
        let cameras = FixtureCatalog.cameras
        let lenses = FixtureCatalog.lenses
        try await older.write { writer in
            let camera = try writer.database.prepare("INSERT INTO cameras (id, make, model, name) VALUES (?, ?, ?, ?)")
            for (number, entry) in cameras.enumerated() {
                try camera.bind(number + 1, at: 1)
                try camera.bind(entry.make, at: 2)
                try camera.bind(entry.model, at: 3)
                try camera.bind("\(entry.make) \(entry.model)", at: 4)
                try camera.run()
            }
            let lens = try writer.database.prepare("INSERT INTO lenses (id, name) VALUES (?, ?)")
            for (number, entry) in lenses.enumerated() {
                try lens.bind(number + 1, at: 1)
                try lens.bind(entry.name, at: 2)
                try lens.run()
            }
            try writer.database.execute("""
            WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i + 1 < \(photos))
            INSERT INTO photos (folder, name, kind, size, modified, captured, camera, lens, iso, aperture, shutter,
              focal, width, height, indexed)
            SELECT 1 + i / 1000, 'IMG_' || i || '.JPG', 2, 2000000 + i, 1600000000 + i, 1500000000 + i * 60,
              1 + i % \(cameras.count), 1 + i % \(lenses.count), 400, 2.8, 0.004, 12 + i % 300, 6000, 4000, 1
            FROM n;
            """)
        }
        await older.close()
    }

    @Test(.measuresSpeed)
    func `version 12's migration at a million photos fills what names and cameras give`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "redlamp-lens-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Index.sqlite")
        try await Self.olderIndex(at: url, photos: Self.photoCount)
        let started = ContinuousClock.now
        let index = try await LibraryIndex.open(at: url)
        let elapsed = ContinuousClock.now - started
        defer { index.closeAndWait() }
        let (widest, focal35, marked, folders) = try await index.read { reader in
            func count(_ sql: String) throws -> Int {
                try reader.database.prepare(sql).first { $0.int(at: 0) } ?? 0
            }
            return try (
                count("SELECT count(*) FROM photos WHERE widest_aperture IS NOT NULL"),
                count("SELECT count(*) FROM photos WHERE focal35 IS NOT NULL"),
                count("SELECT count(*) FROM photos WHERE indexed = \(PhotoRecord.lensToRead)"),
                reader.foldersWithLensesToRead().count,
            )
        }
        Self.report(String(
            format: "migration to version 12 at %ld photos: %.0f ms; %ld with a widest aperture from their lens's "
                + "name, %ld with a 35 mm focal length from their camera, %ld to read again in %ld folders",
            Self.photoCount, Self.milliseconds(elapsed), widest, focal35, marked, folders,
        ))
        #expect(marked == Self.photoCount && folders == Self.photoCount / 1000)
        #expect(widest > Self.photoCount / 2 && focal35 > 0 && focal35 < Self.photoCount)
    }

    /// lib-1m's own index, copied, brought to version 11 and timed to 12. With `REDLAMP_LENS_BENCH=1`, which
    /// xcodebuild hands to the tests from `TEST_RUNNER_REDLAMP_LENS_BENCH=1`.
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["REDLAMP_LENS_BENCH"] == "1"), .measuresSpeed,
    )
    func `version 12's migration on a copy of lib-1m's index`() async throws {
        try #require(FileManager.default.fileExists(atPath: RootRemovalBenchTests.master.path), "lib-1m's index")
        let work = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/lens-bench", isDirectory: true)
            .appending(path: "bench-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let url = work.appending(path: "Index.sqlite")
        try FileManager.default.copyItem(at: RootRemovalBenchTests.master, to: url)
        try await LibraryIndex.open(at: url, migrations: Array(LibraryIndex.migrations.prefix(11))).close()
        for run in 1 ... 2 {
            let copy = work.appending(path: "Run\(run).sqlite")
            try FileManager.default.copyItem(at: url, to: copy)
            let started = ContinuousClock.now
            let index = try await LibraryIndex.open(at: copy)
            let elapsed = ContinuousClock.now - started
            let (widest, focal35, total) = try await index.read { reader in
                func count(_ sql: String) throws -> Int {
                    try reader.database.prepare(sql).first { $0.int(at: 0) } ?? 0
                }
                return try (
                    count("SELECT count(*) FROM photos WHERE widest_aperture IS NOT NULL"),
                    count("SELECT count(*) FROM photos WHERE focal35 IS NOT NULL"),
                    count("SELECT count(*) FROM photos"),
                )
            }
            await index.close()
            Self.report(String(
                format: "lib-1m, run %ld: migration to version 12 in %.0f ms; of %ld photos, %ld with a widest aperture, "
                    + "%ld with a 35 mm focal length", run, Self.milliseconds(elapsed), total, widest, focal35,
            ))
            #expect(widest > 0 && total == 1_000_000)
        }
    }
}
