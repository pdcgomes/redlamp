import Metal
import RedlampEngineAPI
import RedlampServices
import simd

/// Where DNG gain maps (lens shading) brightened the raw, they amplified its noise too, but the
/// noise model describes the sensor before them. This is the gain per camera channel over the
/// frame, so noise reduction and the dual-demosaic blend can scale the noise to match: after a
/// gain g, variance a·v + b becomes g·a·v + g²·b.
enum NoiseGain {
    /// Texels on the long edge; lens shading is smooth.
    static let resolution = 64

    struct Field {
        let width: Int
        let height: Int
        /// Row-major gains per camera channel (w unused), at texel centres.
        let gains: [SIMD4<Float>]
    }

    /// The field for an image `width` x `height`; a mosaic's channels come from `pattern`,
    /// averaged over the pattern's sites near each texel (Bayer's two greens), otherwise planes.
    static func field(_ maps: [GainMap], width: Int, height: Int, pattern: CFAPattern?) -> Field {
        guard !maps.isEmpty, width > 0, height > 0 else {
            return Field(width: 1, height: 1, gains: [SIMD4(1, 1, 1, 1)])
        }
        let scale = Double(resolution) / Double(max(width, height))
        let columns = max(1, Int((Double(width) * scale).rounded()))
        let rows = max(1, Int((Double(height) * scale).rounded()))
        func gain(x: Int, y: Int, plane: Int) -> Float {
            maps.reduce(1) { $0 * ($1.gain(x: x, y: y, plane: plane, width: width, height: height) ?? 1) }
        }
        var gains: [SIMD4<Float>] = []
        gains.reserveCapacity(columns * rows)
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let cx = min(Int((Double(column) + 0.5) / Double(columns) * Double(width)), width - 1)
                let cy = min(Int((Double(row) + 0.5) / Double(rows) * Double(height)), height - 1)
                guard let pattern else {
                    gains.append(SIMD4((0 ..< 3).map { gain(x: cx, y: cy, plane: $0) } + [1]))
                    continue
                }
                var sum = SIMD4<Float>.zero
                var count = SIMD4<Float>.zero
                let x0 = min(cx - cx % pattern.width, max(width - pattern.width, 0))
                let y0 = min(cy - cy % pattern.height, max(height - pattern.height, 0))
                for y in y0 ..< min(y0 + pattern.height, height) {
                    for x in x0 ..< min(x0 + pattern.width, width) {
                        let color = Int(pattern.colors[(y % pattern.height) * pattern.width + x % pattern.width])
                        let channel = color == 3 ? 1 : min(color, 2)
                        sum[channel] += gain(x: x, y: y, plane: 0)
                        count[channel] += 1
                    }
                }
                let mean = sum / simd_max(count, SIMD4(repeating: 1))
                gains.append(SIMD4(repeating: 1).replacing(with: mean, where: count .> 0))
            }
        }
        return Field(width: columns, height: rows, gains: gains)
    }

    static func texture(_ field: Field, device: any MTLDevice) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: field.width, height: field.height, mipmapped: false,
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
        field.gains.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, field.width, field.height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: field.width * MemoryLayout<SIMD4<Float>>.stride,
            )
        }
        return texture
    }
}
