import Accelerate
import CoreGraphics
import Foundation
import RedlampEngineAPI
import simd

/// Per-pixel coverage for a person or subject mask: stray hairs, beard curls, fur.
///
/// Closed-form matting (Levin, Lischinski and Weiss, 2008): within every 3×3 window, coverage is
/// taken to be a linear function of colour, and the coverage that best fits that everywhere in an
/// uncertain band around the coarse edge is solved for, given sure subject inside the band and sure
/// background outside it. Unlike a colour model it needs no estimate of the background behind a
/// strand, which is why it holds up where the background isn't smooth. Its matrix is never built:
/// it is applied through 3×3 window sums (He, Sun and Tang, 2010), and conjugate gradients run over
/// the uncertain pixels only, preconditioned by the matrix's diagonal and started from the coarse
/// mask, coarse to fine.
///
/// Prototyped as `research/prototypes/masking/cf_matte.py`. Against a learned matting reference
/// (ViTMatte, which can't ship) it takes the error around the edge from 0.085 to 0.067 on four
/// portraits and from 0.182 to 0.122 on a dancer in a costume Vision is unsure of (MSK-17).
public enum ClosedFormMatte {
    /// Regularisation: larger smooths coverage, smaller follows colour (and JPEG blocks) more.
    static let epsilon: Float = 1e-5
    /// The uncertain band, as fractions of the long side: a little inside the coarse edge, more
    /// outside it, where hair pokes out.
    static let inner: Float = 0.006
    static let outer: Float = 0.02
    /// Coarse to fine: the photo halved until its long side is at most this, where most
    /// iterations run; each finer size starts from the coarser one's result.
    static let coarsestLongEdge = 1536
    static let coarsestIterations = 400
    static let refineIterations = 100
    static let finalIterations = 40

    /// `coarse` is any size; `image` is the photo at the size to solve at.
    public static func refine(_ coarse: GrayMask, image: CGImage) -> GrayMask {
        refine(coarse, image: image) { mask, size in Self.trimap(mask, width: size.width, height: size.height) }
    }

    /// The Refine Edge brush: coverage under `strokes` solved again, everything else kept as
    /// `coarse` has it (soft values included), so the solve meets the mask where the strokes end.
    /// Under a stroke, all of it outside the mask's edge is uncertain (hair the mask missed), but
    /// inside only the usual band along the edge, and wherever the mask is itself unsure: solving
    /// deep inside hair turns the dark gaps between strands into holes.
    public static func refine(_ coarse: GrayMask, image: CGImage, along strokes: [BrushStroke]) -> GrayMask {
        // A stroke reaching the frame solves the pixels along it too.
        refine(coarse, image: image, tolerance: brushTolerance, solvesBorder: true) { mask, size in
            let band = Self.band(along: strokes, size: size)
            let reach = inner * Float(max(size.width, size.height))
            let inside = SkyMatte.distance(from: mask, width: size.width, height: size.height, limit: reach)
            return mask.indices.map { index in
                let value = mask[index]
                let uncertain = band[index] && (value <= 0.9 || inside[index] <= reach)
                // 0.5 marks the uncertain pixels: a known pixel exactly at a half is nudged off it.
                return uncertain ? 0.5 : value == 0.5 ? 0.502 : value
            }
        }
    }

    /// A stroke's band is small, so its solve can run to a tighter residual: coverage has to
    /// reach across flat colour inside it, which a looser stop leaves half done.
    static let brushTolerance = 1e-6

