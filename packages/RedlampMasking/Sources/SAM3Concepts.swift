import CoreGraphics
import CoreML
import Foundation
import RedlampEngineAPI

/// Landscape masks and people parts from SAM 3 (Meta), converted by
/// `research/prototypes/masking/convert_sam3.py`: an image encoder (once per photo) and a
/// text-prompted decoder (once per prompt), with the text features of each class's prompts
/// computed offline (`Sam3Prompts.bin`), so no text encoder ships.
///
/// Each class is its prompts' maps maxed, as the mean of two: the instances SAM 3 scores over
/// 0.4, merged, and its dense semantic map times the presence score. The classes of a group are
/// then made exclusive by precedence, as Lightroom's are. On the Landscape bake-off (MSK-17)
/// against OneFormer: IoU water 0.839, vegetation 0.718, mountains 0.618, architecture 0.589,
/// natural ground 0.329, artificial ground 0.621. Evaluation only: the SAM License isn't cleared.
public final class SAM3Concepts: @unchecked Sendable {
    public static let inputSize = 1008
    /// The decoder's output, square (the photo is squashed to the input).
    public static let outputSize = 288
    /// Where several classes claim a pixel, the first here wins: grass is vegetation, not
    /// ground; a road is artificial ground even where "ground" also fires.
    public static let precedence: [LandscapeClass] = [
        .water, .vegetation, .architecture, .mountains, .artificialGround, .naturalGround,
    ]
    /// The people parts SAM 3 gives, by precedence: a beard is facial hair, not hair; a sleeve
    /// is clothes, not skin. Body skin is also less the face (Face Skin is a part of its own).
    public static let partPrecedence: [PersonPart] = [.facialHair, .hair, .clothes, .bodySkin]

    /// The photo's encoding: the three feature levels the decoder reads.
    public struct Features: @unchecked Sendable {
        let levels: MLFeatureProvider
    }

    struct Prompt {
        let text: MLMultiArray
        let mask: MLMultiArray
    }

    public let manifest: ModelManifest
    private let encoder: MLModel
    private let decoder: MLModel
    /// By class name in `Sam3Prompts.json`: "natural-ground", "facial-hair", "face".
    private let prompts: [String: [Prompt]]
    private let lock = NSLock()

    public init(manifest: ModelManifest, directory: URL) throws {
        self.manifest = manifest
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        func model(_ name: String) throws -> MLModel {
            let compiled = try CompiledModels.compiled(
                package: directory.appending(path: "\(name).mlpackage"),
                key: "\(manifest.id)-v\(manifest.version)-\(name)",
            )
            return try MLModel(contentsOf: compiled, configuration: configuration)
        }
        encoder = try model("Sam3ImageEncoder")
        decoder = try model("Sam3TextDecoder")
        prompts = try Self.prompts(in: directory, decoder: decoder)
    }

