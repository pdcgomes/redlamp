import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import RedlampEngineAPI

/// Relative depth for Depth Range on photos without an embedded depth map: Depth Anything V2
/// Small (Apple's Core ML conversion, 518×392). Evaluation only until DEC-02: its teacher was
/// trained on Virtual KITTI 2, which is non-commercial.
public final class DepthEstimator: @unchecked Sendable {
    public let manifest: ModelManifest
    private let model: MLModel
    private let lock = NSLock()

    public init(manifest: ModelManifest, directory: URL) throws {
        self.manifest = manifest
        let configuration = MLModelConfiguration()
        configuration.computeUnits = manifest.computeUnits == "cpuAndGPU" ? .cpuAndGPU : .all
        guard let name = SAMSegmenter.packages(in: manifest).first else {
            throw ModelStoreError.unknownModel(manifest.id)
        }
        let compiled = try CompiledModels.compiled(
            package: directory.appending(path: "\(name).mlpackage"), key: "\(manifest.id)-v\(manifest.version)-\(name)",
        )
        model = try MLModel(contentsOf: compiled, configuration: configuration)
    }

    /// Depth of `image` (near is white), scaled to the image's shape within `longEdge`, and
    /// snapped to its edges.
    public func depth(of image: CGImage, longEdge: Int = VisionMaskProvider.storedLongEdge) throws -> GrayMask {
        guard let input = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
            throw MaskComputationError.unsupported(.depthRange)
        }
        let buffer = try SAMSegmenter.pixelBuffer(image, width: input.pixelsWide, height: input.pixelsHigh)
        let output = try lock.withLock {
            try model
                .prediction(
                    from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]),
                )
        }
        guard let depth = output.featureValue(for: "depth")?.imageBufferValue else {
            throw MaskComputationError.unsupported(.depthRange)
        }
        // Relative inverse depth: larger is nearer. Normalised to the photo's own range.
        var values = try Self.values(depth)
        let sorted = values.sorted()
        let low = sorted[sorted.count / 100]
        let high = sorted[sorted.count * 99 / 100]
        let span = max(high - low, 1e-6)
        values = values.map { min(max(($0 - low) / span, 0), 1) }
        let size = PixelSize(width: image.width, height: image.height).fitted(within: PixelSize(
            width: longEdge,
            height: longEdge,
        ))
        let mask = GrayMask(
            width: CVPixelBufferGetWidth(depth),
            height: CVPixelBufferGetHeight(depth),
            coverage: values,
        )
        .resized(to: size)
        return GuidedFilter.refine(mask, guide: image, radius: 6, epsilon: 2e-3)
    }

    private static func values(_ buffer: CVPixelBuffer) throws -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer)
        else { throw MaskComputationError.unsupported(.depthRange) }
        var values = [Float](repeating: 0, count: width * height)
        let half = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent16Half
        for y in 0 ..< height {
            let row = base + y * rowBytes
            for x in 0 ..< width {
                values[y * width + x] = half
                    ? Float(row.load(fromByteOffset: x * 2, as: Float16.self))
                    : row.load(fromByteOffset: x * 4, as: Float.self)
            }
        }
        return values
    }
}
