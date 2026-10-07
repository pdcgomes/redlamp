import CryptoKit
import Foundation

/// A point in normalised, oriented image coordinates: (0, 0) top-left, (1, 1) bottom-right.
///
/// This is the canonical mask space (DEC-07): the photo as its EXIF orientation shows it, before
/// crop, Transform and lens correction. A user's rotation or flip is geometry after it, like crop,
/// and each of those maps mask points forward, so masks stay on the same content. Shapes are
/// anchored here but built in the corrected image, so an ellipse stays an ellipse on screen.
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

/// One stroke of a brush mask: dabs along `points`, each a soft disc.
public struct BrushStroke: Codable, Sendable, Hashable {
    public var points: [ImagePoint]
    /// Pen pressure at each point, 0...1. Empty when the input had none (full pressure).
    public var pressures: [Double]
    /// The brush radius, as a fraction of the image *height* (like radial radii).
    public var size: Double
    /// 0...100: the share of the radius that fades out.
    public var feather: Double
    /// 0...100: how much each dab adds, so overlapping dabs build up.
    public var flow: Double
    /// 0...100: the most coverage the stroke can reach.
    public var density: Double
    /// Removes coverage instead of adding it.
    public var erase: Bool
    /// Keeps each dab to colours like the one under its centre (Lightroom's Auto Mask).
    public var autoMask: Bool

    public init(
        points: [ImagePoint],
        pressures: [Double] = [],
        size: Double,
        feather: Double = 50,
        flow: Double = 100,
        density: Double = 100,
        erase: Bool = false,
        autoMask: Bool = false,
    ) {
        self.points = points
        self.pressures = pressures
        self.size = size
        self.feather = feather
        self.flow = flow
        self.density = density
        self.erase = erase
        self.autoMask = autoMask
    }

    public func pressure(at index: Int) -> Double {
        index < pressures.count ? min(max(pressures[index], 0), 1) : 1
    }
}

/// Painted strokes, in order; erase strokes take coverage away from earlier ones.
public struct BrushMask: Codable, Sendable, Hashable {
    public var strokes: [BrushStroke]

    public init(strokes: [BrushStroke] = []) {
        self.strokes = strokes
    }

    public var center: ImagePoint {
        strokes.first { !$0.erase }?.points.first ?? ImagePoint(x: 0.5, y: 0.5)
    }
}

/// Full coverage for lightness between `lower` and `upper`, fading to none over the feathers.
/// Lightness is OKLab L × 100 of the photo with its global edit (no local adjustments).
public struct LuminanceRangeMask: Codable, Sendable, Hashable {
    public var lower: Double
    public var upper: Double
    public var lowerFeather: Double
    public var upperFeather: Double
    /// Where the eyedropper sampled, for the pin. Not used for rendering.
    public var samplePoint: ImagePoint?

    public init(
        lower: Double = 50,
        upper: Double = 100,
        lowerFeather: Double = 10,
        upperFeather: Double = 0,
        samplePoint: ImagePoint? = nil,
    ) {
        self.lower = lower
        self.upper = upper
        self.lowerFeather = lowerFeather
        self.upperFeather = upperFeather
        self.samplePoint = samplePoint
    }

    /// The trapezoid with every bound in 0...100 and in order.
    public var normalized: LuminanceRangeMask {
        var range = self
        range.lower = min(max(lower, 0), 100)
        range.upper = min(max(upper, range.lower), 100)
        range.lowerFeather = min(max(lowerFeather, 0), range.lower)
        range.upperFeather = min(max(upperFeather, 0), 100 - range.upper)
        return range
    }

    /// A range centred on a sampled lightness, as Lightroom's eyedropper sets it.
    public static func sampled(lightness: Double, at point: ImagePoint) -> LuminanceRangeMask {
        let l = min(max(lightness, 0), 100)
        return LuminanceRangeMask(
            lower: max(l - 10, 0), upper: min(l + 10, 100),
            lowerFeather: 15, upperFeather: 15, samplePoint: point,
        ).normalized
    }
}

