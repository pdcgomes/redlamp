import Foundation
import RedlampEngineAPI
import simd

/// One measured color correspondence, both in Redlamp's display Rec.2020 (sRGB transfer).
public struct ProfileSample: Sendable {
    public var input: SIMD3<Float>
    public var target: SIMD3<Float>
    public var weight: Float

    public init(input: SIMD3<Float>, target: SIMD3<Float>, weight: Float = 1) {
        self.input = input
        self.target = target
        self.weight = weight
    }
}

/// Fits a look table to color samples: the smoothest table whose tetrahedral interpolation
/// (exactly what the GPU does) matches the samples.
///
/// It solves for the table's difference from an identity, with a second-difference
/// smoothness penalty along each axis, by conjugate gradients. Where there are no samples
/// the difference continues smoothly, so colors the cameras never showed stay sensible.
public enum LatticeFit {
    public static func fit(_ samples: [ProfileSample], size: Int = 25, smoothness: Float) -> LookTable {
        let n = size, nodes = n * n * n
        // Each sample's four nodes and tetrahedral weights.
        var indices = [Int32](repeating: 0, count: samples.count * 4)
        var weights = [Float](repeating: 0, count: samples.count * 4)
        var rhs = [SIMD3<Float>](repeating: .zero, count: nodes)
        var totalWeight: Float = 0
        for (s, sample) in samples.enumerated() {
            let (ids, ws) = tetrahedron(sample.input, size: n)
            for k in 0 ..< 4 {
                indices[s * 4 + k] = Int32(ids[k])
                weights[s * 4 + k] = ws[k]
                rhs[ids[k]] += ws[k] * sample.weight * (sample.target - sample.input)
            }
            totalWeight += sample.weight
        }
        // Scale the penalty with the data so the same `smoothness` means the same trade-off.
        let lambda = smoothness * totalWeight / Float(nodes)
        // First differences keep the correction from growing into colors no sample covers
        // (second differences alone would extend it linearly); the ridge fades it towards
        // no change far from the data.
        let membrane = 0.5 * lambda
        let ridge = 0.02 * lambda

        func apply(_ r: [SIMD3<Float>]) -> [SIMD3<Float>] {
            var out = [SIMD3<Float>](repeating: .zero, count: nodes)
            for (s, sample) in samples.enumerated() {
                var value = SIMD3<Float>.zero
                for k in 0 ..< 4 {
                    let weight: Float = weights[s * 4 + k]
                    let node = Int(indices[s * 4 + k])
                    value += weight * r[node]
                }
                value *= sample.weight
                for k in 0 ..< 4 {
                    let weight: Float = weights[s * 4 + k]
                    let node = Int(indices[s * 4 + k])
                    out[node] += weight * value
                }
            }
            for axisStride in [1, n, n * n] {
                for node in 0 ..< nodes {
                    let coordinate = (node / axisStride) % n
                    if coordinate < n - 1 {
                        let d1 = r[node + axisStride] - r[node]
                        out[node + axisStride] += membrane * d1
                        out[node] -= membrane * d1
                    }
                    guard coordinate > 0, coordinate < n - 1 else { continue }
                    let d = r[node - axisStride] - 2 * r[node] + r[node + axisStride]
                    out[node - axisStride] += lambda * d
                    out[node] -= 2 * lambda * d
                    out[node + axisStride] += lambda * d
                }
            }
            for node in 0 ..< nodes {
                out[node] += ridge * r[node]
            }
            return out
        }

        // Conjugate gradients on the normal equations; the three channels share the matrix.
        var x = [SIMD3<Float>](repeating: .zero, count: nodes)
        var r = rhs
        var p = r
        var rsOld = zip(r, r).reduce(SIMD3<Float>.zero) { $0 + $1.0 * $1.1 }
        for _ in 0 ..< 400 {
            let ap = apply(p)
            let pap = zip(p, ap).reduce(SIMD3<Float>.zero) { $0 + $1.0 * $1.1 }
            let alpha = rsOld / simd_max(pap, SIMD3(repeating: 1e-20))
            for i in 0 ..< nodes {
                x[i] += alpha * p[i]
                r[i] -= alpha * ap[i]
            }
            let rsNew = zip(r, r).reduce(SIMD3<Float>.zero) { $0 + $1.0 * $1.1 }
            if rsNew.max() < 1e-12 * max(totalWeight, 1) {
                break
            }
            let beta = rsNew / simd_max(rsOld, SIMD3(repeating: 1e-20))
            for i in 0 ..< nodes {
                p[i] = r[i] + beta * p[i]
            }
            rsOld = rsNew
        }

        let step = 1 / Float(n - 1)
        var values = [Float]()
        values.reserveCapacity(nodes * 3)
        for b in 0 ..< n {
            for g in 0 ..< n {
                for rr in 0 ..< n {
                    let identity = SIMD3(Float(rr), Float(g), Float(b)) * step
                    let value = simd_clamp(
                        identity + x[(b * n + g) * n + rr],
                        SIMD3(repeating: -0.2),
                        SIMD3(repeating: 1.2),
                    )
                    values += [value.x, value.y, value.z]
                }
            }
        }
        // Values are clamped into the table's valid range above, so this always validates.
        return (try? LookTable(size: n, floats: values)) ?? .identity(size: n)
    }

