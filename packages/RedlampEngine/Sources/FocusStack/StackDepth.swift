import Foundation

/// Which frame is sharpest where, at quarter resolution: the depth map fusion follows.
struct StackDepthMap: Equatable {
    let width: Int
    let height: Int
    /// Fractional frame index per pixel, 0 ... frames - 1.
    let depth: [Float]
    /// Whether the fine solve was trusted there; elsewhere the coarse solve fills in.
    let confident: [Bool]

    var confidentFraction: Float {
        Float(confident.count(where: \.self)) / Float(max(confident.count, 1))
    }
}

/// The depth solve of the validated prototype (`research/prototypes/focus_stack/focus_stack.py`):
/// a sum-modified-Laplacian focus volume, each slice regularised by a guided filter (He, Sun &
/// Tang 2013) guided by the sharpest frame's luminance, winner-takes-all with parabolic sub-frame
/// refinement, and a coarser solve where the peak doesn't stand out.
enum StackDepthSolver {
    /// Sizes relative to the image being stacked, not the sensor: the prototype's, validated on
    /// ~2000-pixel frames, so the solve runs at a quarter of the 2048-pixel analysis copy.
    struct Settings {
        /// Focus window radius at the analysis resolution (a quarter of it in the volume).
        var radius = 5
        /// Guided-filter radius in the volume; the coarse solve uses four times this.
        var smoothing = 8
        /// How strong an edge (luma variance, square-root encoded) must be to keep a depth jump.
        var edgeEpsilon: Float = 1e-3

        var focusRadius: Int {
            max(1, Int((Float(radius) / 4).rounded()))
        }
    }

    /// `lumas`: every aligned frame's encoded luminance at quarter resolution, in stack order.
    static func solve(_ lumas: [LumaImage], settings: Settings = Settings()) -> StackDepthMap {
        let volume = Parallel.map(lumas.count) { sumModifiedLaplacian(lumas[$0], radius: settings.focusRadius) }
        return solve(volume: volume, lumas: lumas, settings: settings)
    }

    /// Solves from a precomputed focus `volume` (one sum-modified-Laplacian slice per frame, in
    /// the reference's geometry) and the aligned `lumas` that guide the regularisation.
    static func solve(volume: [[Float]], lumas: [LumaImage], settings: Settings = Settings()) -> StackDepthMap {
        precondition(!lumas.isEmpty && volume.count == lumas.count)
        let width = lumas[0].width
        let height = lumas[0].height
        let smoothing = settings.smoothing
        let count = width * height

        // The guide: at each pixel, the luminance of the frame that is sharpest there.
        var guide = [Float](repeating: 0, count: count)
        var peak = [Float](repeating: -1, count: count)
        for (frame, slice) in volume.enumerated() {
            for index in 0 ..< count where slice[index] > peak[index] {
                peak[index] = slice[index]
                guide[index] = lumas[frame].pixels[index]
            }
        }
        let maximum = volume.reduce(0) { max($0, $1.max() ?? 0) }
        let epsilon = 1e-3 * maximum * maximum
        let guidance = guide
        let filtered = Parallel.map(2 * volume.count) { job in
            guidedFilter(
                guide: guidance,
                source: volume[job / 2],
                width: width,
                height: height,
                radius: job.isMultiple(of: 2) ? smoothing : smoothing * 4,
                epsilon: epsilon,
            )
        }
        let fine = stride(from: 0, to: filtered.count, by: 2).map { filtered[$0] }
        let coarse = stride(from: 1, to: filtered.count, by: 2).map { filtered[$0] }

        let noiseFloor = median(of: volume)
        func standsOut(_ cost: [[Float]], at index: Int) -> Bool {
            var best: Float = -.greatestFiniteMagnitude
            var sum: Float = 0
            for slice in cost {
                best = max(best, slice[index])
                sum += slice[index]
            }
            return best > 2 * noiseFloor && (best - sum / Float(cost.count)) / (best + 1e-12) > 0.15
        }
        var depth = [Float](repeating: 0, count: count)
        var confident = [Bool](repeating: false, count: count)
        var known = [Bool](repeating: true, count: count)
        for index in 0 ..< count {
            confident[index] = standsOut(fine, at: index)
            if confident[index] {
                depth[index] = refinedArgmax(fine, at: index)
            } else if standsOut(coarse, at: index) {
                depth[index] = refinedArgmax(coarse, at: index)
            } else {
                known[index] = false
            }
        }
        // Where no frame is sharp, any choice is noise, and noise-driven choices make blotches:
        // follow the surroundings instead.
        let filled = fill(depth, known: known, width: width, height: height, empty: Float(lumas.count - 1) / 2)
        // Then smooth the labels along the image: depth jumps survive only where the image has
        // an edge too, so multi-peaked focus (transparent subjects) doesn't leave seams where
        // neighbouring pixels chose far-apart frames. Real depth edges are almost always image
        // edges; a step across flat texture (the synthetic two-plane test) does get softened.
        let last = Float(lumas.count - 1)
        let smoothed = guidedFilter(
            guide: guidance, source: filled, width: width, height: height, radius: smoothing,
            epsilon: settings.edgeEpsilon,
        ).map { min(max($0, 0), last) }
        return StackDepthMap(width: width, height: height, depth: smoothed, confident: confident)
    }

