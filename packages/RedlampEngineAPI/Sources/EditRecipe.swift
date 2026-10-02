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

/// A point on the point tone curve, both coordinates in 0...1 (display-referred).
public struct CurvePoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Which shared recipe an edit came from. Provenance only: rendering never reads it.
public struct AppliedRecipe: Codable, Sendable, Hashable {
    public var id: String
    public var version: Int
    public var name: String
    /// The recipe's Amount when it was applied, in percent.
    public var amount: Double

    public init(id: String, version: Int, name: String, amount: Double = 100) {
        self.id = id
        self.version = version
        self.name = name
        self.amount = amount
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
    /// Version 2 renamed `profile` to `baseLook` and namespaced built-in look ids. Version 3
    /// added brush, range and AI mask components, whose bitmaps live in a sidecar package.
    public static let formatVersion = 3
    /// Bumped whenever a change to rendering math would make existing edits look different.
    /// 2: grain is sized to the frame rather than the sensor's pixels, and is strongest in the
    /// low midtones and shadows, as film's is.
    /// 3: a bitmap (JPEG, HEIC, PNG, TIFF) renders as the file at default settings, and halation
    /// boosts only small clipped lights, not a clipped sky.
    /// 4: a DNG's embedded camera profile corrects its colour with the profile's HueSatMap.
    /// 5: the lens correction the file carries (DNG opcodes, Sony's tags) applies by default.
    public static let currentProcessVersion = 5
    public static let linearPointCurve = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    /// Sidecars written before process versions existed are version 1.
    public var processVersion = EditRecipe.currentProcessVersion
    public var treatment: Treatment = .color
    public var baseLook: BaseLookReference = BuiltInBaseLook.color.reference
    public var whiteBalanceMode: WhiteBalanceMode = .asShot
    public var pointCurve: [CurvePoint] = EditRecipe.linearPointCurve
    public private(set) var values: [ParameterID: Double] = [:]
    /// Local adjustments, applied in order on top of the global edit.
    public var masks: [MaskLayer] = []
    /// The shared recipe this edit was last built from.
    public var appliedRecipe: AppliedRecipe?
    /// The crop, in the straightened frame (see `GeometryMap`); its angle is `cropAngle`.
    public var crop: CropRect = .full
    /// The user's rotation and flip, after the camera's orientation.
    public var orientation: ImageOrientation = .identity
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
            && baseLook == BuiltInBaseLook.color.reference
            && whiteBalanceMode == .asShot
            && pointCurve == EditRecipe.linearPointCurve
            && masks.isEmpty
            && appliedRecipe == nil
            && crop.isFull
            && orientation.isIdentity
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
        case version, processVersion, treatment, baseLook, whiteBalance, pointCurve, values, masks, appliedRecipe
        case crop, orientation
        /// Format version 1's name for `baseLook`; read, never written.
        case profile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        processVersion = try container.decodeIfPresent(Int.self, forKey: .processVersion) ?? 1
        treatment = try container.decodeIfPresent(Treatment.self, forKey: .treatment) ?? .color
        baseLook = try container.decodeIfPresent(BaseLookReference.self, forKey: .baseLook)
            ?? container.decodeIfPresent(BaseLookReference.self, forKey: .profile)
            ?? BuiltInBaseLook.color.reference
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
        appliedRecipe = try container.decodeIfPresent(AppliedRecipe.self, forKey: .appliedRecipe)
        crop = try container.decodeIfPresent(CropRect.self, forKey: .crop) ?? .full
        orientation = try container.decodeIfPresent(ImageOrientation.self, forKey: .orientation) ?? .identity
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
        try container.encode(baseLook, forKey: .baseLook)
        try container.encode(whiteBalanceMode, forKey: .whiteBalance)
        if hasPointCurve {
            try container.encode(pointCurve, forKey: .pointCurve)
        }
        let known = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        try container.encode(unknownValues.merging(known) { _, value in value }, forKey: .values)
        if !masks.isEmpty {
            try container.encode(masks, forKey: .masks)
        }
        try container.encodeIfPresent(appliedRecipe, forKey: .appliedRecipe)
        if !crop.isFull {
            try container.encode(crop, forKey: .crop)
        }
        if !orientation.isIdentity {
            try container.encode(orientation, forKey: .orientation)
        }
    }
}
