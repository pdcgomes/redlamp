import Foundation
import Testing
@testable import RedlampLibrary

/// The naming scenario, small enough for every run; and at full size with `REDLAMP_NAMING_BENCH=1`
/// (which xcodebuild hands to the tests from `TEST_RUNNER_REDLAMP_NAMING_BENCH=1`), with
/// `REDLAMP_NAMING_BENCH_PHOTOS` files named as templates are typed (10,000 by default) and
/// `REDLAMP_NAMING_BENCH_MANY` named at once (1,000,000).
struct NamingBenchTests {
    @Test func `the naming scenario gives each file the only name in its folder and keeps pairs together`(
    ) async throws {
        let results = try await NamingScenario(photos: 1200, many: 9000).measure(seed: 4)
        let ids = Set(results.map(\.id))
        #expect(ids.isSuperset(of: [
            "library-naming-preview", "library-naming-preview-p50", "library-naming-many", "library-naming-many-job",
            "library-naming-many-names", "library-naming-duplicates", "library-naming-split-pairs",
        ]))
        let checks = results.filter { $0.budget?.kind == .exactly }
        #expect(checks.count == 2 && checks.allSatisfy { $0.passed == true }, "\(checks)")
        #expect(try #require(results.first { $0.id == "library-naming-preview-numbered" }).value > 0)
    }

    @Test func `the synthetic photos pair a fifth of them with a JPEG, and list each folder's files`() {
        let (files, existing) = NamingScenario.photos(1200, seed: 4)
        #expect(files.count == 1200)
        let raws = files.filter { $0.fields.name.hasSuffix(".ARW") }
        #expect(raws.count == 200)
        #expect(raws.allSatisfy { raw in
            existing[raw.fields.folder]?.contains(NamingJob.split(raw.fields.name).base + ".JPG") == true
        })
        #expect(existing.values.allSatisfy { $0.contains("Notes.txt") })
        #expect(files
            .contains { ($0.fields.captured?.timeIntervalSince1970 ?? 0).truncatingRemainder(dividingBy: 1) > 0 })
    }

    @Test func `the naming scenario is registered by name`() {
        BenchScenarios.registerNaming()
        #expect((BenchScenarios.named("naming") as? NamingScenario)?.photos == NamingScenario.defaultPhotos)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_NAMING_BENCH"] == "1"))
    func `naming at full size`() async throws {
        let environment = ProcessInfo.processInfo.environment
        let scenario = NamingScenario(
            photos: environment["REDLAMP_NAMING_BENCH_PHOTOS"].flatMap { Int($0) } ?? NamingScenario.defaultPhotos,
            many: environment["REDLAMP_NAMING_BENCH_MANY"].flatMap { Int($0) } ?? NamingScenario.defaultMany,
        )
        let report = try await BenchReport(
            fixture: "synthetic photos", profile: "ssd", photos: scenario.photos, results: scenario.measure(),
        )
        for line in report.lines {
            print("NAMING-BENCH \(line)")
        }
        #expect(report.failed.isEmpty)
    }
}
