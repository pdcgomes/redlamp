import Foundation

/// A camera's noise from calibration frames, by photon transfer (DN-01): pairs of frames shot
/// alike (the same ISO, shutter speed and light: a flat, out-of-focus surface, and bias frames
/// with the lens capped at the shortest shutter speed). The difference of a pair cancels what both
/// share, the scene, vignetting and fixed-pattern noise, so the variance of each tile's difference
/// is twice the noise at the tile's level. A line through those points, per colour and ISO, is
/// `NoiseModel`'s `a` and `b`.
public enum NoiseCalibration {
    /// One tile of one pair, for one colour: its level and noise variance, in normalised units.
    public struct Measurement: Sendable, Hashable {
        public var level: Float
        public var variance: Float
        public var count: Int
    }

    /// What pairing needs to know of a frame, without keeping its samples.
    public struct FrameSummary: Sendable, Hashable {
        public var iso: Double
        /// The frame's average level, normalised.
        public var level: Float

        public init(iso: Double, level: Float) {
            self.iso = iso
            self.level = level
        }

        public init?(_ image: DecodedImage) {
            guard let iso = image.info.iso, iso > 0, let level = NoiseCalibration.averageLevel(image) else {
                return nil
            }
            self.init(iso: iso, level: level)
        }
    }

    /// Tile edge in pixels.
    static let tileSize = 64
    /// Tiles with a sample above this are left out: clipping cuts their noise off.
    static let clipLevel: Float = 0.9

    /// Frames to difference: of the same ISO and within 3% of each other's level, each used once,
    /// in order of level. Indices into `frames`.
    public static func pairs(_ frames: [FrameSummary]) -> [(Int, Int)] {
        let order = frames.indices.sorted { (frames[$0].iso, frames[$0].level) < (frames[$1].iso, frames[$1].level) }
        var pairs: [(Int, Int)] = []
        var index = 0
        while index + 1 < order.count {
            let first = frames[order[index]], second = frames[order[index + 1]]
            let sameISO = abs(first.iso - second.iso) <= first.iso * 0.01
            let alike = abs(first.level - second.level) <= 0.03 * max(first.level, second.level) + 0.002
            if sameISO, alike {
                pairs.append((order[index], order[index + 1]))
                index += 2
            } else {
                index += 1
            }
        }
        return pairs
    }

    /// Each tile's level and noise for a pair, per colour (red, green, blue).
    public static func measure(_ first: DecodedImage, _ second: DecodedImage) -> [[Measurement]] {
        guard first.width == second.width, first.height == second.height,
              first.samples.count == second.samples.count
        else { return [[], [], []] }
        // Per position in the pattern and channel: its colour, black level and scale.
        let (patternWidth, patternHeight, channels, colors): (Int, Int, Int, [Int])
        switch first.layout {
        case let .mosaic(pattern):
            (patternWidth, patternHeight, channels) = (pattern.width, pattern.height, 1)
            colors = pattern.colors.map(Int.init)
        case .linearRGB:
            (patternWidth, patternHeight, channels, colors) = (1, 1, 3, [0, 1, 2])
        default:
            return [[], [], []]
        }
        let blacks = (0 ..< colors.count).map { entry in
            first.blackLevels.isEmpty ? Float(0) : first.blackLevels[entry % first.blackLevels.count]
        }
        let scales = blacks.map { 1 / max(first.whiteLevel - $0, 1) }
        let width = first.width
        var measurements: [[Measurement]] = [[], [], []]
        first.samples.withUnsafeBufferPointer { a in
            second.samples.withUnsafeBufferPointer { b in
                for tileY in 0 ..< first.height / tileSize {
                    for tileX in 0 ..< width / tileSize {
                        var levels = SIMD3<Double>.zero
                        var differences = SIMD3<Double>.zero
                        var squares = SIMD3<Double>.zero
                        var counts = SIMD3<Int>.zero
                        var clipped = false
                        for y in tileY * tileSize ..< (tileY + 1) * tileSize {
                            let row = (y % patternHeight) * patternWidth
                            for x in tileX * tileSize ..< (tileX + 1) * tileSize {
                                for channel in 0 ..< channels {
                                    let entry = (row + x % patternWidth) * channels + channel
                                    let index = (y * width + x) * channels + channel
                                    let v1 = (Float(a[index]) - blacks[entry]) * scales[entry]
                                    let v2 = (Float(b[index]) - blacks[entry]) * scales[entry]
                                    clipped = clipped || v1 > clipLevel || v2 > clipLevel
                                    let c = colors[entry]
                                    levels[c] += Double(v1 + v2) / 2
                                    differences[c] += Double(v1 - v2)
                                    squares[c] += Double((v1 - v2) * (v1 - v2))
                                    counts[c] += 1
                                }
                            }
                        }
                        guard !clipped else { continue }
                        for c in 0 ..< 3 where counts[c] >= 64 {
                            let n = Double(counts[c])
                            // The pair's mean difference is a change of light between them, not noise.
                            let mean = differences[c] / n
                            let variance = (squares[c] / n - mean * mean) * n / (n - 1) / 2
                            measurements[c].append(Measurement(
                                level: Float(levels[c] / n), variance: Float(variance), count: counts[c],
                            ))
                        }
                    }
                }
            }
        }
        return measurements
    }

