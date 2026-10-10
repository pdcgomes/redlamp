import Foundation
import RedlampEngineAPI

/// How to rebuild sensor-clipped photosites, fitted per image.
///
/// A clipped channel is estimated from the unclipped channels around it: in cube-root space, their
/// mean plus a colour offset measured on the unclipped pixels bordering clipped areas, whose
/// colour is the best guess for what clipped. This is the constant-chromaticity case of
/// estimating saturated values from the correlation between channels (Zhang & Brainard,
/// "Estimation of saturated pixel values in digital color imaging", JOSA A 2004); unlike a full
/// regression it cannot extrapolate wildly. Values are white-balanced, as the mosaic is before
/// demosaicing.
public struct HighlightModel: Sendable, Hashable {
    /// Clip level per colour (xyz), and (w) the lowest neutral consistent with every channel
    /// being at least at its clip level: the value for fully clipped areas.
    public var clip: SIMD4<Float>
    /// For clipped colour c and observed set s (0: both other colours, 1: only (c + 1) % 3,
    /// 2: only (c + 2) % 3), at index c * 3 + s: x intercept, yzw weights on the cube roots of
    /// the R, G and B neighbourhood means.
    public var coefficients: [SIMD4<Float>]
    /// The raw revision it was fitted for, which also says how the kernels rebuild.
    public var revision: RawRevision

    /// Photosites at or above this fraction of the white level count as clipped.
    public static let clipFraction: Float = 0.99

    /// Nil when nothing in the image clipped, or it isn't a mosaic.
    public static func fit(_ image: DecodedImage, balance: SIMD3<Float>, revision: RawRevision) -> HighlightModel? {
        guard case let .mosaic(pattern) = image.layout else { return nil }
        let block = pattern.width % 3 == 0 ? 3 : 2
        let grid = BlockGrid(image: image, pattern: pattern, balance: balance, block: block)
        let clipped = grid.clippedBlocks()
        guard clipped.contains(true) else { return nil }
        let rim = grid.dilate(clipped, radius: 2)
        let clip = SIMD3<Float>(repeating: clipFraction) * balance
        // Bright rim pixels only: darker ones (a twig against the sky) aren't what clipped.
        let bright = SIMD3<Double>(clip) * 0.5
        var reference: [SIMD3<Double>] = []
        for index in clipped.indices where rim[index] && !clipped[index] {
            if let means = grid.means(ofBlock: index), all(means .>= bright) {
                reference.append(SIMD3(means.x.cubeRoot, means.y.cubeRoot, means.z.cubeRoot))
            }
        }
        return HighlightModel(
            clip: SIMD4(clip, clip.max()),
            coefficients: coefficients(reference),
            revision: revision,
        )
    }

    /// Offsets from the reference colours. With too few, the offset is zero: the highlight is
    /// assumed neutral.
    static func coefficients(_ samples: [SIMD3<Double>]) -> [SIMD4<Float>] {
        var result: [SIMD4<Float>] = []
        for clipped in 0 ..< 3 {
            let first = (clipped + 1) % 3
            let second = (clipped + 2) % 3
            for observed in [[first, second], [first], [second]] {
                var offset = 0.0
                if samples.count >= 64 {
                    for sample in samples {
                        let reference = observed.map { sample[$0] }.reduce(0, +) / Double(observed.count)
                        offset += (sample[clipped] - reference) / Double(samples.count)
                    }
                }
                var entry = SIMD4<Float>(Float(offset), 0, 0, 0)
                for channel in observed {
                    entry[channel + 1] = 1 / Float(observed.count)
                }
                result.append(entry)
            }
        }
        return result
    }
}

/// The mosaic in blocks small enough to hold every colour (2 x 2 Bayer, 3 x 3 X-Trans).
private struct BlockGrid {
    let image: DecodedImage
    let pattern: CFAPattern
    let balance: SIMD3<Float>
    let block: Int
    let columns: Int
    let rows: Int

    init(image: DecodedImage, pattern: CFAPattern, balance: SIMD3<Float>, block: Int) {
        self.image = image
        self.pattern = pattern
        self.balance = balance
        self.block = block
        columns = image.width / block
        rows = image.height / block
    }

    private func black(x: Int, y: Int) -> Float {
        let blacks = image.blackLevels
        guard !blacks.isEmpty else { return 0 }
        return blacks[((y % pattern.height) * pattern.width + x % pattern.width) % blacks.count]
    }

    /// Whether any photosite in each block reached the clip level.
    func clippedBlocks() -> [Bool] {
        var clipped = [Bool](repeating: false, count: columns * rows)
        let white = image.whiteLevel
        let fraction = HighlightModel.clipFraction
        image.samples.withUnsafeBufferPointer { samples in
            for y in 0 ..< rows * block {
                let rowStart = (y / block) * columns
                for x in 0 ..< columns * block {
                    let black = black(x: x, y: y)
                    if Float(samples[y * image.width + x]) >= black + fraction * (white - black) {
                        clipped[rowStart + x / block] = true
                    }
                }
            }
        }
        return clipped
    }

    /// Blocks within `radius` blocks of a set one.
    func dilate(_ mask: [Bool], radius: Int) -> [Bool] {
        var horizontal = mask
        for row in 0 ..< rows {
            for column in 0 ..< columns where mask[row * columns + column] {
                for dx in max(0, column - radius) ... min(columns - 1, column + radius) {
                    horizontal[row * columns + dx] = true
                }
            }
        }
        var result = horizontal
        for row in 0 ..< rows {
            for column in 0 ..< columns where horizontal[row * columns + column] {
                for dy in max(0, row - radius) ... min(rows - 1, row + radius) {
                    result[dy * columns + column] = true
                }
            }
        }
        return result
    }

    /// White-balanced mean of each colour in a block.
    func means(ofBlock index: Int) -> SIMD3<Double>? {
        let x0 = (index % columns) * block
        let y0 = (index / columns) * block
        var sums = SIMD3<Double>.zero
        var counts = SIMD3<Double>.zero
        let white = image.whiteLevel
        for y in y0 ..< y0 + block {
            for x in x0 ..< x0 + block {
                let color = Int(pattern.color(x: x, y: y))
                let black = black(x: x, y: y)
                let value = (Float(image.samples[y * image.width + x]) - black) / max(white - black, 1)
                sums[color] += Double(max(value, 0) * balance[color])
                counts[color] += 1
            }
        }
        guard counts.min() > 0 else { return nil }
        return sums / counts
    }
}

private extension Double {
    var cubeRoot: Double {
        Foundation.cbrt(self)
    }
}
