import Foundation
import Testing
@testable import RedlampLibrary

/// The xmp scenario, small enough for every run; and on a fixture with `REDLAMP_XMP_BENCH=1` (which
/// xcodebuild hands to the tests from `TEST_RUNNER_REDLAMP_XMP_BENCH=1`), the one at
/// `REDLAMP_XMP_BENCH_FIXTURE` (the 20,000-photo fixture by default), writing
/// `REDLAMP_XMP_BENCH_WRITES` `.xmp` (10,000) and syncing `REDLAMP_XMP_BENCH_PHOTOS` photos (2,000).
struct XMPBenchTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_XMP_BENCH"] == "1"))
    func `xmp on the fixture`() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixture = URL(
            fileURLWithPath: environment["REDLAMP_XMP_BENCH_FIXTURE"]
                ?? "/Volumes/SSD/redlamp-tmp/library-fixtures/lib-20k",
            isDirectory: true,
        )
        let context = try BenchContext(fixture: fixture, manifest: FixtureManifest.load(from: fixture), profile: .ssd)
        let scenario = XMPScenario(
            writes: environment["REDLAMP_XMP_BENCH_WRITES"].flatMap { Int($0) } ?? XMPScenario.defaultWrites,
            photos: environment["REDLAMP_XMP_BENCH_PHOTOS"].flatMap { Int($0) } ?? XMPScenario.defaultPhotos,
        )
        let report = try await BenchReport.run([scenario], in: context)
        for line in report.text.split(separator: "\n") {
            print("XMP-BENCH \(line)")
        }
        #expect(report.failed.isEmpty)
    }

    @Test func `the xmp scenario is added after the others, and found by name`() {
        BenchScenarios.registerXMP()
        BenchScenarios.registerXMP()
        #expect(BenchScenarios.all.map(\.name).filter { $0 == "xmp" } == ["xmp"])
        #expect(BenchScenarios.named("xmp") is XMPScenario)
    }

    @Test func `it merges the fixture's XMP without writing to it, syncs a library and writes .xmp, every count right`(
    ) async throws {
        let fixture = try TemporaryFolder()
        let summary = try LibraryFixture(spec: .init(photos: 200, seed: 23)).write(to: fixture.url)
        let indexFolder = try TemporaryFolder()
        let files = try FixtureTests.files(in: fixture.url)
        let context = BenchContext(fixture: fixture.url, manifest: summary.manifest, profile: .ssd)
        let report = try await BenchReport.run(
            [XMPScenario(writes: 200, photos: 60, indexFolder: indexFolder.url)], in: context,
        )
        #expect(report.failed.isEmpty, "\(report.text)")
        let results = Dictionary(report.results.map { ($0.id, $0) }) { first, _ in first }
        #expect(results["library-xmp-other-apps"]?.value == Double(summary.manifest.totals.xmpSidecars))
        #expect(results["library-xmp-sync-unchanged-photos"]?.value == 60)
        #expect(results["library-xmp-sync-taken"]?.value == 2)
        #expect((results["library-xmp-write-rate"]?.value ?? 0) > 0)
        #expect(try FixtureTests.files(in: fixture.url) == files)
    }
}
