import CoreGraphics
import Foundation
import Metal
import RedlampEngineAPI
import RedlampServices

extension RedlampEngine {
    /// Merges raw or bitmap frames given in focus order into one image and renders it with
    /// `recipe`. Runs on its own GPU queue, so interactive editing carries on meanwhile.
    public func renderFocusStack(
        _ urls: [URL],
        strategy: FocusStackStrategy = .auto,
        recipe: EditRecipe = EditRecipe(),
        maxLongEdge: Int? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
    ) async throws -> FocusStackPreview {
        guard urls.count >= 2 else { throw EngineError.renderFailed("a focus stack needs at least two frames") }
        let merged = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(with: Result { try mergeFocusStack(urls, strategy: strategy, progress: progress) })
            }
        }
        guard let queue = device.makeCommandQueue() else { throw EngineError.gpuUnavailable }
        let session = try SessionBuilder(device: device, queue: queue, kernels: kernels).build(merged.decoded)
        let request = StillRequest(recipe: recipe, maxLongEdge: maxLongEdge, purpose: .export)
        let image = try await withCheckedThrowingContinuation { continuation in
            renderQueue.async { [self] in
                continuation.resume(with: Result { try renderStillNow(request, session: session) })
            }
        }
        return FocusStackPreview(image: image, depth: merged.depth, report: merged.report)
    }

    /// Decodes, aligns and fuses the frames; returns the result as a linear camera RGB image with
    /// the reference frame's calibration, ready to develop like any raw.
    private func mergeFocusStack(
        _ urls: [URL], strategy: FocusStackStrategy, progress: (Double) -> Void,
    ) throws -> MergedStack {
        guard let queue = device.makeCommandQueue() else { throw EngineError.gpuUnavailable }
        queue.label = "Focus stack"
        let builder = SessionBuilder(device: device, queue: queue, kernels: kernels)
        let stacker = FocusStacker(device: device, queue: queue, kernels: kernels)
        var metadata: [Int: DecodedImage] = [:]
        let result = try stacker.merge(
            frameCount: urls.count, settings: StackMergeSettings(strategy: strategy),
            load: { index in
                let frame = try builder.demosaic(ImageDecoder.decode(urls[index]))
                metadata[index] = frame.decoded.withoutSamples
                return frame.texture
            },
            progress: progress,
        )
        let alignment = result.alignment
        guard let reference = metadata[alignment.reference] else { throw EngineError.gpuUnavailable }
        let decoded = try unbalanced(result.fused, like: reference, queue: queue)
        let report = FocusStackReport(
            frames: urls.count,
            reference: alignment.reference,
            width: decoded.width,
            height: decoded.height,
            maximumScaleChange: Double(alignment.transforms.map { abs($0.scale - 1) }.max() ?? 0),
            minimumCorrelation: Double(alignment.correlations.min() ?? 1),
            confidentDepthFraction: Double(result.depth.confidentFraction),
            timings: result.timings,
        )
        let depth = depthImage(result.depth, frames: urls.count, orientation: reference.orientation)
        return MergedStack(decoded: decoded, report: report, depth: depth)
    }

    /// The fused balanced image as 16-bit linear camera RGB: normalisation multiplies by the
    /// white balance again when it develops, so it comes off here.
    private func unbalanced(
        _ fused: any MTLTexture, like reference: DecodedImage, queue: any MTLCommandQueue,
    ) throws -> DecodedImage {
        let (width, height) = (fused.width, fused.height)
        let rowBytes = width * 8
        guard let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else {
            throw EngineError.gpuUnavailable
        }
        blit.copy(
            from: fused, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height,
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let balance = SIMD3<Float>(SessionBuilder.balance(reference))
        let scale = SIMD3<Float>(repeating: 65535) / balance
        nonisolated(unsafe) let halves = buffer.contents().assumingMemoryBound(to: Float16.self)
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        samples.withUnsafeMutableBufferPointer { rows in
            // Each iteration writes its own row.
            nonisolated(unsafe) let out = rows
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for x in 0 ..< width {
                    let source = (y * width + x) * 4
                    let destination = (y * width + x) * 3
                    for channel in 0 ..< 3 {
                        let value = Float(halves[source + channel]) * scale[channel]
                        out[destination + channel] = UInt16(min(max(value, 0), 65535).rounded())
                    }
                }
            }
        }
        return DecodedImage(
            width: width, height: height, layout: .linearRGB, samples: samples,
            blackLevels: [0, 0, 0], whiteLevel: 65535, asShotMultipliers: reference.asShotMultipliers,
            cameraToSRGB: reference.cameraToSRGB, xyzToCamera: reference.xyzToCamera,
            orientation: reference.orientation, baselineExposure: reference.baselineExposure, info: reference.info,
        )
    }

    /// The depth map as an oriented grey image: black at the first frame, white at the last.
    private func depthImage(_ depth: StackDepthMap, frames: Int, orientation: Int) -> CGImage {
        let (w, h) = (depth.width, depth.height)
        let rotated = orientation == 5 || orientation == 6
        let (outWidth, outHeight) = rotated ? (h, w) : (w, h)
        let scale = 255 / Float(max(frames - 1, 1))
        var pixels = [UInt8](repeating: 0, count: outWidth * outHeight)
        for oy in 0 ..< outHeight {
            for ox in 0 ..< outWidth {
                let (sx, sy) = switch orientation {
                case 3: (w - 1 - ox, h - 1 - oy)
                case 5: (w - 1 - oy, ox)
                case 6: (oy, h - 1 - ox)
                default: (ox, oy)
                }
                pixels[oy * outWidth + ox] = UInt8(min(max(depth.depth[sy * w + sx] * scale, 0), 255).rounded())
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: outWidth, height: outHeight, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: outWidth,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent,
        )!
    }
}

private struct MergedStack: Sendable {
    let decoded: DecodedImage
    let report: FocusStackReport
    let depth: CGImage
}

private extension DecodedImage {
    /// The calibration and metadata without the sensor data.
    var withoutSamples: DecodedImage {
        var copy = DecodedImage(
            width: width, height: height, layout: layout, samples: [], blackLevels: blackLevels,
            whiteLevel: whiteLevel, asShotMultipliers: asShotMultipliers, cameraToSRGB: cameraToSRGB,
            xyzToCamera: xyzToCamera, orientation: orientation, baselineExposure: baselineExposure, info: info,
        )
        copy.noiseProfile = noiseProfile
        return copy
    }
}
