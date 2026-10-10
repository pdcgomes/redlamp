import CoreGraphics
import Foundation
import RedlampColor
import RedlampEngineAPI
import simd

/// Sky coverage per pixel from a coarse sky mask: every twig, leaf gap, wire and hair edge.
///
/// Sky is smooth, so the sky colour behind any pixel can be estimated from the sure sky around
/// it, and the foreground's from the sure foreground clear of the edge (within a pixel or two of
/// it, every pixel holds some sky). A pixel's coverage is then where its colour lies between the
/// two in linear light, where light mixes: blue-screen matting with a known, smoothly varying
/// backing (Smith and Blinn, 1996), the colours spread by pull-push (Gortler et al., 1996).
/// Solved: an uncertain band around the coarse edge; sky-coloured pixels further into
/// the foreground that connect to the sky (a crown the coarse mask cut out whole); and, inside
/// the coarse sky, pixels clearly not sky (twigs and wires the model never saw). Where the two
/// colours are too close to tell apart, the coarse mask stays.
///
/// Prototyped as `research/prototypes/masking/sky_matte.py`. On the edge benchmark
/// (`edge_bench.py`: thin structures over real skies, with known coverage, at 4096 px) it takes
/// the error around edges from 0.179 to 0.051 and on thin structures from 0.259 to 0.116 (MSK-17).
public enum SkyMatte {
    /// The band solved around the coarse edge, and how far into the foreground sky is sought,
    /// as fractions of the long side.
    static let band: Float = 0.012
    static let reach: Float = 0.06
    /// Sky and foreground colours closer than this (linear RGB distance) can't be told apart.
    static let tolerance: (low: Float, high: Float) = (0.015, 0.06)
    /// How far, in pixels, past sky taken back from the foreground its mixed edge reaches.
    static let edgeReach = 2
    /// How far off the line from the foreground's colour to the sky's (a share of the distance
    /// between them) walled-in sky may be.
    static let walledOffLine: Float = 0.12
    /// The coarse sky above which the models saw some: half a step of an 8-bit mask.
    static let walledPrior: Float = 0.5 / 255
    /// Pixels more sky than this hold some; the foreground's colour is learnt only from pixels
    /// more than `clearance` pixels from any of them.
    static let mixed: Float = 0.15
    static let clearance = 2
    /// A colour within `start` of either end of the line from the foreground's colour to the sky's
    /// is noise on a pure pixel; from `end` in, its place on the line is its coverage.
    static let deadZone: (start: Float, end: Float) = (0.04, 0.12)

    /// What each pixel takes part in.
    struct Regions {
        /// Within the band of the coarse edge, or where the coarse mask is unsure.
        var near: [Bool]
        /// Further into the coarse foreground, within the reach.
        var far: [Bool]
        /// Inside the coarse sky, beyond the band.
        var inside: [Bool]
    }

