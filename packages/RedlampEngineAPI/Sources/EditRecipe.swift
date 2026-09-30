import Foundation

public enum Treatment: String, Codable, Sendable, Hashable, CaseIterable {
    case color
    case blackAndWhite

    public var name: String {
        switch self {
        case .color: "Color"
        case .blackAndWhite: "B&W"
        }
    }
}

/// A reference to a profile, look or LUT.
///
/// Recipes never store file paths: `id` identifies the profile, `contentHash` pins the
/// exact content for imported profiles so a missing or changed file is detectable.
public struct ProfileReference: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// Look strength in percent, 0...200. Calibration-only profiles ignore it.
    public var amount: Double
    public var contentHash: String?

    public init(id: String, name: String, amount: Double = 100, contentHash: String? = nil) {
        self.id = id
        self.name = name
        self.amount = amount
        self.contentHash = contentHash
    }
}

/// A point on the point tone curve, both coordinates in 0...1 (display-referred).
public struct CurvePoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The complete, non-destructive description of an edit.
///
/// Scalar parameters are stored sparsely: only values that differ from their schema
/// default are kept, which keeps sidecars small and lets new parameters be added
/// without migrating old files.
///
/// Two versions describe an edit. `formatVersion` is the file syntax and can be migrated
/// silently. `processVersion` is the rendering behavior the edit was made with: an edit
/// must keep rendering the same way, so it is only ever changed by an explicit update.
public struct EditRecipe: Sendable, Hashable {
    public static let formatVersion = 1
    /// Bumped whenever a change to rendering math would make existing edits look different.
    public static let currentProcessVersion = 1
    public static let linearPointCurve = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    /// Sidecars written before process versions existed are version 1.
    public var processVersion = EditRecipe.currentProcessVersion
    public var treatment: Treatment = .color
    public var profile: ProfileReference = BuiltInProfile.color.reference
    public var whiteBalanceMode: WhiteBalanceMode = .asShot
    public var pointCurve: [CurvePoint] = EditRecipe.linearPointCurve
    public private(set) var values: [ParameterID: Double] = [:]
    /// Local adjustments, applied in order on top of the global edit.
    public var masks: [MaskLayer] = []
    /// Parameters and fields written by a newer Redlamp. They don't affect rendering here,
    /// but are written back unchanged so saving never erases them.
    public private(set) var unknownValues: [String: Double] = [:]
    public private(set) var unknownFields: [String: JSONValue] = [:]

    public init() {}

    /// The edit was made with rendering behavior this build doesn't have.
    public var requiresNewerProcess: Bool {
        processVersion > EditRecipe.currentProcessVersion
    }

    public subscript(parameter: ParameterID) -> Double {
        get { values[parameter] ?? parameter.spec.defaultValue }
        set {
            guard !parameter.isMaskScoped else { return }
            let spec = parameter.spec
            let clamped = spec.clamp(newValue)
            if abs(clamped - spec.defaultValue) < 1e-9 {
                values[parameter] = nil
            } else {
                values[parameter] = clamped
            }
        }
    }

    public func isDefault(_ parameter: ParameterID) -> Bool {
        values[parameter] == nil
    }

    public mutating func reset(_ parameters: some Sequence<ParameterID>) {
        for parameter in parameters {
            values[parameter] = nil
        }
    }

    /// Whether nothing has been changed from a fresh import.
    public var isPristine: Bool {
        values.filter { $0.key != .temperature && $0.key != .tint }.isEmpty
            && treatment == .color
            && profile == BuiltInProfile.color.reference
            && whiteBalanceMode == .asShot
            && pointCurve == EditRecipe.linearPointCurve
            && masks.isEmpty
            && unknownValues.isEmpty
            && unknownFields.isEmpty
    }

    /// Parameters whose value differs from `other`.
    public func parametersChanged(from other: EditRecipe) -> [ParameterID] {
        values.compactMap { other.values[$0.key] == $0.value ? nil : $0.key }
            + other.values.keys.filter { values[$0] == nil }
    }

    public func mask(_ id: UUID) -> MaskLayer? {
        masks.first { $0.id == id }
    }

    public var hasPointCurve: Bool {
        pointCurve != EditRecipe.linearPointCurve
    }
}

// MARK: - Codable

extension EditRecipe: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, processVersion, treatment, profile, whiteBalance, pointCurve, values, masks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        processVersion = try container.decodeIfPresent(Int.self, forKey: .processVersion) ?? 1
        treatment = try container.decodeIfPresent(Treatment.self, forKey: .treatment) ?? .color
        profile = try container.decodeIfPresent(ProfileReference.self, forKey: .profile)
            ?? BuiltInProfile.color.reference
        whiteBalanceMode = try container.decodeIfPresent(WhiteBalanceMode.self, forKey: .whiteBalance) ?? .asShot
        pointCurve = try container.decodeIfPresent([CurvePoint].self, forKey: .pointCurve)
            ?? EditRecipe.linearPointCurve
        let raw = try container.decodeIfPresent([String: Double].self, forKey: .values) ?? [:]
        for (key, value) in raw {
            if let parameter = ParameterID(rawValue: key) {
                self[parameter] = value
            } else {
                unknownValues[key] = value
            }
        }
        masks = try container.decodeIfPresent([MaskLayer].self, forKey: .masks) ?? []
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(EditRecipe.formatVersion, forKey: .version)
        try container.encode(processVersion, forKey: .processVersion)
        try container.encode(treatment, forKey: .treatment)
        try container.encode(profile, forKey: .profile)
        try container.encode(whiteBalanceMode, forKey: .whiteBalance)
        if hasPointCurve {
            try container.encode(pointCurve, forKey: .pointCurve)
        }
        let known = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        try container.encode(unknownValues.merging(known) { _, value in value }, forKey: .values)
        if !masks.isEmpty {
            try container.encode(masks, forKey: .masks)
        }
    }
}
