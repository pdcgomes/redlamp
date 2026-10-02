import CoreGraphics
import CoreML
import Foundation
import RedlampEngineAPI

/// Landscape masks from SAM 3 (Meta), converted by `research/prototypes/masking/convert_sam3.py`:
/// an image encoder (once per photo) and a text-prompted decoder (once per prompt), with the text
/// features of each class's prompts computed offline (`Sam3Prompts.bin`), so no text encoder ships.
///
/// Each class is its prompts' maps maxed, as the mean of two: the instances SAM 3 scores over
/// 0.4, merged, and its dense semantic map times the presence score. The classes are then made
/// exclusive by precedence, as Lightroom's are. On the Landscape bake-off (MSK-17) against
/// OneFormer: IoU water 0.839, vegetation 0.718, mountains 0.618, architecture 0.589, natural
/// ground 0.329, artificial ground 0.621. Evaluation only: the SAM License isn't cleared.
public final class SAM3Landscape: @unchecked Sendable {
    public static let inputSize = 1008
    /// The decoder's output, square (the photo is squashed to the input).
    public static let outputSize = 288
    /// Where several classes claim a pixel, the first here wins: grass is vegetation, not
    /// ground; a road is artificial ground even where "ground" also fires.
    public static let precedence: [LandscapeClass] = [
        .water, .vegetation, .architecture, .mountains, .artificialGround, .naturalGround,
    ]

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
    private let prompts: [LandscapeClass: [Prompt]]
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

    /// Every class's mask at the output size, exclusive by precedence.
    public func classes(_ features: Features) throws -> [LandscapeClass: GrayMask] {
        let size = Self.outputSize
        var raw: [LandscapeClass: [Float]] = [:]
        for cls in Self.precedence {
            var instances = [Float](repeating: 0, count: size * size)
            var semantic = [Float](repeating: 0, count: size * size)
            for prompt in prompts[cls] ?? [] {
                var inputs: [String: MLFeatureValue] = [
                    "text": MLFeatureValue(multiArray: prompt.text),
                    "textMask": MLFeatureValue(multiArray: prompt.mask),
                ]
                for name in ["fpn0", "fpn1", "fpn2"] {
                    inputs[name] = features.levels.featureValue(for: name)
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
            raw[cls] = zip(instances, semantic).map { ($0 + $1) / 2 }
        }
        return Self.exclusive(raw, size: size)
    }

    /// Each class keeps only what no class before it in `precedence` has claimed.
    static func exclusive(_ raw: [LandscapeClass: [Float]], size: Int) -> [LandscapeClass: GrayMask] {
        var taken = [Float](repeating: 0, count: size * size)
        var out: [LandscapeClass: GrayMask] = [:]
        for cls in precedence {
            guard let values = raw[cls] else { continue }
            let own = zip(values, taken).map { min(max($0 - $1, 0), 1) }
            taken = zip(taken, values).map { max($0, $1) }
            out[cls] = GrayMask(width: size, height: size, coverage: own)
        }
        return out
    }

    /// The prompts' text features (float16, each followed by its mask) and their classes.
    static func prompts(in directory: URL, decoder: MLModel) throws -> [LandscapeClass: [Prompt]] {
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
        let classes: [String: LandscapeClass] = [
            "water": .water, "vegetation": .vegetation, "mountains": .mountains, "architecture": .architecture,
            "natural-ground": .naturalGround, "artificial-ground": .artificialGround,
        ]
        var out: [LandscapeClass: [Prompt]] = [:]
        for (_, entry) in index.sorted(by: { $0.value.offset < $1.value.offset }) {
            guard let cls = classes[entry.class] else { continue }
            let featureCount = entry.features.reduce(1, *)
            let maskCount = entry.mask.reduce(1, *)
            let values: [Float16] = blob.withUnsafeBytes { bytes in
                let base = bytes.baseAddress!.advanced(by: entry.offset).assumingMemoryBound(to: Float16.self)
                return Array(UnsafeBufferPointer(start: base, count: featureCount + maskCount))
            }
            try out[cls, default: []].append(Prompt(
                text: array(Array(values[..<featureCount]), shape: entry.features, name: "text"),
                mask: array(Array(values[featureCount...]), shape: entry.mask, name: "textMask"),
            ))
        }
        return out
    }
}
