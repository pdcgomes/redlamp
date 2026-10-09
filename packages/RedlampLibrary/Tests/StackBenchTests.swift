import Foundation
import Testing
@testable import RedlampLibrary

/// The stacks scenario, small enough for every run; and at full size with `REDLAMP_STACKS_BENCH=1`
/// (which xcodebuild hands to the tests from `TEST_RUNNER_REDLAMP_STACKS_BENCH=1`), at
/// `REDLAMP_STACKS_BENCH_PHOTOS` photos (1,000,000 by default).
struct StackBenchTests {
    @Test func `the stacks scenario finds the generator's stacks, and its diffs put every cell in place`() async throws {
        let results = try await StackScenario(photos: 20000).measure(seed: 3)
        let report = BenchReport(fixture: "synthetic photos", profile: "ssd", photos: 20000, results: results)
        #expect(report.failed.allSatisfy { $0.budget?.kind != .exactly }, "\(report.failed)")
        #expect(results.count { $0.budget?.kind == .exactly } == 5)
        for id in [
            "library-stacks-find", "library-stacks-closed", "library-stacks-open-all", "library-stacks-close-all",
            "library-stacks-open-one", "library-stacks-close-one",
        ] {
            #expect(results.contains { $0.id == id && $0.budget != nil }, "\(id)")
        }
        for kind in Stack.Kind.allCases {
            #expect(try #require(results.first { $0.id == "library-stacks-\(kind.rawValue)" }).value > 0, "\(kind)")
        }
    }

    @Test(.measuresSpeed)
    func `the stacks scenario keeps within its time budgets`() async throws {
        let results = try await StackScenario(photos: 20000).measure(seed: 3)
        let report = BenchReport(fixture: "synthetic photos", profile: "ssd", photos: 20000, results: results)
        #expect(report.failed.isEmpty, "\(report.failed)")
    }

    @Test func `the synthetic library pairs a fifth of its shots, in folders from one camera`() {
        let library = SyntheticStackLibrary(photos: 20000, seed: 9)
        #expect(library.rows.count == 20000)
        let jpegs = library.rows.count { $0.hot.name.hasSuffix(".JPG") }
        #expect(jpegs == library.pairs && jpegs > 2000 && jpegs < 5000)
        let cameras = Dictionary(grouping: library.rows, by: \.hot.folder).mapValues { Set($0.map(\.hot.camera)) }
        #expect(cameras.values.allSatisfy { $0.count == 1 })
        #expect(library.bursts > 0 && library.brackets > 0 && library.manual > 0)
        #expect(library.choices.choices.values.count(where: \.top) == library.manual)
    }

    @Test func `the stacks scenario is registered by name`() {
        BenchScenarios.registerStacks()
        #expect((BenchScenarios.named("stacks") as? StackScenario)?.photos == StackScenario.defaultPhotos)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_STACKS_BENCH"] == "1"))
    func `stacks at full size`() async throws {
        let photos = ProcessInfo.processInfo.environment["REDLAMP_STACKS_BENCH_PHOTOS"].flatMap { Int($0) }
            ?? StackScenario.defaultPhotos
        let report = try await BenchReport(
            fixture: "synthetic photos", profile: "ssd", photos: photos,
            results: StackScenario(photos: photos).measure(),
        )
        for line in report.lines {
            print("STACKS-BENCH \(line)")
        }
        #expect(report.failed.isEmpty)
    }
}