    /// The pixels within reach of `strokes` (each a chain of discs of its size, a fraction of the
    /// height), at `size`.
    static func band(along strokes: [BrushStroke], size: PixelSize) -> [Bool] {
        let width = size.width
        let height = size.height
        var band = [Bool](repeating: false, count: width * height)
        for stroke in strokes {
            let radius = max(stroke.size * Double(height), 1)
            let points = stroke.points.map { SIMD2($0.x * Double(width), $0.y * Double(height)) }
            for (index, end) in points.enumerated() {
                let start = index > 0 ? points[index - 1] : end
                let x0 = max(Int((min(start.x, end.x) - radius).rounded(.down)), 0)
                let x1 = min(Int((max(start.x, end.x) + radius).rounded(.up)), width - 1)
                let y0 = max(Int((min(start.y, end.y) - radius).rounded(.down)), 0)
                let y1 = min(Int((max(start.y, end.y) + radius).rounded(.up)), height - 1)
                guard x0 <= x1, y0 <= y1 else { continue }
                let segment = end - start
                let length = simd_length_squared(segment)
                for y in y0 ... y1 {
                    for x in x0 ... x1 {
                        let pixel = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                        let t = length > 0 ? min(max(simd_dot(pixel - start, segment) / length, 0), 1) : 0
                        if simd_distance(pixel, start + t * segment) <= radius {
                            band[y * width + x] = true
                        }
                    }
                }
            }
        }
        return band
    }

    /// Coarse to fine, each size's trimap from `trimap(coarse at that size, the size)`.
    static func refine(
        _ coarse: GrayMask, image: CGImage, tolerance: Double = 1e-3, solvesBorder: Bool = false,
        trimap makeTrimap: ([Float], PixelSize) -> [Float],
    ) -> GrayMask {
        let size = PixelSize(width: image.width, height: image.height)
        guard let rgb = RGBImage(image, size: size) else { return coarse.resized(to: size) }
        let mask = coarse.resized(to: size).coverage
        let trimap = makeTrimap(mask, size)
        // Coarse to fine: many iterations where they're cheap, a few at full size.
        var sizes = [size]
        while let last = sizes.last, max(last.width, last.height) > coarsestLongEdge {
            sizes.append(PixelSize(width: last.width / 2, height: last.height / 2))
        }
        var initial: [Float]?
        var previous = size
        for (level, levelSize) in sizes.enumerated().reversed() where level > 0 {
            guard let levelRGB = RGBImage(image, size: levelSize) else { continue }
            let levelMask = coarse.resized(to: levelSize).coverage
            let start = initial.map { GrayMask(width: previous.width, height: previous.height, coverage: $0)
                .resized(to: levelSize).coverage
            } ?? levelMask
            initial = Self.solve(
                Self.colours(levelRGB), trimap: makeTrimap(levelMask, levelSize),
                initial: start, width: levelSize.width, height: levelSize.height,
                iterations: level == sizes.count - 1 ? coarsestIterations : refineIterations, tolerance: tolerance,
                solvesBorder: solvesBorder,
            )
            previous = levelSize
        }
        let start = initial.map { GrayMask(width: previous.width, height: previous.height, coverage: $0)
            .resized(to: size).coverage
        } ?? mask
        let iterations = sizes.count == 1 ? coarsestIterations : finalIterations
        let alpha = Self.solve(
            Self.colours(rgb), trimap: trimap, initial: start, width: size.width, height: size.height,
            iterations: iterations, tolerance: tolerance, solvesBorder: solvesBorder,
        )
        return GrayMask(width: size.width, height: size.height, coverage: alpha)
    }

    /// 1 for sure subject, 0 for sure background, 0.5 for uncertain: the band around the coarse
    /// edge, and wherever the coarse mask is itself unsure (Vision leaves much of a costume grey).
    static func trimap(_ mask: [Float], width: Int, height: Int) -> [Float] {
        let long = Float(max(width, height))
        let distance = SkyMatte.distance(from: mask, width: width, height: height, limit: outer * long)
        return mask.indices.map { index in
            if mask[index] > 0.1, mask[index] < 0.9 {
                return 0.5
            }
            if mask[index] > 0.5 {
                return distance[index] > inner * long ? 1 : 0.5
            }
            return distance[index] > outer * long ? 0 : 0.5
        }
    }

    static func colours(_ rgb: RGBImage) -> [SIMD3<Float>] {
        (0 ..< rgb.width * rgb.height).map { rgb.rgb($0 % rgb.width, $0 / rgb.width) }
    }

    // MARK: - Solve

    /// The matting Laplacian over the windows that touch the uncertain pixels.
    struct Laplacian: Sendable {
        let width: Int
        let height: Int
        let image: [SIMD3<Float>]
        /// Window centres (interior pixels within one pixel of an uncertain one), their colour
        /// means and inverted, regularised covariances.
        let centres: [Int32]
        let means: [SIMD3<Float>]
        let inverses: [simd_float3x3]
        /// Each pixel's window, or -1.
        let window: [Int32]