/// A sampled colour: the mean over a disc of the photo with its global edit.
public struct ColorSample: Codable, Sendable, Hashable {
    public var center: ImagePoint
    /// The disc's radius as a fraction of the image height; 0 samples a small spot.
    public var radius: Double

    public init(center: ImagePoint, radius: Double = 0) {
        self.center = center
        self.radius = radius
    }
}

/// Colours like any of the samples (Lightroom's Color Range). Colours are read from the
/// photo every render, so the selection follows the global edit's white balance.
public struct ColorRangeMask: Codable, Sendable, Hashable {
    public static let maximumSamples = 5

    public var samples: [ColorSample]
    /// 0...100: how far from the samples a colour may be and still be selected.
    public var refine: Double

    public init(samples: [ColorSample], refine: Double = 50) {
        self.samples = Array(samples.prefix(Self.maximumSamples))
        self.refine = refine
    }

    public var center: ImagePoint {
        samples.first?.center ?? ImagePoint(x: 0.5, y: 0.5)
    }
}

/// A coverage bitmap stored next to the edit: an 8-bit grayscale PNG in mask space.
/// The JSON keeps its hash and size; the sidecar package keeps the PNG in `masks/`.
public struct MaskBitmap: Codable, Sendable, Hashable {
    public var sha256: String
    public var width: Int
    public var height: Int
    /// The PNG bytes, when loaded. Not encoded: the sidecar package stores them by hash.
    public var png: Data?

    public init(sha256: String, width: Int, height: Int, png: Data? = nil) {
        self.sha256 = sha256
        self.width = width
        self.height = height
        self.png = png
    }

    /// A bitmap for PNG bytes, hashed.
    public init(png: Data, width: Int, height: Int) {
        self.init(sha256: Self.hash(png), width: width, height: height, png: png)
    }

    /// Lowercase hex SHA-256, the bitmap's file name in a sidecar package.
    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case sha256, width, height
    }

    public static func == (lhs: MaskBitmap, rhs: MaskBitmap) -> Bool {
        lhs.sha256 == rhs.sha256 && lhs.width == rhs.width && lhs.height == rhs.height
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sha256)
    }
}

/// A mask computed by a model (Subject, Sky, People and so on) and kept as a bitmap, so
/// it renders the same everywhere and only changes on an explicit update.
public struct AIMask: Sendable, Hashable {
    public var kind: MaskKind
    /// What computed it, for example `apple.vision.foreground`.
    public var provider: String
    /// The provider's request or model revision.
    public var revision: Int
    /// System models can change with the OS at the same revision.
    public var osBuild: String?
    /// Which person or object, when the provider found several.
    public var instance: Int?
    /// A part of a person, for example `faceSkin`.
    public var part: String?
    /// Points the user clicked to guide the model.
    public var prompts: [ImagePoint]
    /// Points the user clicked to leave out.
    public var excludedPrompts: [ImagePoint]?
    /// For Objects: the box dragged around the thing, or the one Find found it in, in the photo's
    /// oriented frame.
    public var box: ImageRect?
    /// Feather (0...100) softens the mask's edge and Edge (-100...100) moves it out or in, as
    /// Lightroom's sliders for AI masks do; both leave the mask as it is at 0.
    public var feather: Double = 0
    public var edge: Double = 0
    /// Hash of the render the model saw.
    public var analysisHash: String
    public var center: ImagePoint
    /// The model's mask, with `refinements` applied.
    public var bitmap: MaskBitmap
    public var createdAt: Date
    /// Refine Edge brush strokes, in order: where the edge was solved again per pixel. Kept so
    /// Update AI Masks can apply them to the new mask.
    public var refinements: [BrushStroke]?
    /// Fields written by a newer Redlamp, written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public init(
        kind: MaskKind,
        provider: String,
        revision: Int,
        osBuild: String? = nil,
        instance: Int? = nil,
        part: String? = nil,
        prompts: [ImagePoint] = [],
        excludedPrompts: [ImagePoint]? = nil,
        box: ImageRect? = nil,
        analysisHash: String,
        center: ImagePoint,
        bitmap: MaskBitmap,
        createdAt: Date = Date(),
        refinements: [BrushStroke]? = nil,
    ) {
        self.refinements = refinements
        self.excludedPrompts = excludedPrompts
        self.box = box
        self.kind = kind
        self.provider = provider
        self.revision = revision
        self.osBuild = osBuild
        self.instance = instance
        self.part = part
        self.prompts = prompts
        self.analysisHash = analysisHash
        self.center = center
        self.bitmap = bitmap
        self.createdAt = createdAt
    }
}