    /// `values` where `known`, elsewhere interpolated from the known values around (push-pull:
    /// averages of known values down a pyramid, blended back up); `empty` if nothing is known.
    static func fill(_ values: [Float], known: [Bool], width: Int, height: Int, empty: Float) -> [Float] {
        guard known.contains(true) else { return [Float](repeating: empty, count: values.count) }
        guard known.contains(false) else { return values }
        // Push: weighted sums and weights, halving until one pixel remains.
        var levels = [(
            width: width,
            height: height,
            sums: zip(values, known).map { $1 ? $0 : 0 },
            weights: known.map { $0 ? Float(1) : 0 },
        )]
        while levels.last!.width > 1 || levels.last!.height > 1 {
            let fine = levels.last!
            let (w, h) = ((fine.width + 1) / 2, (fine.height + 1) / 2)
            var sums = [Float](repeating: 0, count: w * h)
            var weights = [Float](repeating: 0, count: w * h)
            for y in 0 ..< fine.height {
                for x in 0 ..< fine.width {
                    sums[(y / 2) * w + x / 2] += fine.sums[y * fine.width + x]
                    weights[(y / 2) * w + x / 2] += fine.weights[y * fine.width + x]
                }
            }
            levels.append((w, h, sums, weights))
        }
        // Pull: each level's average, with gaps taken from the coarser level (bilinear).
        var coarse = levels.last!.sums.indices.map { levels.last!.sums[$0] / max(levels.last!.weights[$0], 1e-12) }
        for level in levels.dropLast().reversed() {
            let (cw, ch) = ((level.width + 1) / 2, (level.height + 1) / 2)
            var out = [Float](repeating: 0, count: level.width * level.height)
            for y in 0 ..< level.height {
                for x in 0 ..< level.width {
                    let fx = min(max((Float(x) + 0.5) / 2 - 0.5, 0), Float(cw - 1))
                    let fy = min(max((Float(y) + 0.5) / 2 - 0.5, 0), Float(ch - 1))
                    let (x0, y0) = (Int(fx), Int(fy))
                    let (x1, y1) = (min(x0 + 1, cw - 1), min(y0 + 1, ch - 1))
                    let (tx, ty) = (fx - Float(x0), fy - Float(y0))
                    let top = coarse[y0 * cw + x0] * (1 - tx) + coarse[y0 * cw + x1] * tx
                    let bottom = coarse[y1 * cw + x0] * (1 - tx) + coarse[y1 * cw + x1] * tx
                    let up = top * (1 - ty) + bottom * ty
                    let index = y * level.width + x
                    let weight = min(level.weights[index], 1)
                    let own = level.sums[index] / max(level.weights[index], 1e-12)
                    out[index] = weight * own + (1 - weight) * up
                }
            }
            coarse = out
        }
        return zip(coarse, zip(values, known)).map { filled, original in original.1 ? original.0 : filled }
    }

    /// The best frame at `index`, refined by the parabola through it and its neighbours.
    static func refinedArgmax(_ cost: [[Float]], at index: Int) -> Float {
        var best = 0
        for frame in 1 ..< cost.count where cost[frame][index] > cost[best][index] {
            best = frame
        }
        let last = cost.count - 1
        let c0 = cost[max(best - 1, 0)][index]
        let c1 = cost[best][index]
        let c2 = cost[min(best + 1, last)][index]
        let denominator = c0 - 2 * c1 + c2
        let offset = abs(denominator) > 1e-12 ? 0.5 * (c0 - c2) / denominator : 0
        return min(max(Float(best) + min(max(offset, -0.5), 0.5), 0), Float(last))
    }

