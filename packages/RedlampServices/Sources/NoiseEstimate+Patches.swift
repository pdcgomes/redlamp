import Accelerate
import Foundation

/// Texture-robust noise levels for Bayer mosaics, from the covariance of weakly textured patches.
/// Scene texture lives in a few principal directions of a patch set and the rest are noise.
/// Weakly textured patches are chosen by their gradient energy against what pure noise at the
/// current estimate would give, refined until it settles (X. Liu, M. Tanaka & M. Okutomi,
/// "Single-image noise level estimation for blind denoising", IEEE TIP 2013). The noise is the
/// smallest eigenvalue of their covariance, corrected for its small-sample bias: the lower edge
/// of the Marchenko–Pastur law, (1 - √(m/n))², over the m directions that are noise, not texture.
///
/// Each colour plane of the mosaic (one per 2 x 2 position) is treated as its own image, so
/// the noise within a patch is white. Patches don't overlap, so they are independent.
extension NoiseEstimator {
    static let patchSide = 5
    private static let patchDimensions = patchSide * patchSide
    private static let patchesPerPlane = 40000
    private static let patchesPerLevel = 2000
    private static let minimumPatches = 4 * patchDimensions
    private static let levelWidth: Float = 0.045
    private static let levelCount = 20
    /// Gradient energy of a 5 x 5 patch of pure noise has mean 80 σ² and standard deviation
    /// about 26 σ² (sum of squared neighbour differences); patches below this are weakly textured.
    private static let weakTextureLimit: Float = 140

    /// Per colour: noise variance at each brightness, or nil if the layout isn't a 2 x 2 mosaic.
    static func patchLevels(_ image: DecodedImage) -> [[Level]]? {
        guard case let .mosaic(pattern) = image.layout, pattern.width == 2, pattern.height == 2 else { return nil }
        var patches: [[Patch]] = [[], [], []]
        for py in 0 ..< 2 {
            for px in 0 ..< 2 {
                let color = Int(pattern.color(x: px, y: py))
                patches[color] += planePatches(image, x0: px, y0: py)
            }
        }
        return patches.map(levels)
    }

    private struct Patch {
        var mean: Float
        /// Sum of squared differences between horizontal and vertical neighbours.
        var gradient: Float
        var values: [Float]
    }

    /// Non-overlapping patches of one colour plane, normalised (black 0, white 1).
    private static func planePatches(_ image: DecodedImage, x0: Int, y0: Int) -> [Patch] {
        let side = patchSide
        let planeWidth = (image.width - x0) / 2
        let planeHeight = (image.height - y0) / 2
        let columns = planeWidth / side
        let rows = planeHeight / side
        guard columns > 0, rows > 0 else { return [] }
        let stride = max(1, Int((Double(columns * rows) / Double(patchesPerPlane)).squareRoot().rounded(.up)))
        let blackIndex = y0 * 2 + x0
        let black = image.blackLevels.isEmpty ? 0 : image.blackLevels[blackIndex % image.blackLevels.count]
        let scale = 1 / max(image.whiteLevel - black, 1)
        var result: [Patch] = []
        image.samples.withUnsafeBufferPointer { samples in
            for row in Swift.stride(from: 0, to: rows, by: stride) {
                for column in Swift.stride(from: 0, to: columns, by: stride) {
                    var values = [Float](repeating: 0, count: side * side)
                    var clipped = false
                    for j in 0 ..< side {
                        for i in 0 ..< side {
                            let x = x0 + 2 * (column * side + i)
                            let y = y0 + 2 * (row * side + j)
                            let value = (Float(samples[y * image.width + x]) - black) * scale
                            clipped = clipped || value >= 0.9
                            values[j * side + i] = value
                        }
                    }
                    guard !clipped else { continue }
                    var gradient: Float = 0
                    for j in 0 ..< side {
                        for i in 0 ..< side {
                            let v = values[j * side + i]
                            if i + 1 < side {
                                let d = values[j * side + i + 1] - v
                                gradient += d * d
                            }
                            if j + 1 < side {
                                let d = values[(j + 1) * side + i] - v
                                gradient += d * d
                            }
                        }
                    }
                    let mean = values.reduce(0, +) / Float(values.count)
                    result.append(Patch(mean: mean, gradient: gradient, values: values))
                }
            }
        }
        return result
    }