    /// `coarse` is any size; `image` is the photo at the size to solve at.
    public static func refine(_ coarse: GrayMask, image: CGImage) -> GrayMask {
        let size = PixelSize(width: image.width, height: image.height)
        guard let rgb = RGBImage(image, size: size) else { return coarse.resized(to: size) }
        let width = size.width
        let height = size.height
        let count = width * height
        let mask = coarse.resized(to: size).coverage
        let unchanged = GrayMask(width: width, height: height, coverage: mask)
        let regions = Self.regions(mask, width: width, height: height)

        let linear = Self.linear(rgb)
        var sky = [Bool](repeating: false, count: count)
        Parallel.fill(&sky) { mask[$0] > 0.9 && !regions.near[$0] }
        var solid = [Bool](repeating: false, count: count)
        Parallel.fill(&solid) { mask[$0] < 0.1 && !regions.near[$0] }
        guard sky.contains(true) else { return unchanged }
        var seeds = [Bool](repeating: false, count: count)
        Parallel.fill(&seeds) { mask[$0] > 0.5 }
        var result = mask
        for _ in 0 ..< 2 {
            let behind = SkyColour(linear, sky: sky, width: width, height: height)
            guard let front = ForegroundColour(
                linear, behind: behind, sky: sky, solid: solid, width: width, height: height,
            ) else { return unchanged }
            let (refined, confidence, offLine) = Self.solve(
                linear, mask: mask, regions: regions, behind: behind, front: front, width: width,
            )

            // Far from the edge, only sky-like pixels connected to the sky through sky-like ones;
            // inside the sky, only what is clearly not sky (noise and cloud texture stay sky).
            var likely = [Bool](repeating: false, count: count)
            Parallel.fill(&likely) { index in
                refined[index] > 0.5 && (regions.near[index] || regions.far[index] || mask[index] > 0.5)
            }
            let connected = Self.connected(likely, seeds: seeds, width: width, height: height)
            // Sky walled in by dense twigs reaches the sky only through twigs. It is taken back
            // where it is nearly pure sky of the colour the sky has behind it: sure of the colours,
            // on the line from the foreground's colour to the sky's (as a blue sign or car beside
            // the sky rarely is), and where the models saw some sky. They see a little through a
            // crown, but none in a snow field or the sea under a pale sky, which colour can't tell
            // from it.
            var accepted = connected
            Parallel.fill(&accepted) { index in
                connected[index] || (regions.far[index] && refined[index] > 0.9 && confidence[index] > 0.9
                    && offLine[index] < Self.walledOffLine && mask[index] > Self.walledPrior)
            }
            // The edge pixels of sky taken back from the foreground are mostly branch, so not
            // likely themselves, but they touch sky that is: they take their own coverage too.
            let edged = RemovalRegion.dilated(accepted, width: width, height: height, radius: Self.edgeReach)
            Parallel.fill(&result) { index in
                let intrusion = regions.inside[index] && refined[index] < 0.75 && confidence[index] > 0.5
                return regions.near[index] || (regions.far[index] && edged[index]) || intrusion
                    ? refined[index] : mask[index]
            }
            // The next pass learns the colours from what this one found: the foreground's only from
            // pixels clear of any that hold some sky. The nearest to an edge hold a little, and would
            // teach it a colour short of the foreground's.
            let solved = result
            Parallel.fill(&sky) { index in
                (solved[index] > 0.97 && confidence[index] > 0.5)
                    || (mask[index] > 0.9 && !regions.near[index] && solved[index] > 0.9)
            }
            var holdsSky = [Bool](repeating: false, count: count)
            Parallel.fill(&holdsSky) { solved[$0] > Self.mixed }
            let besideSky = RemovalRegion.dilated(holdsSky, width: width, height: height, radius: Self.clearance)
            Parallel.fill(&solid) { index in
                solved[index] < 0.03 && !besideSky[index]
                    && (confidence[index] > 0.5 || !(regions.near[index] || regions.far[index]))
            }
        }
        return GrayMask(width: width, height: height, coverage: result)
    }

    /// The band, the reach and the sky's inside, from distances to the coarse edge measured at a
    /// quarter of the size (a few pixels off doesn't matter at these widths).
    static func regions(_ mask: [Float], width: Int, height: Int) -> Regions {
        let long = Float(max(width, height))
        let factor = 4
        let smallWidth = max(1, width / factor)
        let smallHeight = max(1, height / factor)
        let small = (0 ..< smallWidth * smallHeight).map { index -> Float in
            let x = min((index % smallWidth) * factor + factor / 2, width - 1)
            let y = min((index / smallWidth) * factor + factor / 2, height - 1)
            return mask[y * width + x]
        }
        let reachPixels = reach * long
        let distance = Self.distance(
            from: small, width: smallWidth, height: smallHeight, limit: reachPixels / Float(factor),
        )
        let bandPixels = max(4, band * long)
        let count = width * height
        var regions = Regions(
            near: [Bool](repeating: false, count: count), far: [Bool](repeating: false, count: count),
            inside: [Bool](repeating: false, count: count),
        )
        for y in 0 ..< height {
            let row = min(y / factor, smallHeight - 1) * smallWidth
            for x in 0 ..< width {
                let index = y * width + x
                let d = distance[row + min(x / factor, smallWidth - 1)] * Float(factor)
                let value = mask[index]
                let near = d <= bandPixels || (value > 0.1 && value < 0.9)
                regions.near[index] = near
                regions.far[index] = !near && d <= reachPixels && value <= 0.5
                regions.inside[index] = !near && value > 0.5
            }
        }
        return regions
    }