extension AIMask: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, provider, revision, osBuild, instance, part, prompts, excludedPrompts, box, feather, edge
        case analysisHash, center, bitmap, createdAt, refinements
    }

    /// A box as the sidecar writes it, by its edges.
    private struct Edges: Codable {
        var left, top, right, bottom: Double

        init(_ box: ImageRect) {
            (left, top, right, bottom) = (box.x, box.y, box.x + box.width, box.y + box.height)
        }

        var box: ImageRect {
            ImageRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(MaskKind.self, forKey: .kind)
        provider = try container.decode(String.self, forKey: .provider)
        revision = try container.decode(Int.self, forKey: .revision)
        osBuild = try container.decodeIfPresent(String.self, forKey: .osBuild)
        instance = try container.decodeIfPresent(Int.self, forKey: .instance)
        part = try container.decodeIfPresent(String.self, forKey: .part)
        prompts = try container.decode([ImagePoint].self, forKey: .prompts)
        excludedPrompts = try container.decodeIfPresent([ImagePoint].self, forKey: .excludedPrompts)
        box = try container.decodeIfPresent(Edges.self, forKey: .box)?.box
        feather = try container.decodeIfPresent(Double.self, forKey: .feather) ?? 0
        edge = try container.decodeIfPresent(Double.self, forKey: .edge) ?? 0
        analysisHash = try container.decode(String.self, forKey: .analysisHash)
        center = try container.decode(ImagePoint.self, forKey: .center)
        bitmap = try container.decode(MaskBitmap.self, forKey: .bitmap)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        refinements = try container.decodeIfPresent([BrushStroke].self, forKey: .refinements)
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(provider, forKey: .provider)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(osBuild, forKey: .osBuild)
        try container.encodeIfPresent(instance, forKey: .instance)
        try container.encodeIfPresent(part, forKey: .part)
        try container.encode(prompts, forKey: .prompts)
        try container.encodeIfPresent(excludedPrompts, forKey: .excludedPrompts)
        try container.encodeIfPresent(box.map(Edges.init), forKey: .box)
        if feather != 0 {
            try container.encode(feather, forKey: .feather)
        }
        if edge != 0 {
            try container.encode(edge, forKey: .edge)
        }
        try container.encode(analysisHash, forKey: .analysisHash)
        try container.encode(center, forKey: .center)
        try container.encode(bitmap, forKey: .bitmap)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(refinements, forKey: .refinements)
    }
}

public extension EditRecipe {
    /// Every mask bitmap the edit uses.
    var maskBitmaps: [MaskBitmap] {
        masks.flatMap(\.components).compactMap { component in
            switch component.shape {
            case let .ai(mask): mask.bitmap
            case let .depthRange(range): range.depth.bitmap
            default: nil
            }
        } + spots.compactMap(\.region?.bitmap) + spots.compactMap(\.fill?.bitmap)
    }

