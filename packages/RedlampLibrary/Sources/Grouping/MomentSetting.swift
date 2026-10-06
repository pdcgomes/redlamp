import Foundation

/// How long a pause in shooting starts a new moment (LIB-41): the Tighter–Looser control, which moves
/// the floor and the multiple together. A pause starts a moment when it's longer than `floor` and
/// longer than `multiple` times the pace of the photos around it, that pace counted as
/// `slowestPace` at most, so a pause past `ceiling` always starts one: otherwise photos a year
/// apart, a year being their pace, would be one moment. Each step looser multiplies the floor by √2
/// and the multiple by ⁴√2: from the default's 60 s and four times (an hour's ceiling), the tightest
/// is 15 s and twice (half an hour) and the loosest 4 minutes and eight times (two hours). Looser
/// never finds more moments among the same photos than tighter.
public struct MomentSetting: Sendable, Hashable, Codable {
    /// The floor, in seconds, and the multiple at the default step: the start the owner's own culled
    /// shoots tune them from (LIB-katami §6).
    public static let defaultFloor: Double = 60
    public static let defaultMultiple: Double = 4
    /// Seconds: the most the pace around a pause counts for.
    public static let slowestPace: Double = 900
    public static let tightest = -4
    public static let loosest = 4

    /// Steps from the default: tighter below 0, looser above, from `tightest` to `loosest`.
    public let looseness: Int

    public init(looseness: Int = 0) {
        self.looseness = min(max(looseness, Self.tightest), Self.loosest)
    }

    /// The shortest pause that starts a moment, in seconds.
    public var floor: Double {
        Self.defaultFloor * pow(2, Double(looseness) / 2)
    }

    /// How many times the pace around it a pause must be to start a moment.
    public var multiple: Double {
        Self.defaultMultiple * pow(2, Double(looseness) / 4)
    }

    /// A pause longer than this, in seconds, starts a moment however slow the photos around it.
    public var ceiling: Double {
        multiple * Self.slowestPace
    }

    private enum CodingKeys: String, CodingKey {
        case looseness
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(looseness: container.decodeIfPresent(Int.self, forKey: .looseness) ?? 0)
    }
}
