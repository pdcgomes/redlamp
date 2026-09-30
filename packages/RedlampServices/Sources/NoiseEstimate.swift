import Foundation

/// Signal-dependent sensor noise (the Poisson–Gaussian model): per channel,
/// variance = a · value + b, with values in normalised sensor units (black = 0, white = 1).
public struct NoiseModel: Sendable, Hashable {
    public var a: SIMD3<Float>
    public var b: SIMD3<Float>

    public init(a: SIMD3<Float>, b: SIMD3<Float>) {
        self.a = a
        self.b = b
    }

    /// For images whose noise can't be measured (bitmaps): about 8-bit quantisation noise.
    public static let quantization = NoiseModel(a: .zero, b: SIMD3(repeating: 1e-6))

    /// The same noise after each channel is multiplied by `gains` (white balance).
    public func scaled(by gains: SIMD3<Float>) -> NoiseModel {
        NoiseModel(a: a * gains, b: b * gains * gains)
    }
}

/// Estimates sensor noise from the image itself, with no calibration shots.
///
/// For each color, the variance of differences between nearby same-color samples is measured in
/// many small tiles. Scene texture only ever adds variance, so at each brightness the flattest
/// tiles are kept (a low percentile, corrected for its sampling bias), and a weighted line through
/// those points gives `a` and `b`.
///
/// Scenes with texture everywhere, and lossy-compressed raws (whose errors grow with local
/// contrast), still read noisier than the sensor is.
public enum NoiseEstimator {
    public static func estimate(_ image: DecodedImage) -> NoiseModel? {
        let layout: Layout
        switch image.layout {
        case let .mosaic(pattern): layout = mosaicLayout(pattern, blackLevels: image.blackLevels)
        case .linearRGB: layout = rgbLayout(blackLevels: image.blackLevels)
        case .linearSRGBHalf: return nil
        }
        let points = measure(image, layout: layout)
        var a = SIMD3<Float>.zero
        var b = SIMD3<Float>.zero
        var fitted = [Bool](repeating: false, count: 3)
        for channel in 0 ..< 3 {
            guard let line = fit(points[channel]) else { continue }
            a[channel] = line.a
            b[channel] = line.b
            fitted[channel] = true
        }
        // A channel without enough flat tiles borrows the others' average.
        let good = (0 ..< 3).filter { fitted[$0] }
        guard !good.isEmpty else { return nil }
        let meanA = good.map { a[$0] }.reduce(0, +) / Float(good.count)
        let meanB = good.map { b[$0] }.reduce(0, +) / Float(good.count)
        for channel in 0 ..< 3 where !fitted[channel] {
            a[channel] = meanA
            b[channel] = meanB
        }
        return NoiseModel(a: a, b: b)
    }

    // MARK: - Sampling

    /// Where each sample's partner is and how to normalise both, per position in the pattern.
    private struct Layout {
        var patternWidth: Int
        var patternHeight: Int
        /// Samples per pixel (1 for a mosaic, 3 for linear RGB).
        var channels: Int
        /// Per pattern position and channel: color, partner offset, black level.
        var colors: [Int]
        var offsets: [(dx: Int, dy: Int)]
        var blacks: [Float]
    }

    private static func mosaicLayout(_ pattern: CFAPattern, blackLevels: [Float]) -> Layout {
        // Forward offsets within one pattern period, nearest first.
        var candidates: [(dx: Int, dy: Int)] = []
        for dy in 0 ... pattern.height {
            for dx in -pattern.width ... pattern.width where dy > 0 || dx > 0 {
                candidates.append((dx, dy))
            }
        }
        candidates.sort { $0.dx * $0.dx + $0.dy * $0.dy < $1.dx * $1.dx + $1.dy * $1.dy }
        var offsets: [(dx: Int, dy: Int)] = []
        for y in 0 ..< pattern.height {
            for x in 0 ..< pattern.width {
                let color = pattern.color(x: x, y: y)
                let match = candidates.first {
                    pattern.color(x: x + $0.dx + pattern.width, y: y + $0.dy) == color
                }
                offsets.append(match ?? (0, 0))
            }
        }
        let count = pattern.width * pattern.height
        let blacks = (0 ..< count).map { blackLevels.isEmpty ? 0 : blackLevels[$0 % blackLevels.count] }
        return Layout(
            patternWidth: pattern.width, patternHeight: pattern.height, channels: 1,
            colors: pattern.colors.map(Int.init), offsets: offsets, blacks: blacks,
        )
    }