    /// Fills in the bytes of the edit's mask bitmaps from `bytes(sha256)`.
    mutating func loadMaskBitmaps(_ bytes: (String) -> Data?) {
        for layer in masks.indices {
            for index in masks[layer].components.indices {
                switch masks[layer].components[index].shape {
                case var .ai(mask) where mask.bitmap.png == nil:
                    mask.bitmap.png = bytes(mask.bitmap.sha256)
                    masks[layer].components[index].shape = .ai(mask)
                case var .depthRange(range) where range.depth.bitmap.png == nil:
                    range.depth.bitmap.png = bytes(range.depth.bitmap.sha256)
                    masks[layer].components[index].shape = .depthRange(range)
                default:
                    break
                }
            }
        }
        for index in spots.indices {
            if var region = spots[index].region, region.bitmap.png == nil {
                region.bitmap.png = bytes(region.bitmap.sha256)
                spots[index].region = region
            }
            if var fill = spots[index].fill, fill.bitmap.png == nil {
                fill.bitmap.png = bytes(fill.bitmap.sha256)
                spots[index].fill = fill
            }
        }
    }
}

/// Full coverage for depths between `lower` and `upper` (0 farthest, 100 nearest), fading over
/// the feathers. The depth map comes from the file (iPhone depth) or a depth model.
public struct DepthRangeMask: Codable, Sendable, Hashable {
    /// The depth map, near is white.
    public var depth: AIMask
    public var lower: Double
    public var upper: Double
    public var lowerFeather: Double
    public var upperFeather: Double

    public init(
        depth: AIMask,
        lower: Double = 60,
        upper: Double = 100,
        lowerFeather: Double = 15,
        upperFeather: Double = 0,
    ) {
        self.depth = depth
        self.lower = lower
        self.upper = upper
        self.lowerFeather = lowerFeather
        self.upperFeather = upperFeather
    }

    /// The trapezoid, as a luminance range (the same four handles).
    public var range: LuminanceRangeMask {
        get { LuminanceRangeMask(lower: lower, upper: upper, lowerFeather: lowerFeather, upperFeather: upperFeather) }
        set {
            let r = newValue.normalized
            (lower, upper, lowerFeather, upperFeather) = (r.lower, r.upper, r.lowerFeather, r.upperFeather)
        }
    }
}

/// Parts of a person an AI mask can select, as in Lightroom's People mask.
public enum PersonPart: String, Codable, Sendable, Hashable, CaseIterable {
    case entirePerson, faceSkin, bodySkin, eyebrows, eyeSclera, iris, lips, teeth, hair, facialHair, clothes

    public var name: String {
        switch self {
        case .entirePerson: "Entire Person"
        case .faceSkin: "Face Skin"
        case .bodySkin: "Body Skin"
        case .eyebrows: "Eyebrows"
        case .eyeSclera: "Eye Sclera"
        case .iris: "Iris and Pupil"
        case .lips: "Lips"
        case .teeth: "Teeth"
        case .hair: "Hair"
        case .facialHair: "Facial Hair"
        case .clothes: "Clothes"
        }
    }

    /// Whether `name` is plural ("No eyebrows were found").
    public var isPlural: Bool {
        [.eyebrows, .iris, .lips, .teeth, .clothes].contains(self)
    }
}

/// Lightroom's Landscape classes (Sky is a mask kind of its own). Each pixel belongs to one.
public enum LandscapeClass: String, Codable, Sendable, Hashable, CaseIterable {
    case water, vegetation, mountains, architecture, naturalGround, artificialGround
    /// Lightroom Classic 15's.
    case snow

    public var name: String {
        switch self {
        case .water: "Water"
        case .vegetation: "Vegetation"
        case .mountains: "Mountains"
        case .architecture: "Architecture"
        case .naturalGround: "Natural Ground"
        case .artificialGround: "Artificial Ground"
        case .snow: "Snow"
        }
    }

    /// Whether `name` is plural ("No mountains were found").
    public var isPlural: Bool {
        self == .mountains
    }
}

