import Foundation
import Metal
import RedlampEngineAPI
import RedlampServices
import simd

extension FocusStackCache {
    /// `stack` with each stroke painting its source over it, in order.
    func retouch(
        _ stack: MergedStack, with strokes: [FocusStackStroke], document: FocusStackDocument, at url: URL,
    ) throws -> MergedStack {
        var samples = stack.decoded.samples
        var sources: [FocusStackStroke.Source: [UInt16]] = [:]
        for stroke in strokes {
            let source = try sources[stroke.source] ?? pixels(
                of: stroke.source,
                like: stack,
                document: document,
                at: url,
            )
            sources[stroke.source] = source
            Self.paint(
                stroke, from: source, into: &samples,
                size: PixelSize(width: stack.decoded.width, height: stack.decoded.height),
                orientation: stack.decoded.orientation,
            )
        }
        return stack.with(samples: samples)
    }

    /// A stroke's source over the same crop as `stack`, as float16 RGBA.
    private func pixels(
        of source: FocusStackStroke.Source, like stack: MergedStack, document: FocusStackDocument, at url: URL,
    ) throws -> [UInt16] {
        let frames = document.frameURLs(at: url)
        switch source {
        case let .strategy(strategy):
            let other = try merged(frames, strategy: strategy, documentURL: url)
            return Self.recropped(other.decoded.samples, from: other.crop, to: stack.crop)
        case let .frame(path):
            guard let index = document.frames.firstIndex(of: path) else {
                throw EngineError.renderFailed("\(path) is not a frame of this stack")
            }
            return try alignedFrame(frames[index], index: index, like: stack)
        }
    }

    /// Frame `index` warped into the reference and brightness-matched, as the merge saw it.
    private func alignedFrame(_ url: URL, index: Int, like stack: MergedStack) throws -> [UInt16] {
        guard let queue = device.makeCommandQueue() else { throw EngineError.gpuUnavailable }
        let builder = SessionBuilder(device: device, queue: queue, kernels: kernels)
        let stacker = FocusStacker(device: device, queue: queue, kernels: kernels)
        let frame = try builder.demosaic(ImageDecoder.decode(url))
        let warped = try stacker.makeTexture(.rgba16Float, stack.frameWidth, stack.frameHeight)
        let crop = stack.crop
        let rowBytes = crop.width * 8
        guard let commands = queue.makeCommandBuffer(),
              let buffer = device.makeBuffer(length: rowBytes * crop.height, options: .storageModeShared)
        else {
            throw EngineError.gpuUnavailable
        }
        try stacker.encodeWarp(
            frame.texture, transform: stack.alignment.transforms[index], gain: stack.alignment.gains[index],
            into: warped, commands: commands,
        )
        guard let blit = commands.makeBlitCommandEncoder() else { throw EngineError.gpuUnavailable }
        blit.copy(
            from: warped, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: crop.x, y: crop.y, z: 0),
            sourceSize: MTLSize(width: crop.width, height: crop.height, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * crop.height,
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error {
            throw EngineError.renderFailed(error.localizedDescription)
        }
        let halves = buffer.contents().assumingMemoryBound(to: UInt16.self)
        return Array(UnsafeBufferPointer(start: halves, count: crop.width * crop.height * 4))
    }

    /// Float16 RGBA pixels cropped at `from`, moved to the crop `to` (same reference frame);
    /// pixels outside `from` are transparent black.
    static func recropped(_ samples: [UInt16], from: PixelRect, to: PixelRect) -> [UInt16] {
        guard from != to else { return samples }
        var out = [UInt16](repeating: 0, count: to.width * to.height * 4)
        for y in 0 ..< to.height {
            let sy = y + to.y - from.y
            guard sy >= 0, sy < from.height else { continue }
            for x in 0 ..< to.width {
                let sx = x + to.x - from.x
                guard sx >= 0, sx < from.width else { continue }
                for channel in 0 ..< 4 {
                    out[(y * to.width + x) * 4 + channel] = samples[(sy * from.width + sx) * 4 + channel]
                }
            }
        }
        return out
    }

    /// Blends `source` into `samples` under the stroke: full strength within `hardness` of the
    /// radius, then a smooth falloff to the edge, scaled by the opacity.
    static func paint(
        _ stroke: FocusStackStroke, from source: [UInt16], into samples: inout [UInt16], size: PixelSize,
        orientation: Int,
    ) {
        let (width, height) = (size.width, size.height)
        guard !stroke.points.isEmpty, stroke.opacity > 0, stroke.radius > 0 else { return }
        let radius = Float(stroke.radius) * Float(max(width, height))
        let points = stroke.points.map { point in
            let unoriented = sourceCoordinate(point, orientation: orientation)
            return SIMD2<Float>(Float(unoriented.x) * Float(width), Float(unoriented.y) * Float(height))
        }
        // The stroke's mask over its bounding box: the strongest coverage from any segment.
        let low = points.reduce(SIMD2(repeating: .infinity)) { pointwiseMin($0, $1) } - radius
        let high = points.reduce(SIMD2(repeating: -.infinity)) { pointwiseMax($0, $1) } + radius
        let x0 = max(Int(low.x.rounded(.down)), 0)
        let y0 = max(Int(low.y.rounded(.down)), 0)
        let x1 = min(Int(high.x.rounded(.up)), width)
        let y1 = min(Int(high.y.rounded(.up)), height)
        guard x1 > x0, y1 > y0 else { return }
        let boxWidth = x1 - x0
        var mask = [Float](repeating: 0, count: boxWidth * (y1 - y0))
        let hardness = Float(min(max(stroke.hardness, 0), 0.999))
        let opacity = Float(min(stroke.opacity, 1))
        let segments = points.count == 1 ? [(points[0], points[0])] : Array(zip(points, points.dropFirst()))
        for (a, b) in segments {
            let sx0 = max(Int((min(a.x, b.x) - radius).rounded(.down)), x0)
            let sx1 = min(Int((max(a.x, b.x) + radius).rounded(.up)), x1)
            let sy0 = max(Int((min(a.y, b.y) - radius).rounded(.down)), y0)
            let sy1 = min(Int((max(a.y, b.y) + radius).rounded(.up)), y1)
            let ab = b - a
            let length2 = max(dot(ab, ab), 1e-12)
            for y in sy0 ..< max(sy1, sy0) {
                for x in sx0 ..< max(sx1, sx0) {
                    let p = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                    let t = min(max(dot(p - a, ab) / length2, 0), 1)
                    let distance = simd_length(p - (a + t * ab)) / radius
                    guard distance < 1 else { continue }
                    let edge = distance <= hardness ? 1 : (1 - distance) / (1 - hardness)
                    let weight = opacity * edge * edge * (3 - 2 * edge)
                    let index = (y - y0) * boxWidth + x - x0
                    mask[index] = max(mask[index], weight)
                }
            }
        }
        for y in y0 ..< y1 {
            for x in x0 ..< x1 {
                let weight = mask[(y - y0) * boxWidth + x - x0]
                let pixel = (y * width + x) * 4
                // Transparent source pixels (outside another method's crop) leave the merge alone.
                guard weight > 0, Float(Float16(bitPattern: source[pixel + 3])) > 0 else { continue }
                for channel in 0 ..< 3 {
                    let base = Float(Float16(bitPattern: samples[pixel + channel]))
                    let paint = Float(Float16(bitPattern: source[pixel + channel]))
                    samples[pixel + channel] = Float16(base + weight * (paint - base)).bitPattern
                }
            }
        }
    }
}
