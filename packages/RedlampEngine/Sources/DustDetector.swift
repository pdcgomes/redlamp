import Accelerate
import Foundation
import simd

/// Finds sensor dust (RM-02): the soft, dark, colourless specks dust on the sensor shadows a photo
/// with, a few pixels to a few dozen across, where the photo is smooth enough to show them (sky,
/// walls, water).
///
/// Blobs are found as differences of Gaussians on log luminance, at three scales: a speck is
/// darker than a wider blur of itself. Each must stand out from its neighbourhood by several times
/// the neighbourhood's own spread (a median absolute deviation on rings around it, so texture
/// raises the bar where there is texture), be about round (the Hessian test Lowe uses for SIFT),
/// and darken every channel alike, since dust has no colour of its own.
enum DustDetector {
    /// One level of the pyramid, in sensor coordinates: camera RGB per texel.
    struct Image {
        let width: Int
        let height: Int
        let pixels: [SIMD3<Float>]
    }

    struct Speck: Equatable {
        /// In the image's texels.
        var center: SIMD2<Float>
        var radius: Float
        /// How far it stands out, in multiples of its neighbourhood's spread.
        var strength: Float
        /// The photo around it: log luminance on three rings, 12, 24 and 48 texels out, sixteen
        /// points each, less the plane through them, in multiples of the noise. Frames that match
        /// here show the same scene (a tripod, a burst), so a speck repeating in them proves
        /// nothing about the sensor.
        var surroundings: [Float] = []
    }

    /// The blurs paired for each scale's difference of Gaussians. Dust's shadow is out of focus, so
    /// it's never smaller than a few pixels of the level searched (about 6 at full size).
    static let scales: [Float] = [2, 4, 8]
    static let ratio: Float = 1.6
    static let maximumSpecks = 300

    /// `sensitivity` 0...100: how many spreads a speck must stand out by, from 16 down to 4.
    static func detect(_ image: Image, luma: SIMD3<Float>, sensitivity: Double) -> [Speck] {
        let (width, height) = (image.width, image.height)
        guard width >= 32, height >= 32 else { return [] }
        let floor: Float = 1e-4
        let logLuma = image.pixels.map { log(max(simd_dot($0, luma), floor)) }
        let threshold = Float(16 - 0.12 * min(max(sensitivity, 0), 100))
        let noise = noiseLevel(logLuma, width: width, height: height)
        var candidates: [Speck] = []
        var scratch: [Float] = []
        for sigma in scales {
            let narrow = blur(logLuma, width: width, height: height, sigma: sigma)
            let wide = blur(logLuma, width: width, height: height, sigma: sigma * ratio)
            // Positive where a spot is darker than its surroundings.
            let response = zip(wide, narrow).map { $0 - $1 }
            // What noise alone spreads this scale's response by: dust shows only where the photo
            // is that smooth (sky, walls, water), not on stone, foliage or fabric.
            let smooth = 3 * noise * responseGain(sigma: sigma)
            let margin = Int(ceil(sigma * 3))
            guard width > 2 * margin + 2, height > 2 * margin + 2 else { continue }
            for y in margin ..< height - margin {
                for x in margin ..< width - margin {
                    let value = response[y * width + x]
                    guard value > 0.004, isPeak(response, x: x, y: y, width: width) else { continue }
                    guard let found = ringSpread(
                        response, width: width, height: height, x: x, y: y, sigma: sigma, scratch: &scratch,
                    )
                    else { continue }
                    let spread = max(found, 1e-4)
                    guard value > threshold * spread, spread < smooth else { continue }
                    guard isRound(narrow, x: x, y: y, width: width) else { continue }
                    let center = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                    guard isSpeck(
                        image,
                        logLuma: logLuma,
                        center: center,
                        radius: sigma * 1.5,
                        luma: luma,
                        noise: noise,
                    )
                    else { continue }
                    guard let radius = softExtent(logLuma, width: width, height: height, center: center, sigma: sigma),
                          !hasLookalikes(response, narrow, width: width, height: height, x: x, y: y, sigma: sigma)
                    else { continue }
                    candidates.append(Speck(center: center, radius: radius, strength: value / spread))
                }
            }
        }
        // The strongest speck in a place speaks for it: a blob fires at neighbouring scales too.
        var specks: [Speck] = []
        for candidate in candidates.sorted(by: { $0.strength > $1.strength }) {
            let clear = specks.allSatisfy { kept in
                simd_distance(kept.center, candidate.center) > max(kept.radius, candidate.radius) * 1.2
            }
            if clear {
                specks.append(candidate)
            }
        }
        // Dust is sparse: a patch full of specks is the scene's texture (pitted stone, gravel).
        let crowded = specks.map { speck in
            specks.filter { simd_distance($0.center, speck.center) < crowding }.count > 3
        }
        return zip(specks, crowded).filter { !$0.1 }.prefix(maximumSpecks).map { speck, _ in
            var speck = speck
            speck.surroundings = surroundings(
                logLuma, width: width, height: height, center: speck.center, noise: max(noise, 1e-4),
            )
            return speck
        }
    }

