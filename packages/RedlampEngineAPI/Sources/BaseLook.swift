import Foundation

/// A reference from an edit to the Base Look it renders with (Lightroom's "profile").
///
/// Edits never store file paths. `id` and `version` identify the look; `contentHash` pins
/// the exact look table for looks that have one, so a missing or changed file is detected
/// instead of silently rendering differently.
public struct BaseLookReference: Sendable, Hashable {
    public var id: String
    /// Published versions of a look never change; improvements ship as a new version.
    public var version: Int
    public var name: String
    /// Look strength in percent, 0...200.
    public var amount: Double
    public var contentHash: String?

    public static let amountRange: ClosedRange<Double> = 0 ... 200

    public init(id: String, version: Int = 1, name: String, amount: Double = 100, contentHash: String? = nil) {
        self.id = id
        self.version = version
        self.name = name
        self.amount = min(max(amount, Self.amountRange.lowerBound), Self.amountRange.upperBound)
        self.contentHash = contentHash
    }

    /// The same look at another strength.
    public func withAmount(_ amount: Double) -> BaseLookReference {
        var copy = self
        copy.amount = min(max(amount, Self.amountRange.lowerBound), Self.amountRange.upperBound)
        return copy
    }

    /// The id prefix of looks baked from photos' embedded camera profiles.
    public static let embeddedIDPrefix = "local/embedded/"

    /// Whether the look came from a photo's embedded camera profile.
    public var isEmbedded: Bool {
        id.hasPrefix(Self.embeddedIDPrefix)
    }

    /// Whether it's Redlamp Reproduction, which has no tone curve.
    public var isReproduction: Bool {
        BuiltInBaseLook(reference: self) == .reproduction
    }

    /// Whether `other` names the same look and version, whatever its strength.
    public func isSameLook(as other: BaseLookReference) -> Bool {
        id == other.id && version == other.version && contentHash == other.contentHash
    }
}

extension BaseLookReference: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, version, name, amount, contentHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedID = try container.decode(String.self, forKey: .id)
        let builtIn = BuiltInBaseLook(legacyID: storedID)
        id = builtIn?.rawValue ?? storedID
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? builtIn?.name ?? storedID
        amount = try container.decodeIfPresent(Double.self, forKey: .amount) ?? 100
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encode(name, forKey: .name)
        try container.encode(amount, forKey: .amount)
        try container.encodeIfPresent(contentHash, forKey: .contentHash)
    }
}

/// Redlamp's own parametric base looks. Imported and LUT-backed looks sit alongside
/// these, supplied to the engine as `BaseLookDefinition`s.
public enum BuiltInBaseLook: String, CaseIterable, Sendable {
    case color = "redlamp/base/color"
    case neutral = "redlamp/base/neutral"
    case vivid = "redlamp/base/vivid"
    case landscape = "redlamp/base/landscape"
    case portrait = "redlamp/base/portrait"
    case monochrome = "redlamp/base/monochrome"
    case reproduction = "redlamp/base/reproduction"

    /// The id sidecars used before looks were namespaced and versioned (`redlamp.color`).
    public init?(legacyID: String) {
        if let current = BuiltInBaseLook(rawValue: legacyID) {
            self = current
            return
        }
        guard legacyID.hasPrefix("redlamp."),
              let look = BuiltInBaseLook(rawValue: "redlamp/base/" + legacyID.dropFirst("redlamp.".count))
        else { return nil }
        self = look
    }

    public var name: String {
        switch self {
        case .color: "Redlamp Color"
        case .neutral: "Redlamp Neutral"
        case .vivid: "Redlamp Vivid"
        case .landscape: "Redlamp Landscape"
        case .portrait: "Redlamp Portrait"
        case .monochrome: "Redlamp Monochrome"
        case .reproduction: "Redlamp Reproduction"
        }
    }

    public var summary: String {
        switch self {
        case .color: "Redlamp's default rendering: natural contrast and color."
        case .neutral: "Low contrast and restrained color, a flat start for heavy editing."
        case .vivid: "More contrast and saturation for punchy results."
        case .landscape: "Richer greens and blues with a little extra contrast."
        case .portrait: "Softer contrast and gentle, even skin tones."
        case .monochrome: "A balanced black-and-white conversion."
        case .reproduction: "No tone curve: every tone renders as measured, for copying artwork from a target. Anything brighter than white turns white."
        }
    }

    /// The only published version; a changed rendering would ship as version 2.
    public var version: Int {
        1
    }

    public var reference: BaseLookReference {
        BaseLookReference(id: rawValue, version: version, name: name)
    }

    public init?(reference: BaseLookReference) {
        guard let look = BuiltInBaseLook(rawValue: reference.id), reference.version == look.version else { return nil }
        self = look
    }