        init(image: [SIMD3<Float>], unknown: [Bool], width: Int, height: Int, epsilon: Float) {
            self.width = width
            self.height = height
            self.image = image
            var centres: [Int32] = []
            var window = [Int32](repeating: -1, count: width * height)
            for y in 1 ..< max(1, height - 1) {
                for x in 1 ..< max(1, width - 1) {
                    let index = y * width + x
                    var touches = false
                    for dy in -1 ... 1 where !touches {
                        for dx in -1 ... 1 where unknown[index + dy * width + dx] {
                            touches = true
                            break
                        }
                    }
                    if touches {
                        window[index] = Int32(centres.count)
                        centres.append(Int32(index))
                    }
                }
            }
            let found = centres
            var means = [SIMD3<Float>](repeating: .zero, count: found.count)
            var inverses = [simd_float3x3](repeating: simd_float3x3(), count: found.count)
            let regularised = simd_double3x3(diagonal: SIMD3(repeating: Double(epsilon) / 9))
            means.withUnsafeMutableBufferPointer { meanBuffer in
                inverses.withUnsafeMutableBufferPointer { inverseBuffer in
                    // Each chunk writes only its own windows.
                    nonisolated(unsafe) let meanOut = meanBuffer
                    nonisolated(unsafe) let inverseOut = inverseBuffer
                    Self.chunks(found.count) { range in
                        for k in range {
                            let centre = Int(found[k])
                            // In double precision: the covariance is tiny wherever colour is flat,
                            // and its inverse huge.
                            var sum = SIMD3<Double>.zero
                            var outer = simd_double3x3()
                            for dy in -1 ... 1 {
                                for dx in -1 ... 1 {
                                    let colour = SIMD3<Double>(image[centre + dy * width + dx])
                                    sum += colour
                                    outer += simd_double3x3(colour * colour.x, colour * colour.y, colour * colour.z)
                                }
                            }
                            let mean = sum / 9
                            let covariance = outer * (1.0 / 9)
                                - simd_double3x3(mean * mean.x, mean * mean.y, mean * mean.z)
                            meanOut[k] = SIMD3<Float>(mean)
                            let inverse = (covariance + regularised).inverse
                            inverseOut[k] = simd_float3x3(
                                SIMD3<Float>(inverse.columns.0), SIMD3<Float>(inverse.columns.1),
                                SIMD3<Float>(inverse.columns.2),
                            )
                        }
                    }
                }
            }
            self.centres = centres
            self.means = means
            self.inverses = inverses
            self.window = window
        }