    /// `Speck.surroundings` for a speck at `center`.
    static func surroundings(
        _ logLuma: [Float], width: Int, height: Int, center: SIMD2<Float>, noise: Float,
    ) -> [Float] {
        var points: [SIMD3<Float>] = []
        for radius: Float in [12, 24, 48] {
            for step in 0 ..< 16 {
                let angle = Float(step) * .pi / 8
                let offset = SIMD2(radius * cos(angle), radius * sin(angle))
                let x = min(max(Int(center.x + offset.x), 0), width - 1)
                let y = min(max(Int(center.y + offset.y), 0), height - 1)
                points.append(SIMD3(offset.x, offset.y, logLuma[y * width + x]))
            }
        }
        return planeResiduals(points).map { $0 / noise }
    }

    /// Specks with more than three others this near (in texels) are texture.
    static let crowding: Float = 60

    /// The standard deviation of a scale's response to unit white noise: the difference of the
    /// two separable Gaussians' kernels, h = gw ⊗ gw - gn ⊗ gn, has Σh² = (Σgw²)² + (Σgn²)² - 2(Σgw·gn)².
    static func responseGain(sigma: Float) -> Float {
        func kernel(_ sigma: Float, reach: Int) -> [Float] {
            let taps = (-reach ... reach).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
            let total = taps.reduce(0, +)
            return taps.map { $0 / total }
        }
        let reach = Int(ceil(sigma * ratio * 3))
        let narrow = kernel(sigma, reach: reach), wide = kernel(sigma * ratio, reach: reach)
        let ww = wide.map { $0 * $0 }.reduce(0, +), nn = narrow.map { $0 * $0 }.reduce(0, +)
        let wn = zip(wide, narrow).map { $0 * $1 }.reduce(0, +)
        return max(ww * ww + nn * nn - 2 * wn * wn, 0).squareRoot()
    }

    /// A separable Gaussian blur, edges extended.
    static func blur(_ values: [Float], width: Int, height: Int, sigma: Float) -> [Float] {
        let reach = max(Int(ceil(sigma * 3)), 1)
        var kernel = (-reach ... reach).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var output = [Float](repeating: 0, count: values.count)
        var source = values
        source.withUnsafeMutableBufferPointer { input in
            output.withUnsafeMutableBufferPointer { result in
                var from = vImage_Buffer(
                    data: input.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                    rowBytes: width * MemoryLayout<Float>.stride,
                )
                var to = vImage_Buffer(
                    data: result.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                    rowBytes: width * MemoryLayout<Float>.stride,
                )
                _ = kernel.withUnsafeBufferPointer { taps in
                    vImageSepConvolve_PlanarF(
                        &from, &to, nil, 0, 0, taps.baseAddress, UInt32(taps.count), taps.baseAddress,
                        UInt32(taps.count), 0, 0, vImage_Flags(kvImageEdgeExtend),
                    )
                }
            }
        }
        return output
    }

    /// The neighbourhood's spread of a scale's response around (x, y): the median absolute
    /// deviation, scaled to a standard deviation, on rings beyond the reach of the spot's own
    /// response (about six times the scale), so a big speck doesn't raise its own bar. Nil where
    /// too little of the rings is inside the image.
    private static func ringSpread(
        _ response: [Float], width: Int, height: Int, x: Int, y: Int, sigma: Float, scratch: inout [Float],
    ) -> Float? {
        scratch.removeAll(keepingCapacity: true)
        let inner = max(sigma * 6, 12)
        for ring in 0 ..< 3 {
            let radius = inner + Float(ring) * max(sigma * 2, 6)
            let count = 64
            for step in 0 ..< count {
                let angle = (Float(step) + Float(ring) / 3) * 2 * .pi / Float(count)
                let px = Int((Float(x) + 0.5 + radius * cos(angle)).rounded(.down))
                let py = Int((Float(y) + 0.5 + radius * sin(angle)).rounded(.down))
                guard px >= 0, py >= 0, px < width, py < height else { continue }
                scratch.append(response[py * width + px])
            }
        }
        guard scratch.count >= 96 else { return nil }
        scratch.sort()
        let median = scratch[scratch.count / 2]
        for index in scratch.indices {
            scratch[index] = abs(scratch[index] - median)
        }
        scratch.sort()
        return 1.4826 * scratch[scratch.count / 2]
    }

