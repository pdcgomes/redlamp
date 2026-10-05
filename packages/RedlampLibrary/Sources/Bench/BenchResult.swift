import Foundation

/// A target a measurement must meet.
public struct BenchBudget: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case below, atLeast, exactly
    }

    public let kind: Kind
    public let value: Double
    public let unit: String

    public static func below(_ value: Double, _ unit: String) -> BenchBudget {
        BenchBudget(kind: .below, value: value, unit: unit)
    }

    public static func atLeast(_ value: Double, _ unit: String) -> BenchBudget {
        BenchBudget(kind: .atLeast, value: value, unit: unit)
    }

    /// For counts that must match a fixture's manifest.
    public static func exactly(_ value: Double, _ unit: String) -> BenchBudget {
        BenchBudget(kind: .exactly, value: value, unit: unit)
    }

    public func isMet(by measured: Double) -> Bool {
        switch kind {
        case .below: measured < value
        case .atLeast: measured >= value
        case .exactly: measured == value
        }
    }

    /// `under 300 ms`, `at least 2,000 photos/s`, `exactly 20,000 photos`.
    public var target: String {
        let amount = BenchResult.format(value, unit)
        return switch kind {
        case .below: "under \(amount)"
        case .atLeast: "at least \(amount)"
        case .exactly: "exactly \(amount)"
        }
    }
}

/// One measurement of a scenario, and its budget if it has one.
public struct BenchResult: Sendable, Hashable, Codable {
    public let scenario: String
    /// The metric's ID, as docs/performance/metrics.json names the library's (`library-list`).
    public let id: String
    /// What was measured, as the report says it.
    public let name: String
    public let value: Double
    public let unit: String
    public let budget: BenchBudget?

    public init(scenario: String, id: String, name: String, value: Double, unit: String, budget: BenchBudget? = nil) {
        self.scenario = scenario
        self.id = id
        self.name = name
        self.value = value
        self.unit = unit
        self.budget = budget
    }

    /// Nil when there's no budget.
    public var passed: Bool? {
        budget.map { $0.isMet(by: value) }
    }

    public var measured: String {
        Self.format(value, unit)
    }

    /// Milliseconds and seconds to a tenth; everything else whole, with thousands separated,
    /// unless it's small.
    static func format(_ value: Double, _ unit: String) -> String {
        if unit == "ms" || unit == "s" {
            return String(format: "%.1f %@", value, unit)
        }
        if value.rounded() == value || abs(value) >= 100 {
            return "\(grouped(Int(value.rounded()))) \(unit)"
        }
        return String(format: "%.2f %@", value, unit)
    }

    static func grouped(_ value: Int) -> String {
        let digits = Array(String(value.magnitude))
        var text = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 {
                text += ","
            }
            text.append(digit)
        }
        return value < 0 ? "-" + text : text
    }
}