    /// Each solved pixel's coverage, where its colour lies between the sky's and the
    /// foreground's, blended back to the coarse mask as the two get too close to tell apart; how
    /// sure of the colours; and how far its colour lies off the line between them, as a share of
    /// the distance between them.
    static func solve(
        _ linear: [SIMD3<Float>], mask: [Float], regions: Regions, behind: SkyColour, front: ForegroundColour,
        width: Int,
    ) -> (refined: [Float], confidence: [Float], offLine: [Float]) {
        var refined = mask
        var confidence = [Float](repeating: 0, count: mask.count)
        var offLine = [Float](repeating: 1, count: mask.count)
        let height = mask.count / width
        refined.withUnsafeMutableBufferPointer { refinedBuffer in
            confidence.withUnsafeMutableBufferPointer { confidenceBuffer in
                offLine.withUnsafeMutableBufferPointer { offLineBuffer in
                    // Each row writes only its own pixels.
                    nonisolated(unsafe) let refinedOut = refinedBuffer
                    nonisolated(unsafe) let confidenceOut = confidenceBuffer
                    nonisolated(unsafe) let offLineOut = offLineBuffer
                    DispatchQueue.concurrentPerform(iterations: height) { y in
                        for index in y * width ..< (y + 1) * width
                            where regions.near[index] || regions.far[index] || regions.inside[index] {
                            let f = front.at(index)
                            let difference = behind.at(index) - f
                            let span = simd_length_squared(difference)
                            let projected = simd_dot(linear[index] - f, difference) / max(span, 1e-8)
                            let alpha = Self.coverage(projected)
                            let sure = min(
                                max((span.squareRoot() - tolerance.low) / (tolerance.high - tolerance.low), 0),
                                1,
                            )
                            refinedOut[index] = sure * alpha + (1 - sure) * mask[index]
                            confidenceOut[index] = sure
                            offLineOut[index] = simd_length(linear[index] - f - projected * difference)
                                / max(span.squareRoot(), 1e-4)
                        }
                    }
                }
            }
        }
        return (refined, confidence, offLine)
    }

    /// Coverage from where a colour lies on the line from the foreground's colour (0) to the
    /// sky's (1): nought or whole within `deadZone.start` of either end, the same from
    /// `deadZone.end` in, and eased between by a cubic that meets both with the same slope.
    static func coverage(_ projected: Float) -> Float {
        func eased(_ p: Float) -> Float {
            let (start, end) = deadZone
            guard p > start else { return 0 }
            guard p < end else { return p }
            let t = (p - start) / (end - start)
            return end * t * t * (3 - 2 * t) + (end - start) * t * t * (t - 1)
        }
        let p = min(max(projected, 0), 1)
        return p < 0.5 ? eased(p) : 1 - eased(1 - p)
    }

    // MARK: - Colours

    /// sRGB to linear light, per pixel.
    static func linear(_ rgb: RGBImage) -> [SIMD3<Float>] {
        let table = (0 ..< 256).map { value -> Float in
            SRGB.decode(Float(value) / 255)
        }
        var out = [SIMD3<Float>](repeating: .zero, count: rgb.width * rgb.height)
        let pixels = rgb.pixels
        Parallel.fill(&out) { index in
            SIMD3(table[Int(pixels[index * 4])], table[Int(pixels[index * 4 + 1])], table[Int(pixels[index * 4 + 2])])
        }
        return out
    }