    /// Whether two or more spots like this one lie near it, round, standing out about as much
    /// (half its response to twice it) and as dark: dust is sparse, and spots repeating nearby
    /// are the scene's (the knots of a fabric, marks in wood). Gaps between bright things (sky
    /// between clouds) stand out from them but are no darker than the sky around the speck.
    private static func hasLookalikes(
        _ response: [Float], _ narrow: [Float], width: Int, height: Int, x: Int, y: Int, sigma: Float,
    ) -> Bool {
        let value = response[y * width + x]
        let level = narrow[y * width + x]
        let reach = Int(max(sigma * 10, 40))
        let apart = sigma * 2
        var found = 0
        for ny in max(y - reach, 1) ..< min(y + reach + 1, height - 1) {
            for nx in max(x - reach, 1) ..< min(x + reach + 1, width - 1) {
                let other = response[ny * width + nx]
                guard other >= 0.5 * value, other <= 2 * value, narrow[ny * width + nx] <= level + 0.5 * value
                else { continue }
                let dx = Float(nx - x), dy = Float(ny - y)
                guard dx * dx + dy * dy > apart * apart, isPeak(response, x: nx, y: ny, width: width),
                      isRound(narrow, x: nx, y: ny, width: width)
                else { continue }
                found += 1
                if found >= 2 {
                    return true
                }
            }
        }
        return false
    }

    private static func isPeak(_ values: [Float], x: Int, y: Int, width: Int) -> Bool {
        let value = values[y * width + x]
        for dy in -1 ... 1 {
            for dx in -1 ... 1 where dx != 0 || dy != 0 {
                let other = values[(y + dy) * width + x + dx]
                // Ties go to the first in scan order.
                if other > value || (other == value && (dy < 0 || (dy == 0 && dx < 0))) {
                    return false
                }
            }
        }
        return true
    }

    /// Lowe's edge test on the blurred luminance's Hessian: a line or an edge curves one way only.
    private static func isRound(_ values: [Float], x: Int, y: Int, width: Int) -> Bool {
        func at(_ dx: Int, _ dy: Int) -> Float {
            values[(y + dy) * width + x + dx]
        }
        let dxx = at(1, 0) + at(-1, 0) - 2 * at(0, 0)
        let dyy = at(0, 1) + at(0, -1) - 2 * at(0, 0)
        let dxy = (at(1, 1) - at(1, -1) - at(-1, 1) + at(-1, -1)) / 4
        let trace = dxx + dyy, determinant = dxx * dyy - dxy * dxy
        let r: Float = 3
        return determinant > 0 && trace * trace / determinant < (r + 1) * (r + 1) / r
    }

    /// Whether the spot is dust: darker inside `radius` than the ring around it, in every channel
    /// alike, with the ring smooth but for the image's noise (an edge or texture there means the
    /// "speck" is part of the scene).
    private static func isSpeck(
        _ image: Image, logLuma: [Float], center: SIMD2<Float>, radius: Float, luma: SIMD3<Float>, noise: Float,
    ) -> Bool {
        var inside = SIMD3<Float>.zero, ring = SIMD3<Float>.zero
        var insideCount: Float = 0, ringCount: Float = 0
        var ringPoints: [SIMD3<Float>] = []
        let reach = Int(ceil(radius * 3))
        let cx = Int(center.x), cy = Int(center.y)
        for y in max(cy - reach, 0) ... min(cy + reach, image.height - 1) {
            for x in max(cx - reach, 0) ... min(cx + reach, image.width - 1) {
                let d = simd_distance(SIMD2(Float(x) + 0.5, Float(y) + 0.5), center)
                let index = y * image.width + x
                if d <= radius {
                    inside += image.pixels[index]
                    insideCount += 1
                } else if d >= radius * 2, d <= radius * 3 {
                    ring += image.pixels[index]
                    ringCount += 1
                    ringPoints.append(SIMD3(Float(x) - center.x, Float(y) - center.y, logLuma[index]))
                }
            }
        }
        guard insideCount > 0, ringCount > 8 else { return false }
        let floor = SIMD3<Float>(repeating: 1e-4)
        let a = simd_max(inside / insideCount, floor), b = simd_max(ring / ringCount, floor)
        let contrast = SIMD3(log(a.x / b.x), log(a.y / b.y), log(a.z / b.z))
        let overall = log(max(simd_dot(a, luma), 1e-4) / max(simd_dot(b, luma), 1e-4))
        guard overall < 0 else { return false }
        let texture = max(planeResidual(ringPoints) - noise * noise, 0).squareRoot()
        // Anything dark crossing the ring (the twig a dark tip belongs to) isn't dust's halo.
        let ringLevel = ringPoints.map(\.z).reduce(0, +) / Float(ringPoints.count)
        let dark = ringPoints.filter { $0.z < ringLevel - max(0.5 * abs(overall), 4 * noise) }.count
        return texture < 0.2 * abs(overall) && texture < 2 * noise
            && Float(dark) <= (0.004 * Float(ringPoints.count)).rounded(.down)
            && contrast.max() - contrast.min() < 0.5 * abs(overall) + 0.01
    }

