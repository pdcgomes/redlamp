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
    /// A picked person or object (an AI mask of the whole photo): the spot is its shape grown by
    /// `radius`, instead of a circle or stroke. It stays where it was found; `center` is its middle.
    public var region: AIMask?
    /// A fraction of the image *height*, like radial mask radii: the circle's, the brush's, or how
    /// far a region grows past its edge.
    public var radius: Double
    /// 0...100: the share of the radius that fades out.
    public var feather: Double
    /// 0...100.
    public var opacity: Double
    /// A Remove spot's fill made by a generative model (RM-10), in place of filling it from the
    /// photo around it. A build that doesn't know it keeps it and fills the spot from the photo.
    public var fill: GeneratedFill?
    /// Fields written by a newer Redlamp, written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public static let radiusRange = 0.002 ... 0.25

    public init(
        id: UUID = UUID(),
        mode: Mode = .heal,
        center: ImagePoint,
        source: ImagePoint,
        stroke: [ImagePoint] = [],
        region: AIMask? = nil,
        radius: Double,
        feather: Double = 50,
        opacity: Double = 100,
        fill: GeneratedFill? = nil,
    ) {
        self.fill = fill
        self.id = id
        self.mode = mode
        self.center = center
        self.source = source
        self.stroke = stroke
        self.region = region
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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, mode, center, source, stroke, region, radius, feather, opacity, fill
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        mode = try container.decode(Mode.self, forKey: .mode)
        center = try container.decode(ImagePoint.self, forKey: .center)
        source = try container.decode(ImagePoint.self, forKey: .source)
        stroke = try container.decodeIfPresent([ImagePoint].self, forKey: .stroke) ?? []
        region = try container.decodeIfPresent(AIMask.self, forKey: .region)
        radius = try container.decode(Double.self, forKey: .radius)
        feather = try container.decode(Double.self, forKey: .feather)
        opacity = try container.decode(Double.self, forKey: .opacity)
        fill = try container.decodeIfPresent(GeneratedFill.self, forKey: .fill)
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(mode, forKey: .mode)
        try container.encode(center, forKey: .center)
        try container.encode(source, forKey: .source)
        if !stroke.isEmpty {
            try container.encode(stroke, forKey: .stroke)
        }
        try container.encodeIfPresent(region, forKey: .region)
        try container.encode(radius, forKey: .radius)
        try container.encode(feather, forKey: .feather)
        try container.encode(opacity, forKey: .opacity)
        try container.encodeIfPresent(fill, forKey: .fill)
    }
}

/// A Remove spot's fill made by a generative model (RM-10), kept with the edit so it renders the
/// same everywhere, whatever Mac opens it and whether or not it has the model.
public struct GeneratedFill: Codable, Sendable, Hashable {
    /// Where the fill goes, in the photo's full-size pixels before its orientation is applied.
    public struct Box: Codable, Sendable, Hashable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// The fill in the photo's camera RGB, white balanced as shot, linear: a 16-bit RGB PNG of
    /// each value divided by `peak`, square-rooted, kept with the edit's bitmaps.
    public var bitmap: MaskBitmap
    public var peak: Double
    public var box: Box
    /// The size of the photo it was made for: a fill made for a photo decoded at another size is
    /// left out, and the spot filled from the photo.
    public var photoSize: PixelSize
    /// The model's manifest and version, and the seed and prompt that made the fill.
    public var model: String
    public var modelVersion: Int
    public var seed: Int
    public var prompt: String
    /// Fields written by a newer Redlamp, written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public init(
        bitmap: MaskBitmap, peak: Double, box: Box, photoSize: PixelSize, model: String, modelVersion: Int, seed: Int,
        prompt: String,
    ) {
        self.bitmap = bitmap
        self.peak = peak
        self.box = box
        self.photoSize = photoSize
        self.model = model
        self.modelVersion = modelVersion
        self.seed = seed
        self.prompt = prompt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case bitmap, peak, box, photoSize, model, modelVersion, seed, prompt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bitmap = try container.decode(MaskBitmap.self, forKey: .bitmap)
        peak = try container.decode(Double.self, forKey: .peak)
        box = try container.decode(Box.self, forKey: .box)
        photoSize = try container.decode(PixelSize.self, forKey: .photoSize)
        model = try container.decode(String.self, forKey: .model)
        modelVersion = try container.decode(Int.self, forKey: .modelVersion)
        seed = try container.decode(Int.self, forKey: .seed)
        prompt = try container.decode(String.self, forKey: .prompt)
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bitmap, forKey: .bitmap)
        try container.encode(peak, forKey: .peak)
        try container.encode(box, forKey: .box)
        try container.encode(photoSize, forKey: .photoSize)
        try container.encode(model, forKey: .model)
        try container.encode(modelVersion, forKey: .modelVersion)
        try container.encode(seed, forKey: .seed)
        try container.encode(prompt, forKey: .prompt)
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

/// A thing found in the photo by name (RM-08), for the Healing tool to offer for removal: what
/// it is, how sure the detector is (0...1), and its box in the photo as shown.
public struct FoundThing: Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var thing: String
    public var score: Double
    public var box: ImageRect

    public init(thing: String, score: Double, box: ImageRect) {
        self.thing = thing
        self.score = score
        self.box = box
    }
}