    /// The sky's colour behind every pixel, from the sure sky: at a quarter of the size (it is
    /// smooth), read back bilinearly.
    struct SkyColour: Sendable {
        static let factor = 4
        let width: Int
        let smallWidth: Int
        let smallHeight: Int
        let filled: [SIMD3<Float>]

        init(_ linear: [SIMD3<Float>], sky: [Bool], width: Int, height: Int) {
            let factor = Self.factor
            self.width = width
            smallWidth = max(1, width / factor)
            smallHeight = max(1, height / factor)
            var values = [SIMD3<Float>](repeating: .zero, count: smallWidth * smallHeight)
            var weights = [Float](repeating: 0, count: smallWidth * smallHeight)
            for y in 0 ..< smallHeight {
                for x in 0 ..< smallWidth {
                    var sum = SIMD3<Float>.zero
                    var all = true
                    for dy in 0 ..< factor {
                        for dx in 0 ..< factor {
                            let index = min(y * factor + dy, height - 1) * width + min(x * factor + dx, width - 1)
                            sum += linear[index]
                            all = all && sky[index]
                        }
                    }
                    values[y * smallWidth + x] = sum / Float(factor * factor)
                    weights[y * smallWidth + x] = all ? 1 : 0
                }
            }
            filled = PullPush.fill(values, weights: weights, width: smallWidth, height: smallHeight, levels: nil)
        }

        func at(_ index: Int) -> SIMD3<Float> {
            let factor = Float(Self.factor)
            let x = (Float(index % width) + 0.5) / factor - 0.5
            let y = (Float(index / width) + 0.5) / factor - 0.5
            let x0 = min(max(Int(x.rounded(.down)), 0), smallWidth - 1)
            let y0 = min(max(Int(y.rounded(.down)), 0), smallHeight - 1)
            let x1 = min(x0 + 1, smallWidth - 1)
            let y1 = min(y0 + 1, smallHeight - 1)
            let fx = min(max(x - Float(x0), 0), 1)
            let fy = min(max(y - Float(y0), 0), 1)
            let top = filled[y0 * smallWidth + x0] * (1 - fx) + filled[y0 * smallWidth + x1] * fx
            let bottom = filled[y1 * smallWidth + x0] * (1 - fx) + filled[y1 * smallWidth + x1] * fx
            return top * (1 - fy) + bottom * fy
        }
    }

    /// The foreground's colour behind every pixel, from the sure foreground, weighted by how far
    /// from the sky's colour, so pure foreground outweighs pixels mixed with sky (inside a
    /// cut-out crown, most are). Spread only a few levels, as foreground varies. With no sure
    /// foreground at all (every trunk inside the band), one colour from the purest pixels that
    /// aren't sure sky: learnt locally, each pixel would learn its own colour.
    struct ForegroundColour: Sendable {
        let filled: [SIMD3<Float>]?
        let constant: SIMD3<Float>

        /// Nil if nothing differs from the sky.
        init?(
            _ linear: [SIMD3<Float>], behind: SkyColour, sky: [Bool], solid: [Bool], width: Int, height: Int,
        ) {
            var distinct = [Float](repeating: 0, count: linear.count)
            distinct.withUnsafeMutableBufferPointer { buffer in
                nonisolated(unsafe) let out = buffer
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for index in y * width ..< (y + 1) * width where !sky[index] {
                        let separation = simd_length(linear[index] - behind.at(index))
                        out[index] = min(max((separation - 0.04) / 0.25, 0), 1)
                    }
                }
            }
            var weights = [Float](repeating: 0, count: solid.count)
            let separations = distinct
            Parallel.fill(&weights) { solid[$0] ? separations[$0] * separations[$0] * separations[$0] : 0 }
            if weights.reduce(0, +) >= 1 {
                filled = PullPush.fill(linear, weights: weights, width: width, height: height, levels: 7)
                constant = .zero
                return
            }
            var sum = SIMD3<Float>.zero
            var total: Float = 0
            for index in linear.indices where !sky[index] {
                let weight = distinct[index] * distinct[index]
                sum += weight * linear[index]
                total += weight
            }
            guard total >= 1 else { return nil }
            filled = nil
            constant = sum / total
        }