    /// Noise variance per brightness level from one colour's patches.
    private static func levels(_ patches: [Patch]) -> [Level] {
        var bins = [[Patch]](repeating: [], count: levelCount)
        for patch in patches where patch.mean > 0 {
            bins[min(Int(patch.mean / levelWidth), levelCount - 1)].append(patch)
        }
        var levels: [Level] = []
        for var bin in bins where bin.count >= minimumPatches {
            if bin.count > patchesPerLevel {
                let step = Double(bin.count) / Double(patchesPerLevel)
                bin = (0 ..< patchesPerLevel).map { bin[Int(Double($0) * step)] }
            }
            guard var variance = noiseVariance(bin) else { continue }
            var kept = bin
            for _ in 0 ..< 5 {
                let limit = weakTextureLimit * variance
                let weak = bin.filter { $0.gradient < limit }
                guard weak.count >= minimumPatches, let next = noiseVariance(weak) else { break }
                kept = weak
                let settled = abs(next - variance) < 0.01 * variance
                variance = next
                if settled {
                    break
                }
            }
            let mean = kept.map { Double($0.mean) }.reduce(0, +) / Double(kept.count)
            levels.append(Level(mean: mean, variance: Double(variance), tiles: Double(kept.count)))
        }
        return levels
    }

    /// The noise variance from the patches' covariance.
    private static func noiseVariance(_ patches: [Patch]) -> Float? {
        let n = patches.count
        let d = patchDimensions
        guard n > d else { return nil }
        var means = [Float](repeating: 0, count: d)
        for patch in patches {
            for k in 0 ..< d {
                means[k] += patch.values[k]
            }
        }
        for k in 0 ..< d {
            means[k] /= Float(n)
        }
        var centred = [Float](repeating: 0, count: n * d)
        for (row, patch) in patches.enumerated() {
            for k in 0 ..< d {
                centred[row * d + k] = patch.values[k] - means[k]
            }
        }
        // Covariance = Xᵀ X / (n - 1), with X the n x d centred patches.
        var transposed = [Float](repeating: 0, count: n * d)
        vDSP_mtrans(centred, 1, &transposed, 1, vDSP_Length(d), vDSP_Length(n))
        var product = [Float](repeating: 0, count: d * d)
        vDSP_mmul(transposed, 1, centred, 1, &product, 1, vDSP_Length(d), vDSP_Length(d), vDSP_Length(n))
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: d), count: d)
        for i in 0 ..< d {
            for j in 0 ..< d {
                matrix[i][j] = Double(product[i * d + j]) / Double(n - 1)
            }
        }
        let spectrum = eigenvalues(matrix)
        guard let smallest = spectrum.min(), smallest > 0 else { return nil }
        // Directions above the noise bulk's upper edge are texture; the rest set the correction.
        var ratio = Double(d) / Double(n)
        var noise = smallest / pow(1 - ratio.squareRoot(), 2)
        for _ in 0 ..< 3 {
            let upperEdge = noise * pow(1 + ratio.squareRoot(), 2) * 1.2
            let noiseDirections = spectrum.filter { $0 <= upperEdge }.count
            ratio = Double(noiseDirections) / Double(n)
            noise = smallest / pow(1 - ratio.squareRoot(), 2)
        }
        return Float(noise)
    }

    /// Cyclic Jacobi rotations on a small symmetric matrix.
    private static func eigenvalues(_ input: [[Double]]) -> [Double] {
        var a = input
        let n = a.count
        for _ in 0 ..< 30 {
            var off = 0.0
            for i in 0 ..< n {
                for j in i + 1 ..< n {
                    off += a[i][j] * a[i][j]
                }
            }
            if off < 1e-30 {
                break
            }
            for p in 0 ..< n {
                for q in p + 1 ..< n where abs(a[p][q]) > 1e-300 {
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let t = (theta >= 0 ? 1 : -1) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot()
                    let s = t * c
                    for k in 0 ..< n {
                        let akp = a[k][p]
                        let akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0 ..< n {
                        let apk = a[p][k]
                        let aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                }
            }
        }
        return (0 ..< n).map { a[$0][$0] }
    }
}
