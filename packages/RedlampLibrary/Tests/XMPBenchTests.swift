import Foundation
import Testing
@testable import RedlampLibrary

struct XMPBenchTests {
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