    /// `a` and `b` through `measurements` (all levels of one colour and ISO): weighted least
    /// squares, each point by its count over its expected variance squared, refitted twice, and
    /// then without points more than five standard errors off. Nil without bright and dark enough
    /// points to tell the two apart.
    public static func fit(_ measurements: [Measurement]) -> (a: Float, b: Float)? {
        guard let low = measurements.map(\.level).min(), let high = measurements.map(\.level).max(),
              high - low > 0.05
        else { return nil }
        var points = measurements
        var line = solve(points) { _ in 1 }
        for pass in 0 ..< 4 {
            guard let current = line else { return nil }
            if pass == 3 {
                points = points.filter { point in
                    let expected = max(current.a * Double(point.level) + current.b, 1e-14)
                    let error = expected * (2 / Double(point.count)).squareRoot()
                    return abs(Double(point.variance) - expected) <= 5 * error
                }
            }
            line = solve(points) { point in
                let expected = max(current.a * Double(point.level) + current.b, 1e-14)
                return Double(point.count) / (expected * expected)
            }
        }
        guard let line, line.a > 0 else { return nil }
        return (Float(line.a), Float(max(line.b, 1e-12)))
    }

    /// The profile point at one ISO from all its pairs' measurements, or nil when a colour can't
    /// be fitted.
    public static func point(iso: Double, pairs: Int, measurements: [[Measurement]]) -> CameraNoiseProfile.Point? {
        var a = SIMD3<Float>.zero, b = SIMD3<Float>.zero
        for channel in 0 ..< 3 {
            guard let line = fit(measurements[channel]) else { return nil }
            a[channel] = line.a
            b[channel] = line.b
        }
        return CameraNoiseProfile.Point(
            iso: iso,
            a: a,
            b: b,
            pairs: pairs,
            tiles: measurements.map(\.count).reduce(0, +),
        )
    }

    // MARK: - Helpers

    static func averageLevel(_ image: DecodedImage) -> Float? {
        guard image.isRaw, !image.samples.isEmpty else { return nil }
        let black = image.blackLevels.isEmpty ? 0 : image.blackLevels.reduce(0, +) / Float(image.blackLevels.count)
        var sum: Double = 0
        var count = 0
        for index in stride(from: 0, to: image.samples.count, by: 97) {
            sum += Double(image.samples[index])
            count += 1
        }
        return (Float(sum / Double(count)) - black) / max(image.whiteLevel - black, 1)
    }

    /// Weighted least squares for variance = a · level + b.
    private static func solve(
        _ points: [Measurement], weight: (Measurement) -> Double,
    ) -> (a: Double, b: Double)? {
        var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for point in points {
            let w = weight(point), x = Double(point.level), y = Double(point.variance)
            sw += w
            sx += w * x
            sy += w * y
            sxx += w * x * x
            sxy += w * x * y
        }
        let determinant = sw * sxx - sx * sx
        guard points.count >= 2, abs(determinant) > 1e-30 else { return nil }
        let a = (sw * sxy - sx * sy) / determinant
        return (a, (sy - a * sx) / sw)
    }
}
