import Foundation
import Testing
@testable import RedlampLibrary

/// Library Health's checks that use only the index against LIB-39's budget (LIB-40): a million photos
/// in under a second, off the main thread. The pairs check on a synthetic library a fifth of whose
/// shots are a raw and its JPEG, small enough for every run; at full size with
/// `REDLAMP_HEALTH_BENCH=1` (which xcodebuild hands to the tests from `TEST_RUNNER_REDLAMP_HEALTH_BENCH=1`),
/// at `REDLAMP_HEALTH_BENCH_PHOTOS` photos (1,000,000 by default).
struct HealthBenchTests {
    /// The pairs check under each rule on `photos` synthetic photos, timed off the main thread from the
    /// column store to the findings: how many it found, and how long the slowest rule took.
    static func pairs(photos: Int) async -> (findings: [PairRule: Int], pairs: Int, slowest: Duration) {
        let library = SyntheticStackLibrary(photos: photos, seed: 5)
        let store = library.store()
        let names = library.names()
        return await Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            var found: [PairRule: Int] = [:]
            var slowest = Duration.zero
            for rule in [PairRule.keepRaw, .keepJPEG] {
                let started = clock.now
                let stacks = StackFinder.find(in: store, names: names, choices: library.choices)
                let drops = HealthChecker.drops(rule, in: stacks, store: store)
                let findings = HealthChecker.findings(
                    rule, drops: drops, store: store, names: names, texts: [:], isKept: { _ in false },
                )
                slowest = max(slowest, clock.now - started)
                found[rule] = findings.findings.count
            }
            return (found, library.pairs, slowest)
        }.value
    }

    @Test func `the pairs check proposes one half of each of the synthetic library's pairs`() async {
        let (findings, pairs, _) = await Self.pairs(photos: 20000)
        #expect(pairs > 2000)
        #expect(findings[.keepRaw] == pairs && findings[.keepJPEG] == pairs)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_HEALTH_BENCH"] == "1"))
    func `the pairs check at full size, within LIB-39's budget`() async {
        let photos = ProcessInfo.processInfo.environment["REDLAMP_HEALTH_BENCH_PHOTOS"].flatMap { Int($0) }
            ?? 1_000_000
        let (findings, pairs, slowest) = await Self.pairs(photos: photos)
        print("HEALTH-BENCH pairs of \(photos) photos: \(pairs) pairs, \(findings) findings, slowest \(slowest)")
        #expect(slowest < .seconds(1))
    }
}
