import CoreGraphics
import Foundation
import Metal
import RedlampEngineAPI
import RedlampServices

extension RedlampEngine {
    /// Merges raw or bitmap frames given in focus order into one image and renders it with
    /// `recipe`. Runs on its own GPU queue, so interactive editing carries on meanwhile. Nothing
    /// is cached: save a `FocusStackDocument` and open it for that.
    public func renderFocusStack(
        _ urls: [URL],
        strategy: FocusStackStrategy = .auto,
        recipe: EditRecipe = EditRecipe(),
        maxLongEdge: Int? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
    ) async throws -> FocusStackPreview {
        let stacks = stacks
        let merged = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try stacks.merge(urls, strategy: strategy, documentURL: nil, progress: progress)
                })
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
        return FocusStackPreview(image: image, depth: depthImage(merged), report: merged.report)
    }

    /// The depth map over the cropped stack as an oriented grey image: black at the first frame,
    /// white at the last.
    private func depthImage(_ stack: MergedStack) -> CGImage {
        let (w, h) = (stack.depthWidth, stack.depthHeight)
        // The crop is in reference pixels; the depth map spans the whole reference frame.
        let scale = Float(w) / Float(max(stack.frameWidth, 1))
        let x0 = min(Int(Float(stack.crop.x) * scale), w - 1)
        let y0 = min(Int(Float(stack.crop.y) * scale), h - 1)
        let cw = max(1, min(Int(Float(stack.crop.width) * scale), w - x0))
        let ch = max(1, min(Int(Float(stack.crop.height) * scale), h - y0))
        let orientation = stack.decoded.orientation
        let rotated = orientation == 5 || orientation == 6
        let (outWidth, outHeight) = rotated ? (ch, cw) : (cw, ch)
        let levels = 255 / Float(max(stack.report.frames - 1, 1))
        var pixels = [UInt8](repeating: 0, count: outWidth * outHeight)
        for oy in 0 ..< outHeight {
            for ox in 0 ..< outWidth {
                let (sx, sy) = switch orientation {
                case 3: (cw - 1 - ox, ch - 1 - oy)
                case 5: (cw - 1 - oy, ox)
                case 6: (oy, ch - 1 - ox)
                default: (ox, oy)
                }
                let value = stack.depth[(y0 + sy) * w + x0 + sx] * levels
                pixels[oy * outWidth + ox] = UInt8(min(max(value, 0), 255).rounded())
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
