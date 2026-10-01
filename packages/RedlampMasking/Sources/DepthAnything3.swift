import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import RedlampEngineAPI

/// Depth Anything 3 Mono-L (ByteDance Seed), converted by `research/prototypes/masking/convert_da3.py`:
/// relative depth and a sky mask from one inference, at a fixed 504×336. Portrait photos are
/// turned on their side for it and the results turned back.
///
/// In the sky bake-off (MSK-17) its sky scored IoU 0.929, and averaged with Segment Anything's
/// 0.946. Evaluation only: its weights are Apache-2.0 but its training data isn't audited.
public final class DepthAnything3: @unchecked Sendable {
    public static let inputWidth = 504
    public static let inputHeight = 336

    public struct Result: Sendable {
        /// Near is white, normalised to the photo's own range.
        public var depth: GrayMask
        /// Sky as the model sees it (≥ 0.5), soft only where resampled.
        public var sky: GrayMask
    }

    public let manifest: ModelManifest
    private let model: MLModel
    private let lock = NSLock()

    public init(manifest: ModelManifest, directory: URL) throws {
        self.manifest = manifest
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        guard let name = SAMSegmenter.packages(in: manifest).first
        else { throw ModelStoreError.unknownModel(manifest.id) }
        let compiled = try CompiledModels.compiled(
            package: directory.appending(path: "\(name).mlpackage"), key: "\(manifest.id)-v\(manifest.version)-\(name)",
        )
        model = try MLModel(contentsOf: compiled, configuration: configuration)
    }

    /// Depth and sky of `image`, in its shape within `longEdge`.
    public func predict(_ image: CGImage, longEdge: Int = VisionMaskProvider.partsLongEdge) throws -> Result {
        let portrait = image.height > image.width
        let buffer = try Self.input(image, portrait: portrait)
        let output = try lock.withLock {
            try model
                .prediction(
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
        var depthMask = GrayMask(
            width: Self.inputWidth, height: Self.inputHeight,
            coverage: depths.map { 1 - min(max(($0 - low) / span, 0), 1) },
        )
        var skyMask = GrayMask(
            width: Self.inputWidth, height: Self.inputHeight, pixels: Self.values(sky).map { $0 >= 0.5 ? 255 : 0 },
        )
        if portrait {
            depthMask = depthMask.rotatedCounterClockwise()
            skyMask = skyMask.rotatedCounterClockwise()
        }
        let size = PixelSize(width: image.width, height: image.height)
            .fitted(within: PixelSize(width: longEdge, height: longEdge))
        return Result(
            depth: GuidedFilter.refine(depthMask.resized(to: size), guide: image, radius: 6, epsilon: 2e-3),
            sky: skyMask.resized(to: size),
        )
    }

    /// The model's BGRA input: the photo squashed to 504×336, turned clockwise first if portrait.
    static func input(_ image: CGImage, portrait: Bool) throws -> CVPixelBuffer {
        let width = inputWidth
        let height = inputHeight
        let source = portrait ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height)
        guard let rgb = RGBImage(image, size: source) else { throw MaskComputationError.unsupported(.depthRange) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer,
        )
        guard let buffer else { throw MaskComputationError.unsupported(.depthRange) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)
        else { throw MaskComputationError.unsupported(.depthRange) }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0 ..< height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0 ..< width {
                // Turned clockwise: the result's (x, y) is the source's (y, sourceHeight - 1 - x).
                let rgbValue = portrait ? rgb.rgb(y, source.height - 1 - x) : rgb.rgb(x, y)
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

extension GrayMask {
    /// Turned a quarter counter-clockwise: the inverse of the clockwise turn `DepthAnything3`'s
    /// input makes for portrait photos.
    func rotatedCounterClockwise() -> GrayMask {
        var out = [UInt8](repeating: 0, count: pixels.count)
        let outWidth = height
        let outHeight = width
        for y in 0 ..< outHeight {
            for x in 0 ..< outWidth {
                out[y * outWidth + x] = pixels[x * width + (width - 1 - y)]
            }
        }
        return GrayMask(width: outWidth, height: outHeight, pixels: out)
    }
}