/// What an AI mask is computed for. Masks are computed from the photo without any edit, so
/// they don't move when the edit changes.
/// A person People finds in the open photo, for the People picker: Vision's person instance,
/// where they are, and their face. A face part's AI mask is numbered by its face
/// (`faceInstance`), a whole person's or a SAM 3 part's by the person.
public struct PersonFound: Sendable, Hashable, Identifiable {
    /// Their person instance; nil when Vision can't tell people apart (none separated, or four or
    /// more), so People covers everyone as one.
    public var instance: Int?
    /// The instance of their face's parts (Face Skin, Lips, Teeth...), when a face is found in them.
    public var faceInstance: Int?
    /// Their bounds, and their face's, in the oriented frame (0...1 from the top left).
    public var box: ImageRect
    public var face: ImageRect?

    public var id: Int {
        instance ?? -1
    }

    public init(instance: Int?, faceInstance: Int? = nil, box: ImageRect, face: ImageRect? = nil) {
        self.instance = instance
        self.faceInstance = faceInstance
        self.box = box
        self.face = face
    }
}

public struct MaskRequest: Sendable, Hashable {
    public var kind: MaskKind
    /// For People: the part of each person.
    public var part: PersonPart
    /// For Objects: points the user clicked (the first selects, more refine).
    public var prompts: [ImagePoint]
    /// For Objects: points to leave out (Option-click).
    public var excluded: [ImagePoint]
    /// One mask for everyone found, rather than one per person.
    public var combined: Bool
    /// For Landscape: which class.
    public var landscape: LandscapeClass
    /// For Objects: a box around the object (dragged, or a thing found by name), which bounds it
    /// as the prompts point at it.
    public var box: ImageRect?
    /// For People: only these people (`PersonFound.instance`); nil for everyone.
    public var people: [Int]?

    public init(
        kind: MaskKind, part: PersonPart = .entirePerson, prompts: [ImagePoint] = [], excluded: [ImagePoint] = [],
        combined: Bool = false, landscape: LandscapeClass = .vegetation, box: ImageRect? = nil, people: [Int]? = nil,
    ) {
        self.kind = kind
        self.part = part
        self.prompts = prompts
        self.excluded = excluded
        self.combined = combined
        self.landscape = landscape
        self.box = box
        self.people = people
    }

    /// The request an existing AI mask was made with, to update it. (A mask's `part` is its person
    /// part, or its Landscape class.)
    public init(updating mask: AIMask) {
        self.init(
            kind: mask.kind, part: mask.part.flatMap(PersonPart.init(rawValue:)) ?? .entirePerson,
            prompts: mask.prompts, excluded: mask.excludedPrompts ?? [],
            combined: mask.instance == nil && mask.kind == .people,
            landscape: mask.part.flatMap(LandscapeClass.init(rawValue:)) ?? .vegetation, box: mask.box,
        )
    }
}

public enum MaskComputationError: Error, Equatable, CustomStringConvertible {
    /// The kind of mask needs a model this device doesn't have yet.
    case unsupported(MaskKind)
    /// The model found nothing to select (no subject, no people, no sky).
    case nothingFound(MaskKind)
    /// The model found none of a People part or a Landscape class (`name`, plural or not).
    case partNotFound(name: String, plural: Bool)
    /// Without SAM 3, hair comes only from a hair matte the camera embedded (iPhone portraits).
    case needsHairMatte
    /// Body skin, facial hair and clothes come only from SAM 3 (an evaluation model).
    case needsSAM3(PersonPart)

    public static func notFound(_ part: PersonPart) -> MaskComputationError {
        .partNotFound(name: part.name, plural: part.isPlural)
    }

    public static func notFound(_ landscape: LandscapeClass) -> MaskComputationError {
        .partNotFound(name: landscape.name, plural: landscape.isPlural)
    }

    public var description: String {
        switch self {
        case let .unsupported(kind): "\(kind.name) masks aren't available on this device yet."
        case .nothingFound(.people): "No people were found in this photo."
        case .nothingFound(.objects): "Nothing was found to select there."
        case let .nothingFound(kind): "No \(kind.name.lowercased()) was found in this photo."
        case let .partNotFound(name, plural): "No \(name.lowercased()) \(plural ? "were" : "was") found in this photo."
        case .needsHairMatte: "Hair masks need a photo with its own hair matte, such as an iPhone portrait."
        case let .needsSAM3(part): "\(part.name) masks need the SAM 3 evaluation model."
        }
    }
}