    /// The four nodes and weights tetrahedral interpolation uses for `c`.
    static func tetrahedron(_ c: SIMD3<Float>, size n: Int) -> ([Int], [Float]) {
        let p = simd_clamp(c, .zero, SIMD3(repeating: 1)) * Float(n - 1)
        let base = SIMD3<Int>(min(Int(p.x), n - 2), min(Int(p.y), n - 2), min(Int(p.z), n - 2))
        let f = p - SIMD3<Float>(Float(base.x), Float(base.y), Float(base.z))
        func index(_ dr: Int, _ dg: Int, _ db: Int) -> Int {
            ((base.z + db) * n + (base.y + dg)) * n + base.x + dr
        }
        let c000 = index(0, 0, 0), c111 = index(1, 1, 1)
        // The same six tetrahedra as LookTable.sample, written as barycentric weights.
        if f.x > f.y {
            if f.y > f.z {
                return ([c000, index(1, 0, 0), index(1, 1, 0), c111], [1 - f.x, f.x - f.y, f.y - f.z, f.z])
            } else if f.x > f.z {
                return ([c000, index(1, 0, 0), index(1, 0, 1), c111], [1 - f.x, f.x - f.z, f.z - f.y, f.y])
            } else {
                return ([c000, index(0, 0, 1), index(1, 0, 1), c111], [1 - f.z, f.z - f.x, f.x - f.y, f.y])
            }
        }
        if f.z > f.y {
            return ([c000, index(0, 0, 1), index(0, 1, 1), c111], [1 - f.z, f.z - f.y, f.y - f.x, f.x])
        } else if f.z > f.x {
            return ([c000, index(0, 1, 0), index(0, 1, 1), c111], [1 - f.y, f.y - f.z, f.z - f.x, f.x])
        }
        return ([c000, index(0, 1, 0), index(1, 1, 0), c111], [1 - f.y, f.y - f.x, f.x - f.z, f.z])
    }

    /// Mean and 90th-percentile OKLab ΔE × 100 between a table's output (nil for no look)
    /// and the targets.
    public static func error(_ table: LookTable?, _ samples: [ProfileSample]) -> (mean: Double, p90: Double) {
        guard !samples.isEmpty else { return (0, 0) }
        var errors = samples.map { sample -> Double in
            let output = table?.sample(sample.input) ?? sample.input
            let a = ColorMath.rec2020ToOKLab(ColorMath.srgbDecode(simd_max(output, .zero)))
            let b = ColorMath.rec2020ToOKLab(ColorMath.srgbDecode(simd_max(sample.target, .zero)))
            return Double(simd_distance(a, b)) * 100
        }
        errors.sort()
        return (errors.reduce(0, +) / Double(errors.count), errors[min(errors.count - 1, errors.count * 9 / 10)])
    }
}