        func at(_ index: Int) -> SIMD3<Float> {
            filled?[index] ?? constant
        }
    }

    // MARK: - Geometry

    /// Distance in pixels from the boundary of `mask > 0.5`, capped at `limit` (a 3-4 chamfer).
    static func distance(from mask: [Float], width: Int, height: Int, limit: Float) -> [Float] {
        let count = width * height
        let inside = mask.map { $0 > 0.5 }
        let cap = (limit + 2) * 3
        var d = [Float](repeating: cap, count: count)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = y * width + x
                let value = inside[index]
                if (x > 0 && inside[index - 1] != value) || (x < width - 1 && inside[index + 1] != value)
                    || (y > 0 && inside[index - width] != value) || (y < height - 1 && inside[index + width] != value) {
                    d[index] = 0
                }
            }
        }
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = y * width + x
                var value = d[index]
                if x > 0 {
                    value = min(value, d[index - 1] + 3)
                }
                if y > 0 {
                    value = min(value, d[index - width] + 3)
                    if x > 0 {
                        value = min(value, d[index - width - 1] + 4)
                    }
                    if x < width - 1 {
                        value = min(value, d[index - width + 1] + 4)
                    }
                }
                d[index] = value
            }
        }
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in stride(from: width - 1, through: 0, by: -1) {
                let index = y * width + x
                var value = d[index]
                if x < width - 1 {
                    value = min(value, d[index + 1] + 3)
                }
                if y < height - 1 {
                    value = min(value, d[index + width] + 3)
                    if x < width - 1 {
                        value = min(value, d[index + width + 1] + 4)
                    }
                    if x > 0 {
                        value = min(value, d[index + width - 1] + 4)
                    }
                }
                d[index] = value
            }
        }
        return d.map { $0 / 3 }
    }

    /// The pixels of `region` four-connected to a pixel of it where `seeds` holds. Seeds count as
    /// connected at once; the flood starts only from those at the edge of what they cover.
    static func connected(_ region: [Bool], seeds: [Bool], width: Int, height _: Int) -> [Bool] {
        var connected = (0 ..< region.count).map { region[$0] && seeds[$0] }
        var stack: [Int] = []
        func open(_ index: Int) -> Bool {
            region[index] && !connected[index]
        }
        for index in region.indices where connected[index] {
            let x = index % width
            if (x > 0 && open(index - 1)) || (x < width - 1 && open(index + 1))
                || (index >= width && open(index - width)) || (index + width < region.count && open(index + width)) {
                stack.append(index)
            }
        }
        while let index = stack.popLast() {
            let x = index % width
            if x > 0, open(index - 1) {
                connected[index - 1] = true
                stack.append(index - 1)
            }
            if x < width - 1, open(index + 1) {
                connected[index + 1] = true
                stack.append(index + 1)
            }
            if index >= width, open(index - width) {
                connected[index - width] = true
                stack.append(index - width)
            }
            if index + width < region.count, open(index + width) {
                connected[index + width] = true
                stack.append(index + width)
            }
        }
        return connected
    }
}