/// Another mask's coverage, used as a component ("new mask from existing"). A referenced mask's
/// own references are ignored, so references never loop.
public struct MaskReference: Codable, Sendable, Hashable {
    public var maskID: UUID

    public init(maskID: UUID) {
        self.maskID = maskID
    }
}

/// A component written by a newer Redlamp. It renders nothing here and is saved unchanged.
public struct UnknownMaskShape: Sendable, Hashable {
    public var key: String
    public var value: JSONValue
}

public enum MaskShape: Sendable, Hashable {
    case linear(LinearMask)
    case radial(RadialMask)
    case brush(BrushMask)
    case luminanceRange(LuminanceRangeMask)
    case colorRange(ColorRangeMask)
    case ai(AIMask)
    case depthRange(DepthRangeMask)
    case maskReference(MaskReference)
    case unknown(UnknownMaskShape)

    /// `nil` for a component this build doesn't know.
    public var kind: MaskKind? {
        switch self {
        case .linear: .linear
        case .radial: .radial
        case .brush: .brush
        case .luminanceRange: .luminanceRange
        case .colorRange: .colorRange
        case let .ai(mask): mask.kind
        case .depthRange: .depthRange
        case .maskReference: .existingMask
        case .unknown: nil
        }
    }

    public var center: ImagePoint {
        switch self {
        case let .linear(gradient): gradient.center
        case let .radial(gradient): gradient.center
        case let .brush(brush): brush.center
        case let .luminanceRange(range): range.samplePoint ?? ImagePoint(x: 0.5, y: 0.5)
        case let .colorRange(range): range.center
        case let .ai(mask): mask.center
        case let .depthRange(range): range.depth.center
        case .maskReference, .unknown: ImagePoint(x: 0.5, y: 0.5)
        }
    }
}

/// `{"linear": {"_0": {...}}}`, the shape Swift synthesizes for enums with a payload.
extension MaskShape: Codable {
    private static let payloadKey = DynamicCodingKey("_0")
    private static let knownKeys = [
        "linear", "radial", "brush", "luminanceRange", "colorRange", "ai", "depthRange", "maskReference",
    ]

    /// A shape holding more than one key is read as the first known kind in `knownKeys`, or the
    /// first unknown key by name: the same every time, as the round-trip check relies on.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        func rank(_ key: DynamicCodingKey) -> Int {
            Self.knownKeys.firstIndex(of: key.stringValue) ?? Self.knownKeys.count
        }
        guard let key = container.allKeys.min(by: { (rank($0), $0.stringValue) < (rank($1), $1.stringValue) }) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Empty mask shape",
            ))
        }
        func payload<T: Decodable>(_: T.Type) throws -> T {
            try container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: key)
                .decode(T.self, forKey: Self.payloadKey)
        }
        switch key.stringValue {
        case "linear": self = try .linear(payload(LinearMask.self))
        case "radial": self = try .radial(payload(RadialMask.self))
        case "brush": self = try .brush(payload(BrushMask.self))
        case "luminanceRange": self = try .luminanceRange(payload(LuminanceRangeMask.self))
        case "colorRange": self = try .colorRange(payload(ColorRangeMask.self))
        case "ai": self = try .ai(payload(AIMask.self))
        case "depthRange": self = try .depthRange(payload(DepthRangeMask.self))
        case "maskReference": self = try .maskReference(payload(MaskReference.self))
        default: self = try .unknown(UnknownMaskShape(
                key: key.stringValue,
                value: container.decode(JSONValue.self, forKey: key),
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        func encode(_ name: String, _ value: some Encodable) throws {
            var nested = container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: DynamicCodingKey(name))
            try nested.encode(value, forKey: Self.payloadKey)
        }
        switch self {
        case let .linear(value): try encode("linear", value)
        case let .radial(value): try encode("radial", value)
        case let .brush(value): try encode("brush", value)
        case let .luminanceRange(value): try encode("luminanceRange", value)
        case let .colorRange(value): try encode("colorRange", value)
        case let .ai(value): try encode("ai", value)
        case let .depthRange(value): try encode("depthRange", value)
        case let .maskReference(value): try encode("maskReference", value)
        case let .unknown(shape): try container.encode(shape.value, forKey: DynamicCodingKey(shape.key))
        }
    }
}

