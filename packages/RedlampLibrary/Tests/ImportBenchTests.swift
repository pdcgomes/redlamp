import Foundation
import Testing
@testable import RedlampLibrary

/// The import scenario, small enough for every run; and at full size with `REDLAMP_IMPORT_BENCH=1`
/// (which xcodebuild hands to the tests from `TEST_RUNNER_REDLAMP_IMPORT_BENCH=1`), with
/// `REDLAMP_IMPORT_BENCH_PHOTOS` photos (2,000 by default).
struct ImportBenchTests {
    @Test func `the import scenario browses, copies and verifies a card, then skips all of it the second time`(
    ) async throws {
        let results = try await ImportScenario(photos: 120, rawFolder: FixtureTests.rawFolder).measure()
        let ids = Set(results.map(\.id))
        #expect(ids.isSuperset(of: [
            "library-import-first-previews", "library-import-browse", "library-import-copy", "library-import-rate",
            "library-import-again", "library-import-again-skipped", "library-import-verified", "library-import-safe",
        ]))
        let checks = results.filter { $0.budget?.kind == .exactly }
        #expect(checks.count == 6 && checks.allSatisfy { $0.passed == true }, "\(checks)")
    }

    @Test func `the scenario's card has a raw of each kind beside its JPEG among camera JPEGs`() {
        let raws = SimulatedCard.raws(in: FixtureTests.rawFolder)
        let shots = SimulatedCard.shots(2000, raws: raws)
        #expect(shots.count == 2000 && Set(shots.map(\.name)).count == 2000)
        #expect(shots.count { $0.raw != nil } == raws.count && Set(raws.map { $0.pathExtension.lowercased() })
            .count == raws.count)
        #expect(Set(shots.map { Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: $0.captured).day })
            .count == 2)
    }

    @Test func `the import scenario is registered by name`() {
        BenchScenarios.registerImport()
        #expect((BenchScenarios.named("import") as? ImportScenario)?.photos == ImportScenario.defaultPhotos)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_IMPORT_BENCH"] == "1"))
    func `the import scenario at full size`() async throws {
        let environment = ProcessInfo.processInfo.environment
        let scenario = ImportScenario(
            photos: environment["REDLAMP_IMPORT_BENCH_PHOTOS"].flatMap { Int($0) } ?? ImportScenario.defaultPhotos,
            rawFolder: FixtureTests.rawFolder,
        )
        let report = try await BenchReport(
            fixture: "a simulated card", profile: "card", photos: scenario.photos, results: scenario.measure(),
        )
        for line in report.lines {
            print("IMPORT-BENCH \(line)")
        }
        #expect(report.failed.allSatisfy { $0.budget?.kind != .exactly })
    }
}