/// Work split into a chunk per core.
enum Parallel {
    /// `array[i] = value(i)` for every index, in parallel; each chunk writes only its own indices.
    static func fill<T>(_ array: inout [T], _ value: @Sendable (Int) -> T) {
        let count = array.count
        array.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer
            let parts = max(1, min(count / 16384, ProcessInfo.processInfo.activeProcessorCount * 4))
            DispatchQueue.concurrentPerform(iterations: parts) { part in
                for index in part * count / parts ..< (part + 1) * count / parts {
                    out[index] = value(index)
                }
            }
        }
    }
}

/// Fills values where their weight is 0 from the weighted values around them, coarse to fine
/// (the pull-push of Gortler et al., 1996).
enum PullPush {
    struct Level {
        var values: [SIMD3<Float>]
        var weights: [Float]
        var width: Int
        var height: Int
    }

    static func fill(
        _ values: [SIMD3<Float>], weights: [Float], width: Int, height: Int, levels: Int?,
    ) -> [SIMD3<Float>] {
        var pyramid: [Level] = []
        var weighted = [SIMD3<Float>](repeating: .zero, count: values.count)
        Parallel.fill(&weighted) { values[$0] * weights[$0] }
        var level = Level(values: weighted, weights: weights, width: width, height: height)
        while min(level.width, level.height) > 1, levels.map({ pyramid.count < $0 }) ?? true {
            pyramid.append(level)
            level = Self.down(level)
        }
        var filled = zip(level.values, level.weights).map { $0 / max($1, 1e-6) }
        var parent = (width: level.width, height: level.height)
        for child in pyramid.reversed() {
            filled = Self.up(filled, parent: parent, child: child)
            parent = (child.width, child.height)
        }
        return filled
    }

    /// Sums over 2×2 blocks.
    static func down(_ level: Level) -> Level {
        let width = (level.width + 1) / 2
        let height = (level.height + 1) / 2
        var values = [SIMD3<Float>](repeating: .zero, count: width * height)
        var weights = [Float](repeating: 0, count: width * height)
        // Each output row sums its own two input rows.
        values.withUnsafeMutableBufferPointer { valueBuffer in
            weights.withUnsafeMutableBufferPointer { weightBuffer in
                nonisolated(unsafe) let valuesOut = valueBuffer
                nonisolated(unsafe) let weightsOut = weightBuffer
                DispatchQueue.concurrentPerform(iterations: height) { row in
                    for y in row * 2 ..< min(row * 2 + 2, level.height) {
                        for x in 0 ..< level.width {
                            let target = row * width + x / 2
                            valuesOut[target] += level.values[y * level.width + x]
                            weightsOut[target] += level.weights[y * level.width + x]
                        }
                    }
                }
            }
        }
        return Level(values: values, weights: weights, width: width, height: height)
    }

    /// The child's own mean where it has weight, else the parent repeated 2×2 and box blurred 3×3.
    static func up(_ filled: [SIMD3<Float>], parent: (width: Int, height: Int), child: Level) -> [SIMD3<Float>] {
        var out = [SIMD3<Float>](repeating: .zero, count: child.width * child.height)
        out.withUnsafeMutableBufferPointer { buffer in
            // Each row writes only its own pixels.
            nonisolated(unsafe) let result = buffer
            DispatchQueue.concurrentPerform(iterations: child.height) { y in
                for x in 0 ..< child.width {
                    let index = y * child.width + x
                    let weight = child.weights[index]
                    if weight >= 1 {
                        result[index] = child.values[index] / weight
                        continue
                    }
                    var sum = SIMD3<Float>.zero
                    for dy in -1 ... 1 {
                        let sy = min(min(max(y + dy, 0), child.height - 1) / 2, parent.height - 1)
                        for dx in -1 ... 1 {
                            let sx = min(min(max(x + dx, 0), child.width - 1) / 2, parent.width - 1)
                            sum += filled[sy * parent.width + sx]
                        }
                    }
                    let mean = child.values[index] / max(weight, 1e-6)
                    result[index] = weight * mean + (1 - weight) * sum / 9
                }
            }
        }
        return out
    }
}