/// Every mask type in Lightroom's "Create New Mask" menu, and when it lands.
public enum MaskKind: String, CaseIterable, Codable, Sendable, Hashable {
    case subject, sky, background, objects, people, landscape
    case brush, linear, radial
    case colorRange, luminanceRange, depthRange
    /// Another mask's coverage, reused as a component.
    case existingMask

    /// The types in the Create New Mask menu.
    public static let creatable: [MaskKind] = allCases.filter { $0 != .existingMask }

    /// Computed by a model from the photo, rather than drawn.
    public var isAI: Bool {
        switch self {
        case .subject, .sky, .background, .objects, .people, .landscape, .depthRange: true
        default: false
        }
    }

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
        case .existingMask: "Existing Mask"
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
        case .existingMask: "square.on.square"
        }
    }

    /// `nil` once the engine renders the mask type.
    public var plannedPhase: String? {
        switch self {
        case .linear, .radial, .brush, .colorRange, .luminanceRange, .existingMask: nil
        case .subject, .sky, .background, .people, .depthRange, .objects, .landscape: nil
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

public struct MaskComponent: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var shape: MaskShape
    public var operation: MaskOperation
    public var inverted: Bool
    /// Fields written by a newer Redlamp, written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public init(id: UUID = UUID(), shape: MaskShape, operation: MaskOperation = .add, inverted: Bool = false) {
        self.id = id
        self.shape = shape
        self.operation = operation
        self.inverted = inverted
    }
}

extension MaskComponent: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, shape, operation, inverted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        shape = try container.decode(MaskShape.self, forKey: .shape)
        operation = try container.decode(MaskOperation.self, forKey: .operation)
        inverted = try container.decode(Bool.self, forKey: .inverted)
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(shape, forKey: .shape)
        try container.encode(operation, forKey: .operation)
        try container.encode(inverted, forKey: .inverted)
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
    /// The whole mask inverted, once its components have combined (Lightroom's Invert); written
    /// only when set, so an older Redlamp keeps it but draws the mask uninverted.
    public var inverted = false
    /// Scales every adjustment of the mask, 0...200 (Lightroom's mask Amount).
    public var amount: Double
    /// -100...100: above 0 keeps only textured areas of the mask, below 0 only flat ones.
    public var detail: Double = 0
    public private(set) var adjustments: [ParameterID: Double]
    /// The mask's Curves; nil while every curve is straight.
    public var curves: MaskCurves? {
        didSet {
            if curves?.isIdentity == true {
                curves = nil
            }
        }
    }

    /// The mask's Point Color swatches, after the edit's own, as far as the mask covers.
    public var pointColor: [PointColorSwatch] = []

    /// Adjustments this build doesn't apply to masks, written by a newer Redlamp: written back
    /// unchanged until the mask's adjustments are reset.
    public private(set) var unknownAdjustments: [String: Double] = [:]
    /// Fields written by a newer Redlamp, written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

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
        unknownAdjustments = [:]
        curves = nil
        pointColor = []
        amount = 100
        detail = 0
    }

    /// The masks this one reuses as components.
    public var referencedMasks: [UUID] {
        components.compactMap { component in
            if case let .maskReference(reference) = component.shape {
                reference.maskID
            } else {
                nil
            }
        }
    }
}

