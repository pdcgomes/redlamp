import Foundation

/// What `redlamp library bench` measured on a fixture: one line per measurement, those with a
/// budget ending PASS or FAIL, then whether every budget was met.
public struct BenchReport: Sendable, Codable {
    public var fixture: String
    public var profile: String
    public var photos: Int
    public var results: [BenchResult]

    public init(fixture: String, profile: String, photos: Int, results: [BenchResult]) {
        self.fixture = fixture
        self.profile = profile
        self.photos = photos
        self.results = results
    }

    /// Runs `scenarios` one after another on `context`'s fixture.
    public static func run(_ scenarios: [any BenchScenario], in context: BenchContext) async throws -> BenchReport {
        var results: [BenchResult] = []
        for scenario in scenarios {
            results += try await scenario.run(context)
        }
        return BenchReport(
            fixture: context.fixture.path, profile: context.profile.name, photos: context.manifest.totals.photos,
            results: results,
        )
    }

    public var failed: [BenchResult] {
        results.filter { $0.passed == false }
    }

    /// `Budgets: all passed` or `Budgets: 2 failed`.
    public var verdict: String {
        failed.isEmpty ? "Budgets: all passed" : "Budgets: \(failed.count) failed"
    }

    public var exitStatus: Int32 {
        failed.isEmpty ? 0 : 1
    }

    public var lines: [String] {
        let scenarioWidth = results.map(\.scenario.count).max() ?? 0
        let nameWidth = results.map(\.name.count).max() ?? 0
        let measuredWidth = results.map(\.measured.count).max() ?? 0
        let header = "\(BenchResult.grouped(photos)) photos in \(fixture), on a simulated \(profile) volume"
        return [header] + results.map { result in
            let line = "  " + Self.padded(result.scenario, scenarioWidth) + "  " + Self.padded(result.name, nameWidth)
                + "  " + String(repeating: " ", count: measuredWidth - result.measured.count) + result.measured
            guard let budget = result.budget, let passed = result.passed else { return line }
            return line + "  (\(budget.target))  " + (passed ? "PASS" : "FAIL")
        } + [verdict]
    }

    public var text: String {
        lines.joined(separator: "\n")
    }

    /// The report as JSON, with each measurement by its ID under `metrics` for
    /// scripts/perf-record.sh.
    public func json() throws -> Data {
        struct Output: Encodable {
            let tool = "redlamp library bench"
            let report: BenchReport
            let metrics: [String: Double]
            let failed: Int
        }
        let metrics = Dictionary(results.map { ($0.id, $0.value) }) { first, _ in first }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Output(report: self, metrics: metrics, failed: failed.count))
    }

    private static func padded(_ text: String, _ width: Int) -> String {
        text.count < width ? text + String(repeating: " ", count: width - text.count) : text
    }
}