    public var parameters: BaseLookParameters {
        switch self {
        case .color: BaseLookParameters(contrast: 1.0, saturation: 1.0, warmth: 0)
        case .neutral: BaseLookParameters(contrast: 0.72, saturation: 0.9, warmth: 0)
        case .vivid: BaseLookParameters(contrast: 1.15, saturation: 1.28, warmth: 0)
        case .landscape: BaseLookParameters(contrast: 1.08, saturation: 1.15, warmth: -0.02, greenBoost: 0.12)
        case .portrait: BaseLookParameters(contrast: 0.9, saturation: 0.94, warmth: 0.03, skinSoftening: 0.25)
        case .monochrome: BaseLookParameters(contrast: 1.05, saturation: 0, warmth: 0, isMonochrome: true)
        case .reproduction: .identity
        }
    }

    public var definition: BaseLookDefinition {
        BaseLookDefinition(id: rawValue, version: version, name: name, parameters: parameters)
    }
}

/// The parametric part of a Base Look, applied on top of the camera's calibration.
public struct BaseLookParameters: Sendable, Hashable {
    /// Multiplier on the base tone curve's contrast.
    public var contrast: Double
    /// Chroma multiplier.
    public var saturation: Double
    /// Shift along the blue–yellow axis, in OKLab units.
    public var warmth: Double
    /// Extra chroma for greens and aquas.
    public var greenBoost: Double
    /// Pulls chroma out of skin hues.
    public var skinSoftening: Double
    public var isMonochrome: Bool

    public static let identity = BaseLookParameters(contrast: 1, saturation: 1, warmth: 0)

    public init(
        contrast: Double,
        saturation: Double,
        warmth: Double,
        greenBoost: Double = 0,
        skinSoftening: Double = 0,
        isMonochrome: Bool = false,
    ) {
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
        self.greenBoost = greenBoost
        self.skinSoftening = skinSoftening
        self.isMonochrome = isMonochrome
    }

    /// The look at a strength in percent: 0 is no look, 100 as designed, 200 twice as strong.
    /// Monochrome stays monochrome at any strength above zero.
    public func scaled(by amount: Double) -> BaseLookParameters {
        let t = amount / 100
        return BaseLookParameters(
            contrast: 1 + (contrast - 1) * t,
            saturation: max(0, 1 + (saturation - 1) * t),
            warmth: warmth * t,
            greenBoost: greenBoost * t,
            skinSoftening: skinSoftening * t,
            isMonochrome: isMonochrome && t > 0,
        )
    }
}

extension BaseLookParameters: Codable {
    private enum CodingKeys: String, CodingKey {
        case contrast, saturation, warmth, greenBoost, skinSoftening, monochrome
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        warmth = try container.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        greenBoost = try container.decodeIfPresent(Double.self, forKey: .greenBoost) ?? 0
        skinSoftening = try container.decodeIfPresent(Double.self, forKey: .skinSoftening) ?? 0
        isMonochrome = try container.decodeIfPresent(Bool.self, forKey: .monochrome) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(warmth, forKey: .warmth)
        if greenBoost != 0 {
            try container.encode(greenBoost, forKey: .greenBoost)
        }
        if skinSoftening != 0 {
            try container.encode(skinSoftening, forKey: .skinSoftening)
        }
        if isMonochrome {
            try container.encode(true, forKey: .monochrome)
        }
    }
}

/// Everything the engine needs to render a Base Look: its parameters and optional table.
public struct BaseLookDefinition: Sendable, Hashable {
    public var id: String
    public var version: Int
    public var name: String
    public var parameters: BaseLookParameters
    public var table: LookTable?

    public init(id: String, version: Int, name: String, parameters: BaseLookParameters, table: LookTable? = nil) {
        self.id = id
        self.version = version
        self.name = name
        self.parameters = parameters
        self.table = table
    }

    /// A reference to this look at full strength, pinned to its table.
    public var reference: BaseLookReference {
        BaseLookReference(id: id, version: version, name: name, contentHash: table?.contentHash)
    }
}

/// A Base Look registered before its table is read: what edits pin it by, and how to read
/// the whole look when a render first uses it.
public struct BaseLookSource: Sendable {
    /// The look at full strength, pinned to its table's content hash.
    public var reference: BaseLookReference
    public var parameters: BaseLookParameters
    /// The look, whose `reference` and `parameters` must be the ones above; nil when it
    /// can't be read.
    public var load: @Sendable () -> BaseLookDefinition?

    public init(
        reference: BaseLookReference,
        parameters: BaseLookParameters,
        load: @escaping @Sendable () -> BaseLookDefinition?,
    ) {
        self.reference = reference
        self.parameters = parameters
        self.load = load
    }
}