extension MaskLayer: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, isVisible, components, inverted, amount, detail, adjustments, curves, pointColor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Mask"
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        components = try container.decodeIfPresent([MaskComponent].self, forKey: .components) ?? []
        inverted = try container.decodeIfPresent(Bool.self, forKey: .inverted) ?? false
        amount = try container.decodeIfPresent(Double.self, forKey: .amount) ?? 100
        detail = try container.decodeIfPresent(Double.self, forKey: .detail) ?? 0
        let curves = try container.decodeIfPresent(MaskCurves.self, forKey: .curves)
        self.curves = curves?.isIdentity == true ? nil : curves
        pointColor = try container.decodeIfPresent([PointColorSwatch].self, forKey: .pointColor) ?? []
        adjustments = [:]
        let raw = try container.decodeIfPresent([String: Double].self, forKey: .adjustments) ?? [:]
        for (key, value) in raw {
            if let parameter = ParameterID(rawValue: key), parameter.isLocal {
                self[parameter] = value
            } else {
                unknownAdjustments[key] = value
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
        try container.encode(name, forKey: .name)
        try container.encode(isVisible, forKey: .isVisible)
        try container.encode(components, forKey: .components)
        if inverted {
            try container.encode(inverted, forKey: .inverted)
        }
        try container.encode(amount, forKey: .amount)
        if detail != 0 {
            try container.encode(detail, forKey: .detail)
        }
        try container.encode(
            unknownAdjustments.merging(adjustments.map { ($0.key.rawValue, $0.value) }) { $1 },
            forKey: .adjustments,
        )
        try container.encodeIfPresent(curves, forKey: .curves)
        if !pointColor.isEmpty {
            try container.encode(pointColor, forKey: .pointColor)
        }
    }
}

/// A mask's Curves, as Lightroom's masks have: a point curve for all three channels, then one for
/// each, on the display-referred values the global Tone Curve works on.
public struct MaskCurves: Sendable, Hashable {
    public enum Channel: String, CaseIterable, Sendable {
        case rgb, red, green, blue

        public var name: String {
            switch self {
            case .rgb: "RGB"
            case .red: "Red"
            case .green: "Green"
            case .blue: "Blue"
            }
        }
    }

    public var rgb = EditRecipe.linearPointCurve
    public var red = EditRecipe.linearPointCurve
    public var green = EditRecipe.linearPointCurve
    public var blue = EditRecipe.linearPointCurve
    /// Fields written by a newer Redlamp, written back unchanged.
    public var unknownFields: [String: JSONValue] = [:]

    public init() {}

    public subscript(channel: Channel) -> [CurvePoint] {
        get {
            switch channel {
            case .rgb: rgb
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            switch channel {
            case .rgb: rgb = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }

    /// Every curve straight, and nothing a newer build wrote to keep.
    public var isIdentity: Bool {
        unknownFields.isEmpty && Channel.allCases.allSatisfy { self[$0] == EditRecipe.linearPointCurve }
    }
}

extension MaskCurves: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case rgb, red, green, blue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rgb = try container.decodeIfPresent([CurvePoint].self, forKey: .rgb) ?? EditRecipe.linearPointCurve
        red = try container.decodeIfPresent([CurvePoint].self, forKey: .red) ?? EditRecipe.linearPointCurve
        green = try container.decodeIfPresent([CurvePoint].self, forKey: .green) ?? EditRecipe.linearPointCurve
        blue = try container.decodeIfPresent([CurvePoint].self, forKey: .blue) ?? EditRecipe.linearPointCurve
        unknownFields = try decoder.container(keyedBy: DynamicCodingKey.self)
            .unknownFields(excluding: Set(CodingKeys.allCases.map(\.stringValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var unknown = encoder.container(keyedBy: DynamicCodingKey.self)
        try unknown.encode(unknownFields)
        var container = encoder.container(keyedBy: CodingKeys.self)
        for channel in Channel.allCases where self[channel] != EditRecipe.linearPointCurve {
            try container.encode(self[channel], forKey: CodingKeys(rawValue: channel.rawValue)!)
        }
    }
}