    /// Sum-modified-Laplacian (Nayar & Nakagawa 1994): |2I - left - right| + |2I - up - down|,
    /// averaged over a (2r + 1)^2 window. Borders reflect.
    static func sumModifiedLaplacian(_ image: LumaImage, radius: Int) -> [Float] {
        let width = image.width
        let height = image.height
        var modified = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let center = 2 * image[x, y]
                let horizontal = center - image[reflect(x - 1, width), y] - image[reflect(x + 1, width), y]
                let vertical = center - image[x, reflect(y - 1, height)] - image[x, reflect(y + 1, height)]
                modified[y * width + x] = abs(horizontal) + abs(vertical)
            }
        }
        return boxMean(modified, width: width, height: height, radius: radius)
    }

    /// The guided filter of `source` by `guide` (He, Sun & Tang, TPAMI 2013), single channel.
    static func guidedFilter(
        guide: [Float], source: [Float], width: Int, height: Int, radius: Int, epsilon: Float,
    ) -> [Float] {
        let count = width * height
        let meanI = boxMean(guide, width: width, height: height, radius: radius)
        let meanP = boxMean(source, width: width, height: height, radius: radius)
        var ip = [Float](repeating: 0, count: count)
        var ii = [Float](repeating: 0, count: count)
        for index in 0 ..< count {
            ip[index] = guide[index] * source[index]
            ii[index] = guide[index] * guide[index]
        }
        let meanIP = boxMean(ip, width: width, height: height, radius: radius)
        let meanII = boxMean(ii, width: width, height: height, radius: radius)
        var a = [Float](repeating: 0, count: count)
        var b = [Float](repeating: 0, count: count)
        for index in 0 ..< count {
            let variance = meanII[index] - meanI[index] * meanI[index]
            let covariance = meanIP[index] - meanI[index] * meanP[index]
            a[index] = covariance / (variance + epsilon)
            b[index] = meanP[index] - a[index] * meanI[index]
        }
        let meanA = boxMean(a, width: width, height: height, radius: radius)
        let meanB = boxMean(b, width: width, height: height, radius: radius)
        return (0 ..< count).map { meanA[$0] * guide[$0] + meanB[$0] }
    }

    /// Mean over a (2r + 1)^2 window with reflected borders, separable running sums.
    static func boxMean(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        let size = Float(2 * radius + 1)
        var rows = [Float](repeating: 0, count: values.count)
        for y in 0 ..< height {
            let row = y * width
            var sum: Float = 0
            for k in -radius ... radius {
                sum += values[row + reflect(k, width)]
            }
            for x in 0 ..< width {
                rows[row + x] = sum / size
                sum += values[row + reflect(x + radius + 1, width)] - values[row + reflect(x - radius, width)]
            }
        }
        var out = [Float](repeating: 0, count: values.count)
        for x in 0 ..< width {
            var sum: Float = 0
            for k in -radius ... radius {
                sum += rows[reflect(k, height) * width + x]
            }
            for y in 0 ..< height {
                out[y * width + x] = sum / size
                sum += rows[reflect(y + radius + 1, height) * width + x] - rows[reflect(y - radius, height) * width + x]
            }
        }
        return out
    }

    /// Reflects an index into 0 ..< count, repeating the edge sample ("fedcba|abcdef").
    static func reflect(_ index: Int, _ count: Int) -> Int {
        guard count > 1 else { return 0 }
        var i = index
        let period = 2 * count
        i %= period
        if i < 0 {
            i += period
        }
        return i < count ? i : period - 1 - i
    }

    /// The median of the whole volume, from an evenly strided sample of about a million values.
    static func median(of volume: [[Float]]) -> Float {
        let total = volume.reduce(0) { $0 + $1.count }
        guard total > 0 else { return 0 }
        let step = max(1, total / 1_000_000)
        var sample: [Float] = []
        sample.reserveCapacity(total / step + volume.count)
        for slice in volume {
            sample.append(contentsOf: stride(from: 0, to: slice.count, by: step).map { slice[$0] })
        }
        sample.sort()
        return sample[sample.count / 2]
    }
}
