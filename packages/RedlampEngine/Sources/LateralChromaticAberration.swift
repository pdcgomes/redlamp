import Foundation
import Metal
import RedlampEngineAPI
import simd

/// Lateral chromatic aberration measured from the photo itself, for Remove Chromatic Aberration
/// when the file carries no correction of its own (LNS-09). A lens records red and blue at a
/// slightly different scale than green, so at edges across the frame they sit a little further
/// out or in. In tiles spread over the frame, a Lucas–Kanade step along the radius finds each
/// channel's shift against green where the edges run across the radius; a fit of those shifts,
/// a·r + b·r³, gives each channel's recorded scale, 1 + a + b·r².
enum LateralChromaticAberration {
    /// The measurement, made once per photo the first time an edit asks for it.
    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var measured = false
        private var value: LensCorrection?

        func value(_ measure: () -> LensCorrection?) -> LensCorrection? {
            lock.lock()
            defer { lock.unlock() }
            if !measured {
                value = measure()
                measured = true
            }
            return value
        }
    }

    static let tileSize = 128
    static let grid = (columns: 8, rows: 6)
    /// The pyramid level measured: the finest whose long edge is at most this.
    static let longEdge = 3072
    /// Smaller corrections than this (in recorded scale anywhere out to the corners) are none.
    static let significant = 2e-5

    static func estimate(_ session: ImageSession) -> LensCorrection? {
        let pyramid = session.pyramid
        let level = (0 ..< pyramid.mipmapLevelCount).first { max(pyramid.width, pyramid.height) >> $0 <= longEdge }
            ?? pyramid.mipmapLevelCount - 1
        let (width, height) = (max(1, pyramid.width >> level), max(1, pyramid.height >> level))
        guard width >= tileSize * 2, height >= tileSize * 2, let tiles = readTiles(pyramid, level: level) else {
            return nil
        }
        // In the source's own orientation; a radial scale about the centre looks the same in any.
        let centre = SIMD2(Double(width), Double(height)) / 2
        let reach = simd_length(centre)
        var samples: [(radius: Double, shift: SIMD2<Double>, weight: SIMD2<Double>)] = []
        for (origin, pixels) in tiles {
            if let measured = shifts(pixels, origin: origin, centre: centre) {
                let tileCentre = SIMD2(Double(origin.x), Double(origin.y)) + Double(tileSize) / 2
                samples.append((simd_distance(tileCentre, centre) / reach, measured.shift / reach, measured.weight))
            }
        }
        guard samples.count >= 6 else { return nil }
        // Weighted least squares for a·r + b·r³, red and blue each.
        func fit(_ channel: Int) -> (a: Double, b: Double)? {
            var (s11, s13, s33, t1, t3) = (0.0, 0.0, 0.0, 0.0, 0.0)
            for sample in samples where sample.weight[channel] > 0 {
                let (r, w, y) = (sample.radius, sample.weight[channel], sample.shift[channel])
                s11 += w * r * r
                s13 += w * r * r * r * r
                s33 += w * pow(r, 6)
                t1 += w * r * y
                t3 += w * r * r * r * y
            }
            let determinant = s11 * s33 - s13 * s13
            guard abs(determinant) > 1e-18 else { return nil }
            let a = (t1 * s33 - t3 * s13) / determinant, b = (s11 * t3 - s13 * t1) / determinant
            // A lens's fringes stay well under 1% of the radius.
            guard abs(a) < 0.005, abs(b) < 0.01 else { return nil }
            return (a, b)
        }
        let red = fit(0) ?? (0, 0), blue = fit(1) ?? (0, 0)
        let radii = (0 ... 16).map { Double($0) / 16 * 1.2 }
        let scales = radii.map { r in SIMD3(1 + red.a + red.b * r * r, 1, 1 + blue.a + blue.b * r * r) }
        guard scales.contains(where: { abs($0.x - 1) > significant || abs($0.z - 1) > significant }) else { return nil }
        return LensCorrection(
            source: .measured,
            center: SIMD2(0.5, 0.5),
            radii: radii,
            distortion: scales,
            vignetting: [],
        )
    }

    /// Red's and blue's radial shift against green in one tile, in source pixels, and how much
    /// evidence each has (zero for none).
    private static func shifts(
        _ pixels: [SIMD3<Float>], origin: SIMD2<Int>, centre: SIMD2<Double>,
    ) -> (shift: SIMD2<Double>, weight: SIMD2<Double>)? {
        let n = tileSize
        func at(_ x: Int, _ y: Int) -> SIMD3<Float> {
            pixels[min(max(y, 0), n - 1) * n + min(max(x, 0), n - 1)]
        }
        /// Bilinear, for the channel moved along the radius.
        func sample(_ p: SIMD2<Double>, _ channel: Int) -> Double {
            let x = min(max(p.x, 0), Double(n - 1)), y = min(max(p.y, 0), Double(n - 1))
            let (x0, y0) = (Int(x), Int(y))
            let (fx, fy) = (x - Double(x0), y - Double(y0))
            let top = Double(at(x0, y0)[channel]) * (1 - fx) + Double(at(x0 + 1, y0)[channel]) * fx
            let bottom = Double(at(x0, y0 + 1)[channel]) * (1 - fx) + Double(at(x0 + 1, y0 + 1)[channel]) * fx
            return top * (1 - fy) + bottom * fy
        }
        let mean = pixels.reduce(SIMD3<Float>.zero, +) / Float(pixels.count)
        guard mean.min() > 1e-4 else { return nil }
        let gains = SIMD2(Double(mean.y / mean.x), Double(mean.y / mean.z))
        // Edge pixels whose gradient runs along the radius.
        var edges: [(p: SIMD2<Double>, u: SIMD2<Double>, green: Double)] = []
        let threshold = 0.04 * Double(mean.y)
        for y in 2 ..< n - 2 {
            for x in 2 ..< n - 2 {
                let gx = Double(at(x + 1, y).y - at(x - 1, y).y) / 2, gy = Double(at(x, y + 1).y - at(x, y - 1).y) / 2
                let magnitude = (gx * gx + gy * gy).squareRoot()
                guard magnitude > threshold else { continue }
                let offset = SIMD2(Double(origin.x + x), Double(origin.y + y)) - centre
                guard simd_length(offset) > 1 else { continue }
                let u = simd_normalize(offset)
                guard abs(gx * u.x + gy * u.y) > 0.7 * magnitude else { continue }
                edges.append((SIMD2(Double(x), Double(y)), u, Double(at(x, y).y)))
            }
        }
        guard edges.count >= 40 else { return nil }
        var shift = SIMD2<Double>.zero, weight = SIMD2<Double>.zero
        for (index, channel) in [0, 2].enumerated() {
            var delta = 0.0, evidence = 0.0
            for _ in 0 ..< 4 {
                var (numerator, denominator) = (0.0, 0.0)
                for edge in edges {
                    let p = edge.p + delta * edge.u
                    let value = sample(p, channel) * gains[index]
                    let slope = (sample(p + edge.u, channel) - sample(p - edge.u, channel)) / 2 * gains[index]
                    numerator += (edge.green - value) * slope
                    denominator += slope * slope
                }
                guard denominator > 0 else { break }
                let step = numerator / denominator
                delta += step
                evidence = denominator
                if abs(step) < 1e-3 {
                    break
                }
            }
            guard abs(delta) < 4 else { continue }
            shift[index] = delta
            weight[index] = evidence
        }
        return (shift, weight)
    }

    /// The grid's tiles at `level`, read back as camera RGB.
    private static func readTiles(_ pyramid: any MTLTexture, level: Int) -> [(SIMD2<Int>, [SIMD3<Float>])]? {
        let device = pyramid.device
        let (width, height) = (max(1, pyramid.width >> level), max(1, pyramid.height >> level))
        let n = tileSize
        var origins: [SIMD2<Int>] = []
        for row in 0 ..< grid.rows {
            for column in 0 ..< grid.columns {
                let u = 0.04 + 0.92 * (Double(column) + 0.5) / Double(grid.columns)
                let v = 0.04 + 0.92 * (Double(row) + 0.5) / Double(grid.rows)
                let origin = SIMD2(Int(u * Double(width)) - n / 2, Int(v * Double(height)) - n / 2)
                origins.append(simd_clamp(origin, .zero, SIMD2(width - n, height - n)))
            }
        }
        let tileBytes = n * n * 8
        guard let queue = device.makeCommandQueue(),
              let buffer = device.makeBuffer(length: tileBytes * origins.count, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else { return nil }
        for (index, origin) in origins.enumerated() {
            blit.copy(
                from: pyramid, sourceSlice: 0, sourceLevel: level,
                sourceOrigin: MTLOrigin(x: origin.x, y: origin.y, z: 0), sourceSize: MTLSize(
                    width: n,
                    height: n,
                    depth: 1,
                ),
                to: buffer, destinationOffset: index * tileBytes, destinationBytesPerRow: n * 8,
                destinationBytesPerImage: tileBytes,
            )
        }
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.error == nil else { return nil }
        let halves = buffer.contents().assumingMemoryBound(to: Float16.self)
        var tiles: [(SIMD2<Int>, [SIMD3<Float>])] = []
        for (index, origin) in origins.enumerated() {
            let base = index * n * n * 4
            var pixels = [SIMD3<Float>](repeating: .zero, count: n * n)
            for i in 0 ..< n * n {
                let r = Float(halves[base + i * 4]), g = Float(halves[base + i * 4 + 1]),
                    b = Float(halves[base + i * 4 + 2])
                pixels[i] = SIMD3(r, g, b)
            }
            tiles.append((origin, pixels))
        }
        return tiles
    }
}
