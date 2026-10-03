import Accelerate
import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// Things named in words (RM-08), found by OWLv2 (Google's B/16, Apache-2.0) in Core ML: the photo
/// padded to a square with grey at its bottom and right, as OWLv2's own notebook pads it, then
/// resized to 960². Each of its 60 × 60 patches proposes a box, scored against the text features
/// of each thing's prompts, computed ahead (`Owlv2Queries.bin`), so no text encoder ships. About
/// 150 ms a photo on the GPU; the Neural Engine computes in float16, which this model doesn't
/// survive.
public final class OWLv2Detector: @unchecked Sendable {
    public static let inputSize = 960

    /// A thing found: its name, the detector's score (0...1) and its box, 0...1 of the image with
    /// the origin at the top left.
    public struct Detection: Sendable, Hashable {
        public var thing: String
        public var score: Float
        public var box: CGRect
    }

    public let manifest: ModelManifest
    /// What it can find, by name, in alphabetical order.
    public let things: [String]
    private let model: MLModel
    /// The prompts' text features (unit length), one column each, and the thing (in `things`) each
    /// finds.
    private let features: [Float]
    private let promptThings: [Int]
    private let dimension: Int
    private let lock = NSLock()

    /// Boxes of one thing overlapping another of it by more than this are the same thing; of two
    /// things, by more than `sameAcross`.
    static let sameThing = 0.3
    static let sameAcross = 0.7

    private struct Prompt: Decodable {
        var thing: String
        var offset: Int
        var features: [Int]
    }

    /// What the model in `directory` can find, read from its prompts without loading it.
    public static func things(in directory: URL) throws -> [String] {
        let index = try JSONDecoder().decode(
            [String: Prompt].self, from: Data(contentsOf: directory.appending(path: "Owlv2Queries.json")),
        )
        return Array(Set(index.values.map(\.thing))).sorted()
    }

    /// Loads the model from `directory`, compiling it once into Caches.
    public init(manifest: ModelManifest, directory: URL) throws {
        self.manifest = manifest
        let configuration = MLModelConfiguration()
        configuration.computeUnits = manifest.computeUnits == "all" ? .all : .cpuAndGPU
        let compiled = try CompiledModels.compiled(
            package: directory.appending(path: "Owlv2Detector.mlpackage"),
            key: "\(manifest.id)-v\(manifest.version)-Owlv2Detector",
        )
        model = try MLModel(contentsOf: compiled, configuration: configuration)
        let index = try JSONDecoder().decode(
            [String: Prompt].self, from: Data(contentsOf: directory.appending(path: "Owlv2Queries.json")),
        )
        let blob = try Data(contentsOf: directory.appending(path: "Owlv2Queries.bin"))
        let prompts = index.values.sorted { $0.offset < $1.offset }
        guard let dimension = prompts.first?.features.first else { throw CocoaError(.fileReadCorruptFile) }
        let things = Array(Set(prompts.map(\.thing))).sorted()
        var features = [Float](repeating: 0, count: dimension * prompts.count)
        for (column, prompt) in prompts.enumerated() {
            guard prompt.features == [dimension], prompt.offset + dimension * 2 <= blob.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            blob.withUnsafeBytes { bytes in
                for index in 0 ..< dimension {
                    let bits = bytes.loadUnaligned(fromByteOffset: prompt.offset + index * 2, as: UInt16.self)
                    features[index * prompts.count + column] = Float(Float16(bitPattern: UInt16(littleEndian: bits)))
                }
            }
        }
        self.things = things
        self.features = features
        self.dimension = dimension
        promptThings = prompts.map { prompt in things.firstIndex(of: prompt.thing) ?? 0 }
    }

