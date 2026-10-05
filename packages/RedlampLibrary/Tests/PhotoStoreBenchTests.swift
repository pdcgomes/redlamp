import Foundation
import Testing
@testable import RedlampLibrary

/// The store's scenario, small enough for every run; and at full size with `REDLAMP_STORE_BENCH=1`
/// (which xcodebuild hands to the tests from `TEST_RUNNER_REDLAMP_STORE_BENCH=1`), with
/// `REDLAMP_STORE_BENCH_PHOTOS` keys (100,000 by default) of `REDLAMP_STORE_BENCH_PAYLOAD` bytes,
/// in a store under `REDLAMP_STORE_BENCH_ROOT` (the temporary folder by default).
struct PhotoStoreBenchTests {
    @Test func `the store scenario stores every record and reads each back whole`() throws {
        let folder = try TemporaryFolder()
        let results = try StoreScenario(photos: 3000, payloadBytes: 2000, root: folder.url).measure()
        let ids = Set(results.map(\.id))
        #expect(ids.isSuperset(of: [
            "library-store-write-rate", "library-store-read-rate", "library-store-read-p99", "library-store-table",
        ]))
        let checks = results.filter { $0.budget?.kind == .exactly }
        #expect(checks.count == 2 && checks.allSatisfy { $0.passed == true }, "\(checks)")
        #expect(results.first { $0.id == "library-store-table" }.map { $0.value > 0 && $0.value < 40 } == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).isEmpty)
    }

    @Test func `the store scenario is registered by name`() {
        BenchScenarios.registerStore()
        #expect((BenchScenarios.named("store") as? StoreScenario)?.photos == StoreScenario.defaultPhotos)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_STORE_BENCH"] == "1"))
    func `the store at full size`() throws {
        let environment = ProcessInfo.processInfo.environment
        let scenario = StoreScenario(
            photos: environment["REDLAMP_STORE_BENCH_PHOTOS"].flatMap { Int($0) } ?? StoreScenario.defaultPhotos,
            payloadBytes: environment["REDLAMP_STORE_BENCH_PAYLOAD"].flatMap { Int($0) }
                ?? StoreScenario.defaultPayloadBytes,
            root: environment["REDLAMP_STORE_BENCH_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) },
        )
        let report = try BenchReport(
            fixture: scenario.root?.path ?? "the temporary folder", profile: "ssd", photos: scenario.photos,
            results: scenario.measure(),
        )
        for line in report.lines {
            print("STORE-BENCH \(line)")
        }
        #expect(report.failed.isEmpty)
    }
}
