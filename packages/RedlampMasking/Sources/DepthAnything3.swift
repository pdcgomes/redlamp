import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import RedlampEngineAPI

/// Depth Anything 3 Mono-L (ByteDance Seed), converted by `research/prototypes/masking/convert_da3.py`:
/// relative depth and a sky mask from one inference. The package has two functions sharing one
/// set of weights: `landscape` at 504×336 and `portrait` at 336×504. Turned on its side, the
/// model misses small patches of sky.
///
/// In the sky bake-off (MSK-17) its sky scored IoU 0.931, and averaged with Segment Anything's
/// 0.945. Evaluation only: its weights are Apache-2.0 but its training data isn't audited.
public final class DepthAnything3: @unchecked Sendable {
    /// The input's long and short sides.
    public static let inputLong = 504
    public static let inputShort = 336

    public struct Result: Sendable {
        /// Near is white, normalised to the photo's own range.
        public var depth: GrayMask
        /// Sky as the model sees it (≥ 0.5), soft only where resampled.
        public var sky: GrayMask
    }

    public let manifest: ModelManifest
    private let compiled: URL
    private var models: [Bool: MLModel] = [:]
    private let lock = NSLock()

    public init(manifest: ModelManifest, directory: URL) throws {
        self.manifest = manifest
        guard let name = SAMSegmenter.packages(in: manifest).first
        else { throw ModelStoreError.unknownModel(manifest.id) }
        compiled = try CompiledModels.compiled(
            package: directory.appending(path: "\(name).mlpackage"), key: "\(manifest.id)-v\(manifest.version)-\(name)",
        )
        _ = try model(portrait: false)
    }

    /// The function for the photo's orientation, loaded on first use.
    private func model(portrait: Bool) throws -> MLModel {
        if let model = models[portrait] {
            return model
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        configuration.functionName = portrait ? "portrait" : "landscape"
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        models[portrait] = model
        return model
    }

    /// Depth and sky of `image`, in its shape within `longEdge`.
    public func predict(_ image: CGImage, longEdge: Int = VisionMaskProvider.partsLongEdge) throws -> Result {
        let portrait = image.height > image.width
        let input = portrait
            ? PixelSize(width: Self.inputShort, height: Self.inputLong)
            : PixelSize(width: Self.inputLong, height: Self.inputShort)
        let buffer = try Self.input(image, size: input)
        let output = try lock.withLock {
            try model(portrait: portrait).prediction(
                from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]),
            )
        }
        guard let depth = output.featureValue(for: "depth")?.multiArrayValue,
              let sky = output.featureValue(for: "sky")?.multiArrayValue
        else { throw MaskComputationError.unsupported(.depthRange) }

        // Depth: larger is farther. Near becomes white, between the 1st and 99th percentiles.
        let depths = Self.values(depth)
        let sorted = depths.sorted()
        let low = sorted[sorted.count / 100]
        let high = sorted[sorted.count * 99 / 100]
        let span = max(high - low, 1e-6)
        let depthMask = GrayMask(
            width: input.width, height: input.height,
            coverage: depths.map { 1 - min(max(($0 - low) / span, 0), 1) },
        )
        let skyMask = GrayMask(
            width: input.width, height: input.height, pixels: Self.values(sky).map { $0 >= 0.5 ? 255 : 0 },
        )
        let size = PixelSize(width: image.width, height: image.height)
            .fitted(within: PixelSize(width: longEdge, height: longEdge))
        return Result(
            depth: GuidedFilter.refine(depthMask.resized(to: size), guide: image, radius: 6, epsilon: 2e-3),
            sky: skyMask.resized(to: size),
        )
    }

    /// The model's BGRA input: the photo squashed to `size`.
    static func input(_ image: CGImage, size: PixelSize) throws -> CVPixelBuffer {
        guard let rgb = RGBImage(image, size: size) else { throw MaskComputationError.unsupported(.depthRange) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, size.width, size.height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer,
        )
        guard let buffer else { throw MaskComputationError.unsupported(.depthRange) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)
        else { throw MaskComputationError.unsupported(.depthRange) }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0 ..< size.height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0 ..< size.width {
                let rgbValue = rgb.rgb(x, y)
                row[x * 4] = UInt8(rgbValue.z * 255)
                row[x * 4 + 1] = UInt8(rgbValue.y * 255)
                row[x * 4 + 2] = UInt8(rgbValue.x * 255)
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    /// A [1, 1, height, width] output, row by row. Core ML pads rows, so the strides are read.
    static func values(_ array: MLMultiArray) -> [Float] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        let height = shape[shape.count - 2]
        let width = shape[shape.count - 1]
        let rowStride = strides[strides.count - 2]
        let columnStride = strides[strides.count - 1]
        func read(_ element: (Int) -> Float) -> [Float] {
            var values = [Float](repeating: 0, count: width * height)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    values[y * width + x] = element(y * rowStride + x * columnStride)
                }
            }
            return values
        }
        switch array.dataType {
        case .float16:
            let pointer = array.dataPointer.assumingMemoryBound(to: Float16.self)
            return read { Float(pointer[$0]) }
        case .float32:
            let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
            return read { pointer[$0] }
        default:
            return read { array[$0].floatValue }
        }
    }
}
