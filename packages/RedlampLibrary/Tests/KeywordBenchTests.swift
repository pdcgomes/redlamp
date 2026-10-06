import Foundation
import Testing
@testable import RedlampLibrary

/// The keywords scenario, small enough for every run; and at full size with `REDLAMP_KEYWORDS_BENCH=1`
/// (which xcodebuild hands to the tests from `TEST_RUNNER_REDLAMP_KEYWORDS_BENCH=1`), with
/// `REDLAMP_KEYWORDS_BENCH_KEYWORDS` keywords and `REDLAMP_KEYWORDS_BENCH_PHOTOS` photos (100,000 and
/// 10,000 by default).
struct KeywordBenchTests {
    @Test func `the keywords scenario completes, adds a keyword and undoes it, every sidecar as it should be`(
    ) async throws {
        let results = try await KeywordScenario(keywords: 3000, photos: 120, queries: 20).measure()
        let ids = Set(results.map(\.id))
        #expect(ids.isSuperset(of: [
            "library-keywords-completion", "library-keywords-add", "library-keywords-add-index",
            "library-keywords-add-sidecars", "library-keywords-undo", "library-keywords-save-cost",
            "library-keywords-wrong",
        ]))
        let checks = results.filter { $0.budget?.kind == .exactly }
        #expect(checks.count == 2 && checks.allSatisfy { $0.passed == true }, "\(checks)")
    }

    @Test func `the synthetic keywords are many, three levels deep, and a tenth have synonyms`() {
        let keywords = KeywordScenario.keywords(5000)
        #expect(keywords.count == 5000 && Set(keywords.map(\.path)).count == 5000)
        #expect(keywords.allSatisfy { $0.path.depth == 2 })
        #expect((400 ... 600).contains(keywords.count { !$0.synonyms.isEmpty }))
    }

    @Test func `the keywords scenario is registered by name`() {
        BenchScenarios.registerKeywords()
        let scenario = BenchScenarios.named("keywords") as? KeywordScenario
        #expect(scenario?.keywords == KeywordScenario.defaultKeywords && scenario?.photos == KeywordScenario
            .defaultPhotos)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_KEYWORDS_BENCH"] == "1"))
    func `the keywords scenario at full size`() async throws {
        let environment = ProcessInfo.processInfo.environment
        let scenario = KeywordScenario(
            keywords: environment["REDLAMP_KEYWORDS_BENCH_KEYWORDS"].flatMap { Int($0) } ?? KeywordScenario
                .defaultKeywords,
            photos: environment["REDLAMP_KEYWORDS_BENCH_PHOTOS"].flatMap { Int($0) } ?? KeywordScenario.defaultPhotos,
        )
        let report = try await BenchReport(
            fixture: "synthetic keywords and photos", profile: "ssd", photos: scenario.photos,
            results: scenario.measure(),
        )
        for line in report.lines {
            print("KEYWORDS-BENCH \(line)")
        }
        #expect(report.failed.allSatisfy { $0.budget?.kind != .exactly })
    }
}
