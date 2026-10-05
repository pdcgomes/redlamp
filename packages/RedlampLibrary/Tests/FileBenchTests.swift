import Foundation
import Testing
@testable import RedlampLibrary

/// The files scenario, small enough for every run; and at full size with `REDLAMP_FILES_BENCH=1`
/// (which xcodebuild hands to the tests from `TEST_RUNNER_REDLAMP_FILES_BENCH=1`), with
/// `REDLAMP_FILES_BENCH_PHOTOS` photos (10,000 by default).
struct FileBenchTests {
    @Test func `the files scenario renames, undoes and recovers without losing a photo or a sidecar`() async throws {
        let results = try await FilesScenario(photos: 240).measure()
        let ids = Set(results.map(\.id))
        #expect(ids.isSuperset(of: [
            "library-files-rename", "library-files-undo", "library-files-rename-cost", "library-files-recover-finish",
            "library-files-recover-roll-back", "library-files-lost", "library-files-apart", "library-files-settled",
        ]))
        let checks = results.filter { $0.budget?.kind == .exactly }
        #expect(checks.count == 3 && checks.allSatisfy { $0.passed == true }, "\(checks)")
        #expect(try #require(results.first { $0.id == "library-files-original-names" }).value == 240)
    }

    @Test func `the scenario's shots pair a fifth of them, and give half a sidecar and a tenth an xmp`() {
        let shots = FilesScenario.shots(1000)
        #expect(shots.count == 1000 && Set(shots.map(\.path)).count == 1000)
        #expect(shots.filter { $0.path.hasSuffix(".ARW") }.count == 167)
        #expect(shots.filter(\.sidecar).count == 500 && shots.filter(\.xmp).count == 100)
        #expect(Set(shots.map { FilePlanner.split($0.path).folder }).count == 2)
    }

    @Test func `the files scenario is registered by name`() {
        BenchScenarios.registerFiles()
        #expect((BenchScenarios.named("files") as? FilesScenario)?.photos == FilesScenario.defaultPhotos)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLAMP_FILES_BENCH"] == "1"))
    func `the files scenario at full size`() async throws {
        let environment = ProcessInfo.processInfo.environment
        let scenario = FilesScenario(
            photos: environment["REDLAMP_FILES_BENCH_PHOTOS"].flatMap { Int($0) } ?? FilesScenario.defaultPhotos,
        )
        let report = try await BenchReport(
            fixture: "synthetic photos", profile: "ssd", photos: scenario.photos, results: scenario.measure(),
        )
        for line in report.lines {
            print("FILES-BENCH \(line)")
        }
        #expect(report.failed.allSatisfy { $0.budget?.kind != .exactly })
    }
}