    /// The `wanted` things in `image` (all of them when nil) scoring at least `threshold`, most
    /// certain first.
    public func detect(_ image: CGImage, things wanted: Set<String>? = nil, threshold: Float) throws -> [Detection] {
        let buffer = try Self.square(image)
        let output = try lock.withLock {
            try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(pixelBuffer: buffer),
            ]))
        }
        func floats(_ name: String) throws -> [Float] {
            guard let array = output.featureValue(for: name)?.multiArrayValue else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return Self.floats(array)
        }
        let embeddings = try floats("classEmbeddings"), shifts = try floats("logitShift")
        let scales = try floats("logitScale"), boxes = try floats("boxes")
        let patches = shifts.count, prompts = promptThings.count
        guard embeddings.count == patches * dimension, scales.count == patches, boxes.count == patches * 4 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Every patch against every prompt: (embedding · features + shift) × scale.
        var logits = [Float](repeating: 0, count: patches * prompts)
        vDSP_mmul(
            embeddings, 1, features, 1, &logits, 1,
            vDSP_Length(patches), vDSP_Length(prompts), vDSP_Length(dimension),
        )
        let side = Double(max(image.width, image.height))
        let covered = (x: Double(image.width) / side, y: Double(image.height) / side)
        var found: [Detection] = []
        for (thing, name) in things.enumerated() where wanted?.contains(name) ?? true {
            var candidates: [Detection] = []
            for patch in 0 ..< patches {
                var best = -Float.infinity
                for prompt in 0 ..< prompts where promptThings[prompt] == thing {
                    best = max(best, (logits[patch * prompts + prompt] + shifts[patch]) * scales[patch])
                }
                let score = 1 / (1 + exp(-best))
                guard score >= threshold else { continue }
                let (cx, cy) = (Double(boxes[patch * 4]), Double(boxes[patch * 4 + 1]))
                // A box proposed for the padding isn't in the photo.
                guard cx < covered.x, cy < covered.y else { continue }
                let (width, height) = (Double(boxes[patch * 4 + 2]), Double(boxes[patch * 4 + 3]))
                let box = CGRect(
                    x: (cx - width / 2) / covered.x, y: (cy - height / 2) / covered.y,
                    width: width / covered.x, height: height / covered.y,
                ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard !box.isNull, box.width > 0, box.height > 0 else { continue }
                candidates.append(Detection(thing: name, score: score, box: box))
            }
            found += Self.distinct(candidates, overlap: Self.sameThing)
        }
        return Self.distinct(found, overlap: Self.sameAcross)
    }

    /// The most certain of each group of boxes overlapping by more than `overlap` (intersection
    /// over union), most certain first.
    static func distinct(_ detections: [Detection], overlap: Double) -> [Detection] {
        var kept: [Detection] = []
        for detection in detections.sorted(by: { $0.score > $1.score })
            where kept.allSatisfy({ intersectionOverUnion($0.box, detection.box) <= overlap }) {
            kept.append(detection)
        }
        return kept
    }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
        let shared = a.intersection(b)
        guard !shared.isNull else { return 0 }
        let intersection = shared.width * shared.height
        return intersection / (a.width * a.height + b.width * b.height - intersection)
    }

    /// The image as the model reads it: on a square of mid grey, at its top left, scaled to fill
    /// the square's longer side, in a BGRA buffer.
    static func square(_ image: CGImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, inputSize, inputSize, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer,
        )
        guard let buffer else { throw CocoaError(.fileReadCorruptFile) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: inputSize, height: inputSize, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) else { throw CocoaError(.fileReadCorruptFile) }
        let size = Double(inputSize)
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let scale = size / Double(max(image.width, image.height))
        let (width, height) = (Double(image.width) * scale, Double(image.height) * scale)
        // Core Graphics counts up from the bottom: the top left is `size - height` up.
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: size - height, width: width, height: height))
        return buffer
    }

    /// An output's values, row by row, whatever its strides and precision.
    static func floats(_ array: MLMultiArray) -> [Float] {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        let count = shape.reduce(1, *)
        var values = [Float](repeating: 0, count: count)
        for index in 0 ..< count {
            var rest = index, offset = 0
            for axis in shape.indices.reversed() {
                offset += (rest % shape[axis]) * strides[axis]
                rest /= shape[axis]
            }
            values[index] = switch array.dataType {
            case .float16: Float(array.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
            case .double: Float(array.dataPointer.assumingMemoryBound(to: Double.self)[offset])
            default: array.dataPointer.assumingMemoryBound(to: Float.self)[offset]
            }
        }
        return values
    }
}