    /// Encodes `image` (squashed to the input size).
    public func features(of image: CGImage) throws -> Features {
        let buffer = try DepthAnything3.input(image, size: PixelSize(width: Self.inputSize, height: Self.inputSize))
        let levels = try lock.withLock {
            try encoder.prediction(
                from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]),
            )
        }
        return Features(levels: levels)
    }

    /// Every Landscape class's mask at the output size, exclusive by precedence.
    public func classes(_ features: Features) throws -> [LandscapeClass: GrayMask] {
        var raw: [LandscapeClass: [Float]] = [:]
        for cls in Self.precedence {
            raw[cls] = try map(Self.className(cls), features: features)
        }
        return Self.exclusive(raw, order: Self.precedence, size: Self.outputSize)
    }

    /// Hair, facial hair, clothes and body skin for everyone in the photo, at the output size.
    public struct PeopleParts: @unchecked Sendable {
        /// Each part, exclusive by precedence.
        public var parts: [PersonPart: GrayMask]
        /// For each part, where SAM 3 sees the face or any other part (not exclusive): where the
        /// part meets those, its edge is SAM 3's (see `edges(of:others:person:reach:)`).
        public var others: [PersonPart: GrayMask]
    }

    public func peopleParts(_ features: Features) throws -> PeopleParts {
        let size = Self.outputSize
        var raw: [PersonPart: [Float]] = [:]
        for part in Self.partPrecedence {
            raw[part] = try map(Self.className(part), features: features)
        }
        let face = try map("face", features: features)
        var others: [PersonPart: GrayMask] = [:]
        for part in Self.partPrecedence {
            let seen = Self.partPrecedence.filter { $0 != part }.compactMap { raw[$0] }
                .reduce(face) { zip($0, $1).map(max) }
            others[part] = GrayMask(width: size, height: size, coverage: seen)
        }
        if let skin = raw[.bodySkin] {
            raw[.bodySkin] = zip(skin, face).map { max($0 - $1, 0) }
        }
        return PeopleParts(parts: Self.exclusive(raw, order: Self.partPrecedence, size: size), others: others)
    }

    /// A part's edges both ways, at `person`'s size: SAM 3's where it meets the person's other
    /// parts, and the person's own matte (`person`, solved per pixel) where it meets the
    /// background. Within `reach` (in `part`'s pixels) of the part, whatever of the person SAM 3
    /// sees as none of their other parts is the part's: stray hairs, a beard's straggles, a
    /// sleeve's fringe, which SAM 3's 288 × 288 output misses.
    public static func edges(of part: GrayMask, others: GrayMask, person: GrayMask, reach: Int) -> GrayMask {
        let size = PixelSize(width: person.width, height: person.height)
        let inside = part.pixels.map { $0 > 127 ? Float(1) : 0 }
        let spread = BoxFilter.blur(inside, width: part.width, height: part.height, radius: reach)
        // Any of the window is the part (the box mean is at least one pixel's worth).
        let floor = 0.5 / Float((2 * reach + 1) * (2 * reach + 1))
        let near = GrayMask(width: part.width, height: part.height, pixels: spread.map { $0 > floor ? 255 : 0 })
            .resized(to: size).pixels
        let own = part.resized(to: size).pixels
        let seen = others.resized(to: size).pixels
        let matte = person.pixels
        var out = [UInt8](repeating: 0, count: matte.count)
        Parallel.fill(&out) { index in
            let free = near[index] > 0 ? matte[index] - min(matte[index], seen[index]) : 0
            return max(own[index], free)
        }
        return GrayMask(width: size.width, height: size.height, pixels: out)
    }

    /// One class's prompts decoded and maxed: the mean of the instance and semantic maps.
    private func map(_ name: String, features: Features) throws -> [Float] {
        let size = Self.outputSize
        var instances = [Float](repeating: 0, count: size * size)
        var semantic = [Float](repeating: 0, count: size * size)
        for prompt in prompts[name] ?? [] {
            var inputs: [String: MLFeatureValue] = [
                "text": MLFeatureValue(multiArray: prompt.text),
                "textMask": MLFeatureValue(multiArray: prompt.mask),
            ]
            for level in ["fpn0", "fpn1", "fpn2"] {
                inputs[level] = features.levels.featureValue(for: level)
            }
            let out = try lock
                .withLock { try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs)) }
            guard let instanceArray = out.featureValue(for: "instances")?.multiArrayValue,
                  let semanticArray = out.featureValue(for: "semantic")?.multiArrayValue
            else { throw MaskComputationError.unsupported(.landscape) }
            for (index, value) in DepthAnything3.values(instanceArray).enumerated() {
                instances[index] = max(instances[index], value)
            }
            for (index, value) in DepthAnything3.values(semanticArray).enumerated() {
                semantic[index] = max(semantic[index], value)
            }
        }
        return zip(instances, semantic).map { ($0 + $1) / 2 }
    }

    /// Each class keeps only what no class before it in `order` has claimed.
    static func exclusive<Class: Hashable>(
        _ raw: [Class: [Float]], order: [Class], size: Int,
    ) -> [Class: GrayMask] {
        var taken = [Float](repeating: 0, count: size * size)
        var out: [Class: GrayMask] = [:]
        for cls in order {
            guard let values = raw[cls] else { continue }
            let own = zip(values, taken).map { min(max($0 - $1, 0), 1) }
            taken = zip(taken, values).map { max($0, $1) }
            out[cls] = GrayMask(width: size, height: size, coverage: own)
        }
        return out
    }

    /// The class's name in `Sam3Prompts.json`.
    static func className(_ cls: LandscapeClass) -> String {
        switch cls {
        case .naturalGround: "natural-ground"
        case .artificialGround: "artificial-ground"
        default: cls.rawValue
        }
    }

    static func className(_ part: PersonPart) -> String {
        switch part {
        case .facialHair: "facial-hair"
        case .bodySkin: "body-skin"
        default: part.rawValue
        }
    }

    /// The prompts' text features (float16, each followed by its mask), by class.
    static func prompts(in directory: URL, decoder: MLModel) throws -> [String: [Prompt]] {
        struct Entry: Decodable {
            let `class`: String
            let offset: Int
            let features: [Int]
            let mask: [Int]
        }
        let index = try JSONDecoder().decode(
            [String: Entry].self, from: Data(contentsOf: directory.appending(path: "Sam3Prompts.json")),
        )
        let blob = try Data(contentsOf: directory.appending(path: "Sam3Prompts.bin"))
        let inputs = decoder.modelDescription.inputDescriptionsByName
        func array(_ values: [Float16], shape: [Int], name: String) throws -> MLMultiArray {
            let type = inputs[name]?.multiArrayConstraint?.dataType ?? .float32
            let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
            for (index, value) in values.enumerated() {
                array[index] = NSNumber(value: Float(value))
            }
            return array
        }
        var out: [String: [Prompt]] = [:]
        for (_, entry) in index.sorted(by: { $0.value.offset < $1.value.offset }) {
            let featureCount = entry.features.reduce(1, *)
            let maskCount = entry.mask.reduce(1, *)
            let values: [Float16] = blob.withUnsafeBytes { bytes in
                let base = bytes.baseAddress!.advanced(by: entry.offset).assumingMemoryBound(to: Float16.self)
                return Array(UnsafeBufferPointer(start: base, count: featureCount + maskCount))
            }
            try out[entry.class, default: []].append(Prompt(
                text: array(Array(values[..<featureCount]), shape: entry.features, name: "text"),
                mask: array(Array(values[featureCount...]), shape: entry.mask, name: "textMask"),
            ))
        }
        return out
    }
}