        /// (L p) at `targets` into `out`, for a field `p` over the whole image; `a` and `b` are
        /// scratch, one per window.
        func apply(
            _ p: UnsafeBufferPointer<Double>, at targets: [Int32], into out: UnsafeMutableBufferPointer<Double>,
            a: UnsafeMutableBufferPointer<SIMD3<Double>>, b: UnsafeMutableBufferPointer<Double>,
        ) {
            // Each chunk writes only its own windows, then its own targets.
            nonisolated(unsafe) let field = p
            nonisolated(unsafe) let aOut = a
            nonisolated(unsafe) let bOut = b
            nonisolated(unsafe) let result = out
            let width = width
            centres.withUnsafeBufferPointer { centres in
                image.withUnsafeBufferPointer { image in
                    means.withUnsafeBufferPointer { means in
                        inverses.withUnsafeBufferPointer { inverses in
                            nonisolated(unsafe) let (centres, image, means, inverses) = (
                                centres,
                                image,
                                means,
                                inverses,
                            )
                            Self.chunks(centres.count) { range in
                                for k in range {
                                    let centre = Int(centres[k])
                                    var sumP: Double = 0
                                    var sumIP = SIMD3<Double>.zero
                                    for dy in -1 ... 1 {
                                        let row = centre + dy * width
                                        for index in row - 1 ... row + 1 {
                                            let value = field[index]
                                            sumP += value
                                            sumIP += SIMD3<Double>(image[index]) * value
                                        }
                                    }
                                    let meanP = sumP / 9
                                    let mean = SIMD3<Double>(means[k])
                                    let inverse = inverses[k]
                                    let difference = sumIP / 9 - mean * meanP
                                    let coefficient = SIMD3<Double>(inverse.columns.0) * difference.x
                                        + SIMD3<Double>(inverse.columns.1) * difference.y
                                        + SIMD3<Double>(inverse.columns.2) * difference.z
                                    aOut[k] = coefficient
                                    bOut[k] = meanP - simd_dot(coefficient, mean)
                                }
                            }
                        }
                    }
                }
            }
            targets.withUnsafeBufferPointer { targets in
                image.withUnsafeBufferPointer { image in
                    window.withUnsafeBufferPointer { window in
                        nonisolated(unsafe) let (targets, image, window) = (targets, image, window)
                        Self.chunks(targets.count) { range in
                            for t in range {
                                let index = Int(targets[t])
                                let colour = SIMD3<Double>(image[index])
                                var count: Double = 0
                                var fitted: Double = 0
                                for dy in -1 ... 1 {
                                    let row = index + dy * width
                                    // Past the first or last row there is no window; past either
                                    // side, the next row's border pixel has none either.
                                    for neighbour in row - 1 ... row + 1
                                        where neighbour >= 0 && neighbour < window.count {
                                        let k = Int(window[neighbour])
                                        if k >= 0 {
                                            count += 1
                                            fitted += simd_dot(aOut[k], colour) + bOut[k]
                                        }
                                    }
                                }
                                result[t] = count * field[index] - fitted
                            }
                        }
                    }
                }
            }
        }

        /// The diagonal of L at `targets`.
        func diagonal(at targets: [Int32]) -> [Double] {
            targets.map { target in
                let index = Int(target)
                var sum: Double = 0
                for dy in -1 ... 1 {
                    for dx in -1 ... 1 {
                        let neighbour = index + dy * width + dx
                        guard neighbour >= 0, neighbour < window.count else { continue }
                        let k = Int(window[neighbour])
                        guard k >= 0 else { continue }
                        let d = image[index] - means[k]
                        sum += 1 - (1 + Double(simd_dot(d, inverses[k] * d))) / 9
                    }
                }
                return max(sum, 1e-6)
            }
        }

        /// Runs `body` over `count` items split into a chunk per core.
        static func chunks(_ count: Int, _ body: @Sendable (Range<Int>) -> Void) {
            let parts = max(1, min(count / 4096, ProcessInfo.processInfo.activeProcessorCount * 4))
            DispatchQueue.concurrentPerform(iterations: parts) { part in
                body(part * count / parts ..< (part + 1) * count / parts)
            }
        }
    }

