import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import RedlampEngineAPI

/// Objects masks with Segment Anything 2.1 (Apple's Core ML conversion of Meta's Hiera tiny).
///
/// The image encoder runs once per photo (about 60 ms on the GPU) on the analysis render
/// squashed to 1024²; each click then costs a prompt encode and a mask decode (about 10 ms).
/// These conversions run slower on the Neural Engine than on the GPU, so the GPU is used.
public final class SAMSegmenter: @unchecked Sendable {
    public static let inputSize = 1024

    /// The encoder's three outputs, which the decoder needs for every prompt.
    public struct Embedding: @unchecked Sendable {
        let image: MLMultiArray
        let featsS0: MLMultiArray
        let featsS1: MLMultiArray

        /// fp16 bytes of the three arrays, for the embedding cache.
        public func data() -> Data {
            var data = Data()
            for array in [image, featsS0, featsS1] {
                array.withUnsafeBytes { data.append(contentsOf: $0) }
            }
            return data
        }

        public init(data: Data) throws {
            func array(_ shape: [Int], at offset: inout Int) throws -> MLMultiArray {
                let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16)
                let length = shape.reduce(1, *) * 2
                guard offset + length <= data.count else { throw CocoaError(.fileReadCorruptFile) }
                array.withUnsafeMutableBytes { pointer, _ in
                    data.copyBytes(to: pointer.bindMemory(to: UInt8.self), from: offset ..< offset + length)
                }
                offset += length
                return array
            }
            var offset = 0
            image = try array([1, 256, 64, 64], at: &offset)
            featsS0 = try array([1, 32, 256, 256], at: &offset)
            featsS1 = try array([1, 64, 128, 128], at: &offset)
        }

