import Foundation

/// A colour in OKLCh, as the develop kernel's colour controls see it after the tone curve.
public struct OKLCh: Codable, Sendable, Hashable {
    /// 0 is black and 1 is white on screen.
    public var lightness: Double
    public var chroma: Double
    /// Degrees, 0 to 360.
    public var hue: Double

    public init(lightness: Double, chroma: Double, hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }
}

/// One of Point Color's swatches (TON-29, `docs/plans/2026-10-05-point-color-design.md`): a colour,
/// the range of colours around it the swatch selects, and what it does to them.
public struct PointColorSwatch: Sendable, Hashable, Identifiable {
    /// The colour a swatch selects around.
    public enum Color: Sendable, Hashable {
        /// Picked on the photo, or carried by a preset: it stays put when other settings change,
        /// as the Color Mixer's bands do.
        case oklch(OKLCh)
        /// On a mask only: the colour typical of what the mask covers, worked out for each photo.
        case mask
    }

    public static let maximumSwatches = 8

    public var id: UUID
    public var color: Color
    /// Where the colour was picked, when it was, so the panel can show it.
    public var picked: ColorSample?
    public private(set) var values: [ParameterID: Double]
    /// Settings this build doesn't know, written by a newer Redlamp: written back unchanged.
    public private(set) var unknownValues: [String: Double] = [:]
    /// Fields written by a newer Redlamp, written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public init(id: UUID = UUID(), color: Color, picked: ColorSample? = nil, values: [ParameterID: Double] = [:]) {
        self.id = id
        self.color = color
        self.picked = picked
        self.values = [:]
        for (parameter, value) in values {
            self[parameter] = value
        }
    }

    public subscript(parameter: ParameterID) -> Double {
        get { values[parameter] ?? parameter.spec.defaultValue }
        set {
            guard parameter.isPointColorScoped else { return }
            let clamped = parameter.spec.clamp(newValue)
            values[parameter] = abs(clamped - parameter.spec.defaultValue) < 1e-9 ? nil : clamped
        }
    }

    /// Whether the swatch changes nothing: every shift and uniformity at 0.
    public var isNeutral: Bool {
        ParameterID.pointColorParameters.filter { $0.spec.defaultValue == 0 }.allSatisfy { values[$0] == nil }
    }
}

extension PointColorSwatch: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, color, picked, values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        color = try container.decode(Color.self, forKey: .color)
        picked = try container.decodeIfPresent(ColorSample.self, forKey: .picked)
        values = [:]
        let raw = try container.decodeIfPresent([String: Double].self, forKey: .values) ?? [:]
        for (key, value) in raw {
            if let parameter = ParameterID(rawValue: key), parameter.isPointColorScoped {
                self[parameter] = value
            } else {
                unknownValues[key] = value
            }
        }
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(color, forKey: .color)
        try container.encodeIfPresent(picked, forKey: .picked)
        try container.encode(
            unknownValues.merging(values.map { ($0.key.rawValue, $0.value) }) { $1 },
            forKey: .values,
        )
    }
}

extension PointColorSwatch.Color: Codable {
    private static let maskName = "mask"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            guard name == Self.maskName else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown swatch colour \(name)")
            }
            self = .mask
        } else {
            self = try .oklch(container.decode(OKLCh.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .oklch(color): try container.encode(color)
        case .mask: try container.encode(Self.maskName)
        }
    }
}