    /// How far the speck reaches, or nil when it's too sharp to be dust: a shadow out of focus
    /// fades gradually, so its half depth lies well inside its tenth (at 0.55 of it for a Gaussian),
    /// where a pit or a stone in the scene stops abruptly (nearer 0.9). Depths are measured against
    /// the photo well outside the speck. The radius returned is 1.9 times the half depth's (a
    /// Gaussian's half depth is at 1.18 of its width, and it fades out by about 2.2).
    private static func softExtent(
        _ values: [Float], width: Int, height: Int, center: SIMD2<Float>, sigma: Float,
    ) -> Float? {
        func ringMean(_ radius: Float) -> Float {
            var sum: Float = 0, count: Float = 0
            for step in 0 ..< 24 {
                let angle = Float(step) * .pi / 12
                let x = Int(center.x + radius * cos(angle)), y = Int(center.y + radius * sin(angle))
                guard x >= 0, y >= 0, x < width, y < height else { continue }
                sum += values[y * width + x]
                count += 1
            }
            return count > 0 ? sum / count : .nan
        }
        let cx = min(max(Int(center.x), 0), width - 1), cy = min(max(Int(center.y), 0), height - 1)
        let depth = values[cy * width + cx]
        let background = ringMean(sigma * 7)
        guard depth.isFinite, background.isFinite, background > depth else { return nil }
        var half: Float?
        var tenth: Float?
        var radius: Float = 0.5
        while radius < sigma * 6, tenth == nil {
            let mean = ringMean(radius)
            if mean.isFinite {
                let remaining = (background - mean) / (background - depth)
                if half == nil, remaining < 0.5 {
                    half = radius
                }
                if remaining < 0.1 {
                    tenth = radius
                }
            }
            radius += 0.5
        }
        guard let half, let tenth, half < 0.8 * tenth, half * 1.9 >= 3 else { return nil }
        return half * 1.9
    }

    /// The variance left in `points` (x, y, value) once the plane through them is taken away: a
    /// gradient across a sky is not texture.
    private static func planeResidual(_ points: [SIMD3<Float>]) -> Float {
        guard points.count >= 3 else { return 0 }
        return planeResiduals(points).map { $0 * $0 }.reduce(0, +) / Float(points.count)
    }

    /// What's left of each point's value once the least-squares plane through `points` is taken
    /// away.
    private static func planeResiduals(_ points: [SIMD3<Float>]) -> [Float] {
        let n = Float(points.count)
        guard n >= 3 else { return points.map { _ in 0 } }
        let mean = points.reduce(SIMD3<Float>.zero, +) / n
        var sxx: Float = 0, syy: Float = 0, sxy: Float = 0, sxz: Float = 0, syz: Float = 0
        for point in points {
            let d = point - mean
            sxx += d.x * d.x
            syy += d.y * d.y
            sxy += d.x * d.y
            sxz += d.x * d.z
            syz += d.y * d.z
        }
        let determinant = sxx * syy - sxy * sxy
        let (gx, gy) = abs(determinant) > 1e-6
            ? ((sxz * syy - syz * sxy) / determinant, (syz * sxx - sxz * sxy) / determinant) : (0, 0)
        return points.map { point in
            let d = point - mean
            return d.z - gx * d.x - gy * d.y
        }
    }

    /// The photo's noise in log luminance: neighbours' differences, by their median absolute
    /// deviation, which the smooth parts of any photo dominate.
    private static func noiseLevel(_ values: [Float], width: Int, height: Int) -> Float {
        var differences: [Float] = []
        differences.reserveCapacity(width * height / 9)
        for y in stride(from: 0, to: height, by: 3) {
            for x in stride(from: 0, to: width - 1, by: 3) {
                differences.append(abs(values[y * width + x + 1] - values[y * width + x]))
            }
        }
        guard !differences.isEmpty else { return 0 }
        differences.sort()
        return 1.4826 * differences[differences.count / 2] / Float(2).squareRoot()
    }
}