        init(image: MLMultiArray, featsS0: MLMultiArray, featsS1: MLMultiArray) {
            self.image = image
            self.featsS0 = featsS0
            self.featsS1 = featsS1
        }
    }

    public let manifest: ModelManifest
    private let encoder: MLModel
    private let promptEncoder: MLModel
    private let decoder: MLModel
    private let lock = NSLock()

    /// Loads the model from `directory`, compiling it once into Caches.
    public init(manifest: ModelManifest, directory: URL) throws {
        self.manifest = manifest
        let configuration = MLModelConfiguration()
        configuration.computeUnits = switch manifest.computeUnits {
        case "cpuAndNeuralEngine": .cpuAndNeuralEngine
        case "all": .all
        default: .cpuAndGPU
        }
        let packages = Self.packages(in: manifest)
        func load(_ suffix: String) throws -> MLModel {
            guard let name = packages.first(where: { $0.hasSuffix("\(suffix)FLOAT16") || $0.contains(suffix) }) else {
                throw ModelStoreError.unknownModel("\(manifest.id) \(suffix)")
            }
            let compiled = try CompiledModels.compiled(
                package: directory.appending(path: "\(name).mlpackage"),
                key: "\(manifest.id)-v\(manifest.version)-\(name)",
            )
            return try MLModel(contentsOf: compiled, configuration: configuration)
        }
        encoder = try load("ImageEncoder")
        promptEncoder = try load("PromptEncoder")
        decoder = try load("MaskDecoder")
    }

    /// The `.mlpackage` names the manifest's files belong to.
    /// The names of the model's Core ML packages; its other files (a licence) aren't models.
    static func packages(in manifest: ModelManifest) -> [String] {
        Array(Set(manifest.files.compactMap { file in
            file.path.split(separator: "/").first.flatMap { component in
                component.hasSuffix(".mlpackage") ? String(component.dropLast(".mlpackage".count)) : nil
            }
        })).sorted()
    }

    public func embedding(for image: CGImage) throws -> Embedding {
        let buffer = try Self.pixelBuffer(image, size: Self.inputSize)
        let output = try lock.withLock {
            try encoder
                .prediction(
                    from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]),
                )
        }
        guard let image = output.featureValue(for: "image_embedding")?.multiArrayValue,
              let s0 = output.featureValue(for: "feats_s0")?.multiArrayValue,
              let s1 = output.featureValue(for: "feats_s1")?.multiArrayValue
        else { throw MaskComputationError.nothingFound(.objects) }
        return Embedding(image: image, featsS0: s0, featsS1: s1)
    }

    /// The object at the included points (or in `box`), without the excluded ones, as a mask of
    /// `size`. SAM's best-scoring of its three proposals is used.
    public func mask(
        _ embedding: Embedding, included: [ImagePoint], excluded: [ImagePoint] = [], box: ImageRect? = nil,
        size: PixelSize,
    ) throws -> GrayMask {
        // SAM reads a box as its corners, labelled 2 (top left) and 3 (bottom right).
        let corners = box.map { box in
            [
                (ImagePoint(x: box.x, y: box.y), Float(2)),
                (ImagePoint(x: box.x + box.width, y: box.y + box.height), Float(3)),
            ]
        } ?? []
        let prompts = included.map { ($0, Float(1)) } + excluded.map { ($0, Float(0)) } + corners
        guard !included.isEmpty || box != nil, prompts.count <= 16 else {
            throw MaskComputationError.nothingFound(.objects)
        }
        let points = try MLMultiArray(shape: [1, NSNumber(value: prompts.count), 2], dataType: .float32)
        let labels = try MLMultiArray(shape: [1, NSNumber(value: prompts.count)], dataType: .float32)
        for (index, (point, label)) in prompts.enumerated() {
            points[index * 2] = NSNumber(value: Float(point.x) * Float(Self.inputSize))
            points[index * 2 + 1] = NSNumber(value: Float(point.y) * Float(Self.inputSize))
            labels[index] = NSNumber(value: label)
        }
        let decoded = try lock.withLock { () -> MLFeatureProvider in
            let prompt = try promptEncoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "points": points, "labels": labels,
            ]))
            guard let sparse = prompt.featureValue(for: "sparse_embeddings"),
                  let dense = prompt.featureValue(for: "dense_embeddings")
            else { throw MaskComputationError.nothingFound(.objects) }
            return try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "image_embedding": MLFeatureValue(multiArray: embedding.image),
                "feats_s0": MLFeatureValue(multiArray: embedding.featsS0),
                "feats_s1": MLFeatureValue(multiArray: embedding.featsS1),
                "sparse_embedding": sparse,
                "dense_embedding": dense,
            ]))
        }
        guard let scores = decoded.featureValue(for: "scores")?.multiArrayValue,
              let masks = decoded.featureValue(for: "low_res_masks")?.multiArrayValue
        else { throw MaskComputationError.nothingFound(.objects) }
        let side = 256
        let pointer = UnsafeMutablePointer<Float16>(OpaquePointer(masks.dataPointer))
        let strides = masks.strides.map(\.intValue)
        // SAM proposes a part, a whole and a larger whole. With one click the best score is often
        // a part (a face rather than the person): among proposals scoring close to the best, the
        // largest wins. With more clicks, or a box, the user has said what they mean; the best
        // score wins.
        let best = (0 ..< 3).max { a, b in
            let scoreA = scores[a].floatValue
            let scoreB = scores[b].floatValue
            guard included.count == 1, box == nil else { return scoreA < scoreB }
            let top = (0 ..< 3).map { scores[$0].floatValue }.max() ?? 0
            let closeA = scoreA >= top - 0.15
            let closeB = scoreB >= top - 0.15
            if closeA != closeB {
                return !closeA
            }
            func area(_ index: Int) -> Int {
                var count = 0
                for y in stride(from: 0, to: side, by: 4) {
                    for x in stride(from: 0, to: side, by: 4)
                        where pointer[index * strides[1] + y * strides[2] + x * strides[3]] > 0 {
                        count += 1
                    }
                }
                return count
            }
            return area(a) < area(b)
        } ?? 0
        // Logits on the squashed 256² frame: a soft edge from the sigmoid, then the photo's shape.
        var coverage = [Float](repeating: 0, count: side * side)
        for y in 0 ..< side {
            for x in 0 ..< side {
                let logit = Float(pointer[best * strides[1] + y * strides[2] + x * strides[3]])
                coverage[y * side + x] = 1 / (1 + exp(-logit * 2))
            }
        }
        return GrayMask(width: side, height: side, coverage: coverage).resized(to: size)
    }

    /// The image drawn into a BGRA buffer of `size`², squashed as SAM's encoder expects.
    static func pixelBuffer(_ image: CGImage, size: Int) throws -> CVPixelBuffer {
        try pixelBuffer(image, width: size, height: size)
    }

    /// The image drawn (squashed if need be) into a BGRA buffer, as Core ML image inputs take it.
    static func pixelBuffer(_ image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer,
        )
        guard let buffer else { throw MaskComputationError.nothingFound(.objects) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
        ) else { throw MaskComputationError.nothingFound(.objects) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

/// Core ML models compiled once per version, kept in Caches (compiling takes seconds).
///
/// Core ML compiles into the temporary folder, as large as the model (SAM 3's encoder is
/// 850 MB), so one compile runs at a time: callers that ask while it runs wait and find it
/// in Caches, rather than each compiling a copy.
public enum CompiledModels {
    private static let lock = NSLock()
    /// Older than this, a compile left in the temporary folder belongs to a launch that ended
    /// before moving it into Caches.
    static let leftoverAge: TimeInterval = 60 * 60

    public static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "app.redlamp/CompiledModels")
    }

    /// Removes compiles of model versions `catalog` doesn't list; one is compiled again if needed.
    static func removeOutdated(catalog: [ModelManifest], in root: URL = root) {
        let current = catalog.map { "\($0.id)-v\($0.version)-" }
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return }
        for item in items where item.pathExtension == "mlmodelc" {
            let name = item.lastPathComponent
            if !current.contains(where: { name.hasPrefix($0) }) {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    static func compiled(package: URL, key: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let destination = root.appending(path: "\(key).mlmodelc")
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        removeLeftovers(of: package.deletingPathExtension().lastPathComponent)
        let compiled = try MLModel.compileModel(at: package)
        defer { try? FileManager.default.removeItem(at: compiled) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: compiled, to: destination)
        return destination
    }

    /// Removes compiles of the named model, `<name>.mlmodelc` or `<name>_<UUID>.mlmodelc`,
    /// that earlier launches left in `directory`.
    static func removeLeftovers(
        of name: String,
        in directory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date(),
    ) {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
        ) else { return }
        for item in items where item.pathExtension == "mlmodelc" {
            let stem = item.deletingPathExtension().lastPathComponent
            guard stem == name || stem.hasPrefix("\(name)_"),
                  let modified = try? item.resourceValues(forKeys: [.contentModificationDateKey])
                  .contentModificationDate,
                  now.timeIntervalSince(modified) > leftoverAge
            else { continue }
            try? fileManager.removeItem(at: item)
        }
    }
}