    private static func rgbLayout(blackLevels: [Float]) -> Layout {
        Layout(
            patternWidth: 1, patternHeight: 1, channels: 3,
            colors: [0, 1, 2], offsets: [(1, 0), (1, 0), (1, 0)],
            blacks: (0 ..< 3).map { blackLevels.isEmpty ? 0 : blackLevels[$0 % blackLevels.count] },
        )
    }

    private struct TilePoint {
        var mean: Float
        var variance: Float
        var count: Int
    }

    private static let tileSize = 16
    private static let maxTiles = 16384

    /// One point per sampled tile and color: mean level and noise variance estimate.
    private static func measure(_ image: DecodedImage, layout: Layout) -> [[TilePoint]] {
        let width = image.width
        let height = image.height
        let tilesX = width / tileSize
        let tilesY = height / tileSize
        guard tilesX > 1, tilesY > 1 else { return [[], [], []] }
        let stride = max(1, Int((Double(tilesX * tilesY) / Double(maxTiles)).squareRoot().rounded(.up)))
        let white = image.whiteLevel
        var points: [[TilePoint]] = [[], [], []]
        image.samples.withUnsafeBufferPointer { samples in
            for tileY in Swift.stride(from: 0, to: tilesY, by: stride) {
                for tileX in Swift.stride(from: 0, to: tilesX, by: stride) {
                    var sums = SIMD3<Double>.zero
                    var squares = SIMD3<Double>.zero
                    var counts = SIMD3<Int>.zero
                    let startX = tileX * tileSize
                    let endX = startX + tileSize
                    let endY = (tileY + 1) * tileSize
                    for y in tileY * tileSize ..< endY {
                        for x in startX ..< endX {
                            let position = (y % layout.patternHeight) * layout.patternWidth + x % layout.patternWidth
                            for channel in 0 ..< layout.channels {
                                let entry = position * layout.channels + channel
                                let offset = layout.offsets[entry]
                                guard offset != (0, 0) else { continue }
                                let x2 = x + offset.dx
                                let y2 = y + offset.dy
                                // Both samples stay in the tile, so its variance sees one surface.
                                guard x2 >= startX, x2 < endX, y2 < endY else { continue }
                                let position2 = (y2 % layout.patternHeight) * layout.patternWidth
                                    + x2 % layout.patternWidth
                                let black1 = layout.blacks[entry]
                                let black2 = layout.blacks[position2 * layout.channels + channel]
                                let raw1 = Float(samples[(y * width + x) * layout.channels + channel])
                                let raw2 = Float(samples[(y2 * width + x2) * layout.channels + channel])
                                let v1 = (raw1 - black1) / max(white - black1, 1)
                                let v2 = (raw2 - black2) / max(white - black2, 1)
                                // Near clipping, the noise is cut off and would read too low.
                                guard v1 < 0.9, v2 < 0.9 else { continue }
                                let color = layout.colors[entry]
                                sums[color] += Double(v1 + v2) / 2
                                squares[color] += Double((v1 - v2) * (v1 - v2))
                                counts[color] += 1
                            }
                        }
                    }
                    for color in 0 ..< 3 where counts[color] >= 16 {
                        let n = Double(counts[color])
                        points[color].append(TilePoint(
                            mean: Float(sums[color] / n),
                            variance: Float(squares[color] / n / 2),
                            count: counts[color],
                        ))
                    }
                }
            }
        }
        return points
    }

