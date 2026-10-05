import Foundation
import Testing
@testable import RedlampLibrary

struct LibraryIndexerBenchTests {
    @Test func `indexing's scenarios are added after the others, and found by name`() {
        BenchScenarios.registerIndexing()
        BenchScenarios.registerIndexing()
        let names = BenchScenarios.all.map(\.name)
        #expect(Array(names.prefix(2)) == ["listing", "fixture-check"])
        let indexing = ["index-build", "warm-launch", "reconcile", "vanishing-volume"]
        #expect(names.filter(indexing.contains) == indexing)
        #expect(BenchScenarios.named("index-build") is IndexBuildScenario)
        #expect(BenchScenarios.named("warm-launch") is IndexLaunchScenario)
        #expect(BenchScenarios.named("reconcile") is ReconcileScenario)
        #expect(BenchScenarios.named("vanishing-volume") is VanishingVolumeScenario)
    }

    @Test func `the indexing scenarios build, relaunch, reconcile and survive a vanishing volume with the manifest's counts`(
    ) async throws {
        let folder = try TemporaryFolder()
        let summary = try LibraryFixture(spec: .init(photos: 400, seed: 51)).write(to: folder.url)
        let totals = summary.manifest.totals
        for profile in [VolumeProfile.ssd, .nas] {
            let context = BenchContext(fixture: folder.url, manifest: summary.manifest, profile: profile)
            let report = try await BenchReport.run(
                [IndexBuildScenario(), IndexLaunchScenario(), ReconcileScenario(), VanishingVolumeScenario()],
                in: context,
            )
            let results = Dictionary(report.results.map { ($0.id, $0) }) { first, _ in first }
            // Counts are exact whatever the load; times are measured on a busy machine.
            let miscounted = report.failed.filter { $0.budget?.kind == .exactly }
            #expect(miscounted.isEmpty, "\(report.text)")
            #expect(results["library-index-photos"]?.value == Double(totals.photos))
            #expect(results["library-index-first"]?.name == "First 400 photos searchable")
            #expect((results["library-index-rate"]?.value ?? 0) > 0)
            #expect(results["library-launch-read"]?.value == 0 && results["library-launch-changed"]?.value == 0)
            #expect((results["library-reconcile-renamed"]?.value ?? 0) >= 3, "\(report.text)")
            let written = try #require(results["library-vanish-written"]).value
            #expect(written > 0 && written < Double(totals.photos), "\(report.text)")
            #expect((results["library-vanish-wait"]?.value ?? .infinity) < 3000)
            #expect(results["library-vanish-online"]?.value == 0)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(folder.url.lastPathComponent + " reconcile") }
        #expect(leftovers.isEmpty)
    }
}
