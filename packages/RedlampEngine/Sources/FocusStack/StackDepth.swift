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
    struct Settings {
        /// Focus window radius at full resolution (the volume is at quarter resolution).
        var radius = 5
        /// Guided-filter radius at quarter resolution; the coarse solve uses four times this.
        var smoothing = 8
    }

    /// `lumas`: every aligned frame's encoded luminance at quarter resolution, in stack order.
    static func solve(_ lumas: [LumaImage], settings: Settings = Settings()) -> StackDepthMap {
        precondition(!lumas.isEmpty)
        let width = lumas[0].width
        let height = lumas[0].height
        let quarterRadius = max(1, Int((Float(settings.radius) * 0.25).rounded()))
        let volume = lumas.map { sumModifiedLaplacian($0, radius: quarterRadius) }
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
        let fine = volume.map { guidedFilter(
            guide: guide,
            source: $0,
            width: width,
            height: height,
            radius: settings.smoothing,
            epsilon: epsilon,
        ) }
        let coarse = volume.map { guidedFilter(
            guide: guide,
            source: $0,
            width: width,
            height: height,
            radius: settings.smoothing * 4,
            epsilon: epsilon,
        ) }

        let noiseFloor = median(of: volume)
        var depth = [Float](repeating: 0, count: count)
        var confident = [Bool](repeating: false, count: count)
        for index in 0 ..< count {
            var best: Float = -.greatestFiniteMagnitude
            var sum: Float = 0
            for slice in fine {
                best = max(best, slice[index])
                sum += slice[index]
            }
            let confidence = (best - sum / Float(fine.count)) / (best + 1e-12)
            confident[index] = best > 2 * noiseFloor && confidence > 0.15
            depth[index] = refinedArgmax(confident[index] ? fine : coarse, at: index)
        }
        return StackDepthMap(width: width, height: height, depth: depth, confident: confident)
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
