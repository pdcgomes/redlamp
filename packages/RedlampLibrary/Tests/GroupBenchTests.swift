import Foundation
import Testing
@testable import RedlampLibrary

/// The groups scenario, small enough for every run; and at full size with `REDLAMP_GROUPS_BENCH=1`
/// (which xcodebuild hands to the tests from `TEST_RUNNER_REDLAMP_GROUPS_BENCH=1`), at
/// `REDLAMP_GROUPS_BENCH_PHOTOS` photos (1,000,000 by default).
struct GroupBenchTests {
    @Test func `the groups scenario finds the generator's moments, days and stacks within budget`() async throws {
        let results = try await GroupScenario(photos: 30000).measure(seed: 5)
        let report = BenchReport(fixture: "synthetic photos", profile: "ssd", photos: 30000, results: results)
        #expect(report.failed.isEmpty, "\(report.failed)")
        #expect(results.count { $0.budget?.kind == .exactly } == 11)
        for id in ["list", "close-all", "open-all", "close-one", "open-one", "update"] {
            #expect(results.contains { $0.id == "library-groups-\(id)" && $0.budget != nil }, "\(id)")
        }
        for key in GroupKey.allCases {
            #expect(results.contains { $0.id == "library-groups-\(key.rawValue)" && $0.budget != nil }, "\(key)")
        }
        for id in ["moments", "moment-cameras", "days", "unpicked", "pairs", "bursts"] {
            #expect(try #require(results.first { $0.id == "library-groups-\(id)" }).value > 0, "\(id)")
        }
        let tightest = try #require(results.first { $0.id == "library-groups-tightest" }).value
        #expect(try tightest > (#require(results.first { $0.id == "library-groups-loosest" }).value))
    }

    @Test func `the synthetic sessions are as the scenario says`() {
        let library = SyntheticSessionLibrary(photos: 200_000, seed: 8)
        #expect(library.rows.count == 200_000)
        let expected = library.expected
        #expect(expected.moments == expected.starts.count && expected.starts.last == -1)
        #expect(expected.momentCameras > expected.moments && expected.unpicked > 0 && expected.unpicked < expected
            .moments)
        let jpegs = library.rows.count { $0.hot.name.hasSuffix(".JPG") }
        #expect(jpegs == expected.pairs && expected.bursts > 0)
        #expect(library.rows.contains { $0.hot.captured == nil })
    }

    @Test func `the groups scenario is registered by name`() {
        BenchScenarios.registerGroups()
        #expect((BenchScenarios.named("groups") as? GroupScenario)?.photos == GroupScenario.defaultPhotos)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_GROUPS_BENCH"] == "1"))
    func `groups at full size`() async throws {
        let photos = ProcessInfo.processInfo.environment["REDLAMP_GROUPS_BENCH_PHOTOS"].flatMap { Int($0) }
            ?? GroupScenario.defaultPhotos
        let report = try await BenchReport(
            fixture: "synthetic photos", profile: "ssd", photos: photos,
            results: GroupScenario(photos: photos).measure(),
        )
        for line in report.lines {
            print("GROUPS-BENCH \(line)")
        }
        #expect(report.failed.isEmpty)
    }
}
