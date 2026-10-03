import Foundation

/// One Remove, Heal or Clone spot, as in Lightroom's Remove tool: the circle at `center`, or the
/// brush stroke starting there, is filled from the photo around it (Remove) or replaced with the
/// same shape at `source`.
///
/// Points are `ImagePoint`s, so spots stay on the same content whatever the crop, Transform
/// or lens correction. Spots apply in order, each to the photo as the earlier ones left it.
public struct RetouchSpot: Codable, Sendable, Hashable, Identifiable {
    public enum Mode: String, Codable, Sendable, Hashable, CaseIterable {
        /// Filled from the photo around it, patch by patch (content-aware fill); `source` is unused.
        case remove
        /// The source's texture, matched to the colour and brightness around the spot.
        case heal
        /// The source as it is.
        case clone

        public var name: String {
            switch self {
            case .remove: "Remove"
            case .heal: "Heal"
            case .clone: "Clone"
            }
        }

        /// A mode this build doesn't know reads as Heal, so an edit from a newer Redlamp still opens.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Mode(rawValue: raw) ?? .heal
        }

        /// Whether the spot copies from `source`.
        public var usesSource: Bool {
            self != .remove
        }
    }

    public var id: UUID
    public var mode: Mode
    public var center: ImagePoint
    public var source: ImagePoint
    /// A brushed spot's stroke after its first point (`center`), each point relative to
    /// `center`, so moving the spot moves the stroke. Empty for a circle.
    public var stroke: [ImagePoint]
    /// A fraction of the image *height*, like radial mask radii: the circle's, or the brush's.
    public var radius: Double
    /// 0...100: the share of the radius that fades out.
    public var feather: Double
    /// 0...100.
    public var opacity: Double

    public static let radiusRange = 0.002 ... 0.25

    public init(
        id: UUID = UUID(),
        mode: Mode = .heal,
        center: ImagePoint,
        source: ImagePoint,
        stroke: [ImagePoint] = [],
        radius: Double,
        feather: Double = 50,
        opacity: Double = 100,
    ) {
        self.id = id
        self.mode = mode
        self.center = center
        self.source = source
        self.stroke = stroke
        self.radius = radius
        self.feather = feather
        self.opacity = opacity
    }

    /// Whether the spot changes nothing.
    public var isEmpty: Bool {
        opacity <= 0 || radius <= 0 || (mode.usesSource && center == source)
    }

    /// The stroke's points, `center` first, where the spot is (or, with `at`, where its source is).
    public func points(at anchor: ImagePoint? = nil) -> [ImagePoint] {
        let origin = anchor ?? center
        return [origin] + stroke.map { ImagePoint(x: origin.x + $0.x, y: origin.y + $0.y) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, mode, center, source, stroke, radius, feather, opacity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        mode = try container.decode(Mode.self, forKey: .mode)
        center = try container.decode(ImagePoint.self, forKey: .center)
        source = try container.decode(ImagePoint.self, forKey: .source)
        stroke = try container.decodeIfPresent([ImagePoint].self, forKey: .stroke) ?? []
        radius = try container.decode(Double.self, forKey: .radius)
        feather = try container.decode(Double.self, forKey: .feather)
        opacity = try container.decode(Double.self, forKey: .opacity)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(mode, forKey: .mode)
        try container.encode(center, forKey: .center)
        try container.encode(source, forKey: .source)
        if !stroke.isEmpty {
            try container.encode(stroke, forKey: .stroke)
        }
        try container.encode(radius, forKey: .radius)
        try container.encode(feather, forKey: .feather)
        try container.encode(opacity, forKey: .opacity)
    }
}

/// A speck of sensor dust the engine found (`EditingEngine.detectDust`).
public struct DetectedSpot: Sendable, Hashable {
    public var center: ImagePoint
    /// A fraction of the image height, enough to cover the speck's soft edge.
    public var radius: Double
    /// How far it stands out from its surroundings, in multiples of their spread.
    public var strength: Double

    public init(center: ImagePoint, radius: Double, strength: Double) {
        self.center = center
        self.radius = radius
        self.strength = strength
    }
}
