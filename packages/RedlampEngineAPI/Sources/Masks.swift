import Foundation

/// A point in normalised, oriented image coordinates: (0, 0) top-left, (1, 1) bottom-right.
public struct ImagePoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Full effect at `start`, fading to no effect at `end`.
public struct LinearMask: Codable, Sendable, Hashable {
    public var start: ImagePoint
    public var end: ImagePoint

    public init(start: ImagePoint, end: ImagePoint) {
        self.start = start
        self.end = end
    }

    public var center: ImagePoint {
        ImagePoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    }
}

/// An ellipse with a feathered edge. Radii are fractions of the image *height*, so a
/// circle stays round whatever the aspect ratio. Full effect inside by default.
public struct RadialMask: Codable, Sendable, Hashable {
    public var center: ImagePoint
    public var radiusX: Double
    public var radiusY: Double
    /// Degrees, clockwise.
    public var rotation: Double
    /// 0...100, as in Lightroom.
    public var feather: Double

    public init(center: ImagePoint, radiusX: Double, radiusY: Double, rotation: Double = 0, feather: Double = 50) {
        self.center = center
        self.radiusX = radiusX
        self.radiusY = radiusY
        self.rotation = rotation
        self.feather = feather
    }
}

public enum MaskShape: Codable, Sendable, Hashable {
    case linear(LinearMask)
    case radial(RadialMask)

    public var kind: MaskKind {
        switch self {
        case .linear: .linear
        case .radial: .radial
        }
    }

    public var center: ImagePoint {
        switch self {
        case let .linear(gradient): gradient.center
        case let .radial(gradient): gradient.center
        }
    }
}

/// Every mask type in Lightroom's "Create New Mask" menu, and when it lands.
public enum MaskKind: String, CaseIterable, Codable, Sendable, Hashable {
    case subject, sky, background, objects, people, landscape
    case brush, linear, radial
    case colorRange, luminanceRange, depthRange

    public var name: String {
        switch self {
        case .subject: "Subject"
        case .sky: "Sky"
        case .background: "Background"
        case .objects: "Objects"
        case .people: "People"
        case .landscape: "Landscape"
        case .brush: "Brush"
        case .linear: "Linear Gradient"
        case .radial: "Radial Gradient"
        case .colorRange: "Color Range"
        case .luminanceRange: "Luminance Range"
        case .depthRange: "Depth Range"
        }
    }

    public var symbol: String {
        switch self {
        case .subject: "person.crop.rectangle"
        case .sky: "cloud.sun"
        case .background: "rectangle.dashed"
        case .objects: "cube"
        case .people: "person.2"
        case .landscape: "mountain.2"
        case .brush: "paintbrush.pointed"
        case .linear: "square.split.1x2"
        case .radial: "circle.circle"
        case .colorRange: "eyedropper.halffull"
        case .luminanceRange: "sun.max"
        case .depthRange: "square.3.layers.3d"
        }
    }

    /// `nil` once the engine renders the mask type.
    public var plannedPhase: String? {
        switch self {
        case .linear, .radial: nil
        case .brush, .subject, .sky, .background, .people, .colorRange, .luminanceRange: "Phase 2"
        case .objects, .landscape, .depthRange: "Phase 3"
        }
    }

    public var isAvailable: Bool {
        plannedPhase == nil
    }
}

/// How a component combines with the components before it.
public enum MaskOperation: String, Codable, Sendable, Hashable, CaseIterable {
    case add, subtract, intersect

    public var name: String {
        switch self {
        case .add: "Add"
        case .subtract: "Subtract"
        case .intersect: "Intersect"
        }
    }

    public var symbol: String {
        switch self {
        case .add: "plus"
        case .subtract: "minus"
        case .intersect: "circle.lefthalf.filled"
        }
    }
}

public struct MaskComponent: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var shape: MaskShape
    public var operation: MaskOperation
    public var inverted: Bool

    public init(id: UUID = UUID(), shape: MaskShape, operation: MaskOperation = .add, inverted: Bool = false) {
        self.id = id
        self.shape = shape
        self.operation = operation
        self.inverted = inverted
    }
}

/// A local adjustment: a mask built from components, plus its own adjustments.
public struct MaskLayer: Sendable, Hashable, Identifiable {
    public static let maximumLayers = 16
    public static let maximumComponents = 64

    public var id: UUID
    public var name: String
    public var isVisible: Bool
    public var components: [MaskComponent]
    /// Scales every adjustment of the mask, 0...200 (Lightroom's mask Amount).
    public var amount: Double
    public private(set) var adjustments: [ParameterID: Double]

    public init(
        id: UUID = UUID(),
        name: String,
        components: [MaskComponent],
        isVisible: Bool = true,
        amount: Double = 100,
        adjustments: [ParameterID: Double] = [:],
    ) {
        self.id = id
        self.name = name
        self.components = components
        self.isVisible = isVisible
        self.amount = amount
        self.adjustments = [:]
        for (parameter, value) in adjustments {
            self[parameter] = value
        }
    }

    public subscript(parameter: ParameterID) -> Double {
        get { adjustments[parameter] ?? parameter.spec.defaultValue }
        set {
            guard parameter.isLocal else { return }
            let clamped = parameter.spec.clamp(newValue)
            adjustments[parameter] = abs(clamped - parameter.spec.defaultValue) < 1e-9 ? nil : clamped
        }
    }

    public mutating func resetAdjustments() {
        adjustments = [:]
        amount = 100
    }
}

extension MaskLayer: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, isVisible, components, amount, adjustments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Mask"
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        components = try container.decodeIfPresent([MaskComponent].self, forKey: .components) ?? []
        amount = try container.decodeIfPresent(Double.self, forKey: .amount) ?? 100
        adjustments = [:]
        let raw = try container.decodeIfPresent([String: Double].self, forKey: .adjustments) ?? [:]
        for (key, value) in raw {
            if let parameter = ParameterID(rawValue: key) {
                self[parameter] = value
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isVisible, forKey: .isVisible)
        try container.encode(components, forKey: .components)
        try container.encode(amount, forKey: .amount)
        try container.encode(
            Dictionary(uniqueKeysWithValues: adjustments.map { ($0.key.rawValue, $0.value) }),
            forKey: .adjustments,
        )
    }
}