    // MARK: - Fitting

    private static let binCount = 45
    private static let binWidth: Float = 0.02
    private static let minimumTilesPerBin = 12

    /// The flattest tiles per brightness bin, then a weighted least-squares line.
    private static func fit(_ points: [TilePoint]) -> (a: Float, b: Float)? {
        var bins = [[TilePoint]](repeating: [], count: binCount)
        for point in points where point.mean >= 0 {
            let index = min(Int(point.mean / binWidth), binCount - 1)
            bins[index].append(point)
        }
        let used = bins.filter { $0.count >= minimumTilesPerBin }
        guard used.count >= 2 else { return nil }
        // Noise changes a lot across a dark bin, so tiles are ranked by their variance relative
        // to the current line (flat at first), which is then refitted.
        var line = (a: 0.0, b: 1.0)
        for _ in 0 ..< 4 {
            let current = line
            let levels = used.map { bin in
                level(bin) { max(current.a * $0 + current.b, 1e-12) }
            }
            // Each level's error is proportional to its variance: weight by tiles / variance².
            line = solve(levels) { $0.tiles / max($0.variance * $0.variance, 1e-24) }
        }
        return (Float(line.a), Float(max(line.b, 1e-9)))
    }

    /// Which of a bin's tiles, ranked by variance, stands for the noise. Texture only adds
    /// variance, so a low percentile; lower resists busy scenes better but scatters more.
    private static let percentile = 0.05
    /// z-score of `percentile` in a standard normal.
    private static let percentileZ = -1.6449

    /// A low percentile of a bin's tiles relative to `expected`, as a variance at the bin's mean.
    private static func level(_ bin: [TilePoint], expected: (Double) -> Double) -> Level {
        let ratios = bin.map { (ratio: Double($0.variance) / expected(Double($0.mean)), count: $0.count) }
            .sorted { $0.ratio < $1.ratio }
        let pick = ratios[Int(Double(ratios.count) * percentile)]
        // Pure noise measured from n differences is a χ²ₙ/n variable; the same percentile of that
        // (Wilson–Hilferty) is how far below the truth the pick sits.
        let n = Double(pick.count)
        let spread = (2 / (9 * n)).squareRoot()
        let bias = max(pow(1 - 2 / (9 * n) + percentileZ * spread, 3), 0.2)
        let mean = bin.map { Double($0.mean) }.reduce(0, +) / Double(bin.count)
        return Level(mean: mean, variance: pick.ratio / bias * expected(mean), tiles: Double(bin.count))
    }

    private struct Level {
        var mean: Double
        var variance: Double
        var tiles: Double
    }

    /// Weighted least squares for variance = a · mean + b, with a and b kept non-negative.
    private static func solve(_ levels: [Level], weight: (Level) -> Double) -> (a: Double, b: Double) {
        var sw = 0.0, sm = 0.0, smm = 0.0, sv = 0.0, smv = 0.0
        for level in levels {
            let w = weight(level)
            sw += w
            sm += w * level.mean
            smm += w * level.mean * level.mean
            sv += w * level.variance
            smv += w * level.mean * level.variance
        }
        let determinant = sw * smm - sm * sm
        if determinant > 1e-300 {
            let a = (sw * smv - sm * sv) / determinant
            let b = (smm * sv - sm * smv) / determinant
            if a >= 0, b >= 0 {
                return (a, b)
            }
        }
        let throughOrigin = (smv / max(smm, 1e-300), 0.0)
        let constant = (0.0, sv / sw)
        func residual(_ line: (Double, Double)) -> Double {
            levels.reduce(0) { total, level in
                let error = level.variance - (line.0 * level.mean + line.1)
                return total + weight(level) * error * error
            }
        }
        return residual(throughOrigin) <= residual(constant) ? throughOrigin : constant
    }
}
