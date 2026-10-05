import Foundation
import Testing
@testable import RedlampLibrary

struct BenchTests {
    static let results = [
        BenchResult(
            scenario: "listing", id: "library-list", name: "All 50,000 photos listed", value: 209.34, unit: "ms",
            budget: .below(300, "ms"),
        ),
        BenchResult(
            scenario: "listing", id: "library-list-rate", name: "Photos listed a second", value: 238_891.4,
            unit: "photos/s",
        ),
        BenchResult(
            scenario: "fixture-check", id: "library-fixture-photos", name: "Photos", value: 49999, unit: "photos",
            budget: .exactly(50000, "photos"),
        ),
    ]

    @Test func `budgets are met as their kind says`() {
        #expect(BenchBudget.below(300, "ms").isMet(by: 299.9))
        #expect(!BenchBudget.below(300, "ms").isMet(by: 300))
        #expect(BenchBudget.atLeast(2000, "photos/s").isMet(by: 2000))
        #expect(!BenchBudget.atLeast(2000, "photos/s").isMet(by: 1999.9))
        #expect(BenchBudget.exactly(20000, "photos").isMet(by: 20000))
        #expect(!BenchBudget.exactly(20000, "photos").isMet(by: 20001))
        #expect(BenchBudget.atLeast(166_666.7, "photos/s").target == "at least 166,667 photos/s")
        #expect(BenchBudget.below(120, "ms").target == "under 120.0 ms")
    }

    @Test func `a report ends each budget's line with PASS or FAIL, and its last line counts the failures`() {
        let report = BenchReport(fixture: "/tmp/lib-50k", profile: "ssd", photos: 50000, results: Self.results)
        let lines = report.lines
        #expect(lines.count == 5)
        #expect(lines[1].hasSuffix("  PASS") && lines[1].contains("209.3 ms") && lines[1].contains("(under 300.0 ms)"))
        #expect(!lines[2].hasSuffix("PASS") && !lines[2].hasSuffix("FAIL") && lines[2].hasSuffix("238,891 photos/s"))
        #expect(lines[3].hasSuffix("  FAIL") && lines[3].contains("49,999 photos  (exactly 50,000 photos)"))
        #expect(lines[4] == "Budgets: 1 failed")
        #expect(report.failed.map(\.id) == ["library-fixture-photos"])
        #expect(report.exitStatus == 1)

        let passing = BenchReport(fixture: "/tmp/lib-50k", profile: "ssd", photos: 50000, results: [Self.results[0]])
        #expect(passing.lines.last == "Budgets: all passed")
        #expect(passing.exitStatus == 0)
    }

    @Test func `the JSON report has every measurement and its budget, and each metric by its ID`() throws {
        let report = BenchReport(fixture: "/tmp/lib-50k", profile: "nas", photos: 50000, results: Self.results)
        let json = try #require(try JSONSerialization.jsonObject(with: report.json()) as? [String: Any])
        #expect(json["tool"] as? String == "redlamp library bench")
        #expect(json["failed"] as? Int == 1)
        #expect((json["metrics"] as? [String: Double])?["library-list"] == 209.34)
        let decoded = try JSONDecoder().decode([String: BenchReport].self, from: JSONSerialization.data(
            withJSONObject: ["report": #require(json["report"])],
        ))
        #expect(decoded["report"]?.results == report.results)
        #expect(decoded["report"]?.profile == "nas")
    }

    @Test func `the listing and fixture-check scenarios measure a fixture and check it against its manifest`(
    ) async throws {
        let folder = try TemporaryFolder()
        let summary = try LibraryFixture(spec: .init(photos: 200, seed: 11)).write(to: folder.url)
        for profile in [VolumeProfile.ssd, .nas] {
            let context = BenchContext(fixture: folder.url, manifest: summary.manifest, profile: profile)
            let report = try await BenchReport.run([ListingScenario(), FixtureCheckScenario()], in: context)
            let listed = try #require(report.results.first { $0.id == "library-list" })
            #expect(listed.name == "All 200 photos listed")
            #expect((listed.budget != nil) == (profile == .ssd))
            let folders = report.results.first { $0.id == "library-list-folders" }?.value
            #expect(folders == Double(summary.manifest.totals.folders + 1))
            let checks = report.results.filter { $0.scenario == "fixture-check" }
            #expect(checks.count == 8 && checks.allSatisfy { $0.passed == true })
        }
    }

    @Test func `fixture-check fails when the disk no longer matches the manifest`() async throws {
        let folder = try TemporaryFolder()
        let fixture = LibraryFixture(spec: .init(photos: 100, seed: 12))
        let summary = try fixture.write(to: folder.url)
        let removed = fixture.photo(at: 50)
        try FileManager.default.removeItem(at: folder.url.appending(path: removed.path))
        let context = BenchContext(fixture: folder.url, manifest: summary.manifest, profile: .ssd)
        let report = try await BenchReport.run([FixtureCheckScenario()], in: context)
        let kind = removed.kind == .heic ? "heics" : "jpegs"
        #expect(report.failed.map(\.id).sorted() == [
            "library-fixture-differing", "library-fixture-\(kind)", "library-fixture-photos",
        ])
        #expect(report.lines.last == "Budgets: 3 failed")
        #expect(report.exitStatus == 1)
    }

    @Test func `a walk through a volume that has gone throws`() async throws {
        let folder = try TemporaryFolder()
        let summary = try LibraryFixture(spec: .init(photos: 50, seed: 13)).write(to: folder.url)
        let gone = VolumeProfile.nas.disconnecting(.init(.afterOperations(2)))
        let context = BenchContext(fixture: folder.url, manifest: summary.manifest, profile: gone)
        await #expect(throws: LibraryFileSystemError.self) { try await ListingScenario().run(context) }
    }

    @Test func `scenarios are found by name, and later rows add their own`() {
        #expect(BenchScenarios.named("listing") is ListingScenario)
        #expect(BenchScenarios.named("fixture-check") is FixtureCheckScenario)
        #expect(Array(BenchScenarios.all.map(\.name).prefix(2)) == ["listing", "fixture-check"])

        struct Probe: BenchScenario {
            let name = "test-probe"
            func run(_: BenchContext) async throws -> [BenchResult] {
                [BenchResult(scenario: name, id: "probe", name: "Probe", value: 1, unit: "probes")]
            }
        }
        BenchScenarios.register(Probe())
        #expect(BenchScenarios.named("test-probe") is Probe)
    }
}