    /// Coverage minimising the matting energy, with the trimap's sure pixels fixed.
    static func solve(
        _ image: [SIMD3<Float>], trimap: [Float], initial: [Float], width: Int, height: Int, iterations: Int,
        tolerance: Double = 1e-3, solvesBorder: Bool = false,
    ) -> [Float] {
        // Border pixels only when asked: they are in the windows of the pixels inside them
        // (windows are centred inside the image), so their coverage follows as if the photo went
        // on; otherwise they keep `initial`, as masks made before the Refine Edge brush did.
        let unknownMask = trimap.indices.map { index in
            let x = index % width
            let y = index / width
            return trimap[index] == 0.5 && (solvesBorder || x > 0 && y > 0 && x < width - 1 && y < height - 1)
        }
        let unknown = unknownMask.indices.filter { unknownMask[$0] }.map { Int32($0) }
        // With nothing sure on one side (a thin object Segment Anything is never sure of) there
        // is nothing to solve against: the coarse mask stays.
        guard !unknown.isEmpty, trimap.contains(1), trimap.contains(0) else { return initial }
        let laplacian = Laplacian(image: image, unknown: unknownMask, width: width, height: height, epsilon: epsilon)
        let n = unknown.count
        let windows = laplacian.centres.count

        let field = UnsafeMutableBufferPointer<Double>.allocate(capacity: trimap.count)
        let a = UnsafeMutableBufferPointer<SIMD3<Double>>.allocate(capacity: windows)
        let b = UnsafeMutableBufferPointer<Double>.allocate(capacity: windows)
        let vectors = (0 ..< 5).map { _ in UnsafeMutableBufferPointer<Double>.allocate(capacity: n) }
        defer {
            field.deallocate()
            a.deallocate()
            b.deallocate()
            vectors.forEach { $0.deallocate() }
        }
        let (x, r, z, d, q) = (vectors[0], vectors[1], vectors[2], vectors[3], vectors[4])
        // Sure pixels keep their value in `field`; the uncertain ones are written per apply.
        for index in trimap.indices {
            field[index] = unknownMask[index] ? 0 : Double(trimap[index] == 0.5 ? initial[index] : trimap[index])
        }
        nonisolated(unsafe) let fieldOut = field
        func scatter(_ v: UnsafeMutableBufferPointer<Double>) {
            nonisolated(unsafe) let source = v
            unknown.withUnsafeBufferPointer { unknown in
                nonisolated(unsafe) let unknown = unknown
                Laplacian.chunks(n) { range in
                    for t in range {
                        fieldOut[Int(unknown[t])] = source[t]
                    }
                }
            }
        }
        func apply(_ v: UnsafeMutableBufferPointer<Double>, into out: UnsafeMutableBufferPointer<Double>) {
            scatter(v)
            laplacian.apply(UnsafeBufferPointer(field), at: unknown, into: out, a: a, b: b)
        }
        func dot(_ u: UnsafeMutableBufferPointer<Double>, _ v: UnsafeMutableBufferPointer<Double>) -> Double {
            var result: Double = 0
            vDSP_dotprD(u.baseAddress!, 1, v.baseAddress!, 1, &result, vDSP_Length(n))
            return result
        }

        // L (known + x) = 0 on the uncertain pixels: A x = -L known there, so r = -L (known + x).
        let inverseDiagonal = laplacian.diagonal(at: unknown).map { 1 / $0 }
        for t in 0 ..< n {
            x[t] = Double(initial[Int(unknown[t])])
        }
        scatter(x)
        laplacian.apply(UnsafeBufferPointer(field), at: unknown, into: r, a: a, b: b)
        var minusOne: Double = -1
        vDSP_vsmulD(r.baseAddress!, 1, &minusOne, r.baseAddress!, 1, vDSP_Length(n))
        for t in 0 ..< n {
            z[t] = r[t] * inverseDiagonal[t]
            d[t] = z[t]
        }
        var rz = dot(r, z)
        let norm = max(dot(r, r).squareRoot(), 1e-12)
        // From here A is applied to search directions alone: the sure values are zeroed once
        // (apply only ever writes the uncertain ones).
        for index in trimap.indices where !unknownMask[index] {
            field[index] = 0
        }
        for _ in 0 ..< iterations {
            apply(d, into: q)
            let curvature = dot(d, q)
            // The matrix is positive semi-definite; anything else is rounding: stop there.
            guard curvature > 1e-30, rz.isFinite else { break }
            var step = rz / curvature
            var minusStep = -step
            vDSP_vsmaD(d.baseAddress!, 1, &step, x.baseAddress!, 1, x.baseAddress!, 1, vDSP_Length(n))
            vDSP_vsmaD(q.baseAddress!, 1, &minusStep, r.baseAddress!, 1, r.baseAddress!, 1, vDSP_Length(n))
            if dot(r, r).squareRoot() / norm < tolerance {
                break
            }
            for t in 0 ..< n {
                z[t] = r[t] * inverseDiagonal[t]
            }
            let rzNext = dot(r, z)
            var beta = rzNext / rz
            vDSP_vsmaD(d.baseAddress!, 1, &beta, z.baseAddress!, 1, d.baseAddress!, 1, vDSP_Length(n))
            rz = rzNext
        }
        var out = trimap
        for t in 0 ..< n {
            let value = x[t].isFinite ? x[t] : Double(initial[Int(unknown[t])])
            out[Int(unknown[t])] = Float(min(max(value, 0), 1))
        }
        for index in out.indices where out[index] == 0.5 && !unknownMask[index] {
            out[index] = initial[index]
        }
        return out
    }
}
