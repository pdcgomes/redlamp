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
    /// From the second revision, where areas clipped in every colour fade to neutral; nil when
    /// none did.
    public var fade: HighlightFade?

    /// Photosites at or above this fraction of the white level count as clipped.
    public static let clipFraction: Float = 0.99

    /// Nil when nothing in the image clipped, or it isn't a mosaic.
    public static func fit(_ image: DecodedImage, balance: SIMD3<Float>, revision: RawRevision) -> HighlightModel? {
        guard case let .mosaic(pattern) = image.layout else { return nil }
        let block = pattern.width % 3 == 0 ? 3 : 2
        let grid = BlockGrid(image: image, pattern: pattern, balance: balance, block: block)
        let colours = grid.clippedColours()
        let clipped = colours.map { $0 != 0 }
        guard clipped.contains(true) else { return nil }
        let rim = grid.dilate(clipped, radius: 2)
        let clip = SIMD3<Float>(repeating: clipFraction) * balance
        // Bright rim pixels only: darker ones (a twig against the sky) aren't what clipped. From the
        // second revision, bright against the lowest clip level: against each colour's own, red's
        // large multiplier in daylight puts a blue sky's own rim out of reach.
        let bright = revision >= .second
            ? SIMD3<Double>(repeating: Double(clip.min()) * 0.5) : SIMD3<Double>(clip) * 0.5
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
            fade: revision >= .second ? HighlightFade(grid: grid, colours: colours) : nil,
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

/// How far each part of the mosaic fades to neutral after the second revision's reconstruction:
/// over cells of `blocksPerCell` blocks a side, the share of a cell's blocks clipped in every
/// colour, blurred over `blurCells`, so an area clipped in every colour meets the colour around it
/// smoothly.
public struct HighlightFade: Sendable, Hashable {
    public var width: Int
    public var height: Int
    /// Photosites per side of a cell.
    public var cell: Int
    /// Per cell, row-major, from 0 to 1.
    public var weights: [Float]

    static let blocksPerCell = 4
    static let blurCells: Float = 2

    /// Nil when no block clipped in every colour.
    fileprivate init?(grid: BlockGrid, colours: [UInt8]) {
        guard colours.contains(BlockGrid.allColours) else { return nil }
        let factor = Self.blocksPerCell
        width = (grid.columns + factor - 1) / factor
        height = (grid.rows + factor - 1) / factor
        cell = grid.block * factor
        var shares = [Float](repeating: 0, count: width * height)
        var counts = [Float](repeating: 0, count: width * height)
        for row in 0 ..< grid.rows {
            let cellRow = (row / factor) * width
            for column in 0 ..< grid.columns {
                let index = cellRow + column / factor
                if colours[row * grid.columns + column] == BlockGrid.allColours {
                    shares[index] += 1
                }
                counts[index] += 1
            }
        }
        weights = Self.blurred(zip(shares, counts).map { $1 > 0 ? $0 / $1 : 0 }, width: width, height: height)
    }

    /// A separable Gaussian of `blurCells`, clamped at the edges.
    private static func blurred(_ values: [Float], width: Int, height: Int) -> [Float] {
        let radius = Int((3 * blurCells).rounded(.up))
        let taps = (-radius ... radius).map { exp(-Float($0 * $0) / (2 * blurCells * blurCells)) }
        let total = taps.reduce(0, +)
        var horizontal = [Float](repeating: 0, count: values.count)
        for y in 0 ..< height {
            for x in 0 ..< width {
                var sum: Float = 0
                for (k, tap) in taps.enumerated() {
                    sum += tap * values[y * width + min(max(x + k - radius, 0), width - 1)]
                }
                horizontal[y * width + x] = sum / total
            }
        }
        var result = [Float](repeating: 0, count: values.count)
        for y in 0 ..< height {
            for x in 0 ..< width {
                var sum: Float = 0
                for (k, tap) in taps.enumerated() {
                    sum += tap * horizontal[min(max(y + k - radius, 0), height - 1) * width + x]
                }
                result[y * width + x] = sum / total
            }
        }
        return result
    }
}

/// The mosaic in blocks small enough to hold every colour (2 x 2 Bayer, 3 x 3 X-Trans).
private struct BlockGrid {
    /// A block's clipped colours when every one of them clipped.
    static let allColours: UInt8 = 0b111

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

    /// Per block, a bit for each colour (1 red, 2 green, 4 blue) with a photosite at the clip level.
    func clippedColours() -> [UInt8] {
        var colours = [UInt8](repeating: 0, count: columns * rows)
        let white = image.whiteLevel
        let fraction = HighlightModel.clipFraction
        image.samples.withUnsafeBufferPointer { samples in
            for y in 0 ..< rows * block {
                let rowStart = (y / block) * columns
                for x in 0 ..< columns * block {
                    let black = black(x: x, y: y)
                    if Float(samples[y * image.width + x]) >= black + fraction * (white - black) {
                        colours[rowStart + x / block] |= 1 << pattern.color(x: x, y: y)
                    }
                }
            }
        }
        return colours
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
