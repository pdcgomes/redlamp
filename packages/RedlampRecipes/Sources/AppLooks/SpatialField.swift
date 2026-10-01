import CoreGraphics
import Foundation
import simd

/// A smooth per-channel field over an image: bilinear on a coarse grid, fitted to scattered
/// samples with a thin-plate-like second-difference penalty, so it follows a vignette or a
/// light leak and interpolates smoothly where there are no samples.
struct GainField: Sendable {
    let columns: Int
    let rows: Int
    let width: Float
    let height: Float
    var nodes: [SIMD3<Float>]

    struct Sample {
        var position: SIMD2<Float>
        var value: SIMD3<Float>
        var weight: Float = 1
    }

    func value(at p: SIMD2<Float>) -> SIMD3<Float> {
        let (ids, ws) = cell(p)
        return ws[0] * nodes[ids[0]] + ws[1] * nodes[ids[1]] + ws[2] * nodes[ids[2]] + ws[3] * nodes[ids[3]]
    }

    private func cell(_ p: SIMD2<Float>) -> ([Int], [Float]) {
        let gx = min(max(p.x / width, 0), 1) * Float(columns - 1)
        let gy = min(max(p.y / height, 0), 1) * Float(rows - 1)
        let x0 = min(Int(gx), columns - 2), y0 = min(Int(gy), rows - 2)
        let fx = gx - Float(x0), fy = gy - Float(y0)
        let i = y0 * columns + x0
        return (
            [i, i + 1, i + columns, i + columns + 1],
            [(1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy],
        )
    }

    /// Fits the field, then refits twice with outlying samples (dust, text, a watermark)
    /// down-weighted.
    static func fit(
        _ samples: [Sample],
        width: Float,
        height: Float,
        spacing: Float = 64,
        smoothness: Float = 0.02,
    ) -> GainField {
        let columns = max(4, Int((width / spacing).rounded()) + 1)
        let rows = max(4, Int((height / spacing).rounded()) + 1)
        var field = GainField(columns: columns, rows: rows, width: width, height: height, nodes: [])
        var samples = samples
        let start = median(samples.map(\.value))
        field.nodes = [SIMD3<Float>](repeating: start, count: columns * rows)
        for pass in 0 ..< 3 {
            if pass > 0 {
                let residuals = samples.map { simd_length($0.value - field.value(at: $0.position)) }
                let scale = max(1.4826 * median(residuals), 0.004)
                for i in samples.indices {
                    let r = residuals[i] / (3 * scale)
                    samples[i].weight = r < 1 ? 1 : 1 / (r * r)
                }
            }
            field.solve(samples, smoothness: smoothness, start: field.nodes)
        }
        return field
    }

    private mutating func solve(_ samples: [Sample], smoothness: Float, start: [SIMD3<Float>]) {
        let count = columns * rows
        let cells = samples.map { cell($0.position) }
        let totalWeight = samples.reduce(Float(0)) { $0 + $1.weight }
        let lambda = smoothness * totalWeight / Float(count)
        let columns = columns, rows = rows
        func apply(_ x: [SIMD3<Float>]) -> [SIMD3<Float>] {
            var out = [SIMD3<Float>](repeating: .zero, count: count)
            for (s, sample) in samples.enumerated() {
                let (ids, ws) = cells[s]
                let v = (ws[0] * x[ids[0]] + ws[1] * x[ids[1]] + ws[2] * x[ids[2]] + ws[3] * x[ids[3]]) * sample.weight
                for k in 0 ..< 4 {
                    out[ids[k]] += ws[k] * v
                }
            }
            for (stride, extent) in [(1, columns), (columns, rows)] {
                for node in 0 ..< count {
                    let coordinate = stride == 1 ? node % columns : node / columns
                    guard coordinate > 0, coordinate < extent - 1 else { continue }
                    let d = x[node - stride] - 2 * x[node] + x[node + stride]
                    out[node - stride] += lambda * d
                    out[node] -= 2 * lambda * d
                    out[node + stride] += lambda * d
                }
            }
            for node in 0 ..< count {
                out[node] += 1e-4 * lambda * x[node]
            }
            return out
        }
        var rhs = [SIMD3<Float>](repeating: .zero, count: count)
        for (s, sample) in samples.enumerated() {
            let (ids, ws) = cells[s]
            for k in 0 ..< 4 {
                rhs[ids[k]] += ws[k] * sample.weight * sample.value
            }
        }
        for node in 0 ..< count {
            rhs[node] += 1e-4 * lambda * start[node]
        }
        nodes = ConjugateGradient.solve(apply, rhs: rhs, start: start, iterations: 3 * count)
    }
}

enum ConjugateGradient {
    /// Solves `apply(x) = rhs` for a symmetric positive definite `apply`, three channels at once.
    static func solve(
        _ apply: ([SIMD3<Float>]) -> [SIMD3<Float>],
        rhs: [SIMD3<Float>],
        start: [SIMD3<Float>],
        iterations: Int,
    ) -> [SIMD3<Float>] {
        var x = start
        let ax = apply(x)
        var r = zip(rhs, ax).map { $0 - $1 }
        var p = r
        var rsOld = dot(r, r)
        let tolerance = max(dot(rhs, rhs).max() * 1e-14, 1e-20)
        for _ in 0 ..< iterations {
            let ap = apply(p)
            let alpha = rsOld / simd_max(dot(p, ap), SIMD3(repeating: 1e-20))
            for i in x.indices {
                x[i] += alpha * p[i]
                r[i] -= alpha * ap[i]
            }
            let rsNew = dot(r, r)
            if rsNew.max() < tolerance {
                break
            }
            let beta = rsNew / simd_max(rsOld, SIMD3(repeating: 1e-20))
            for i in p.indices {
                p[i] = r[i] + beta * p[i]
            }
            rsOld = rsNew
        }
        return x
    }

    private static func dot(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> SIMD3<Float> {
        zip(a, b).reduce(SIMD3<Float>.zero) { $0 + $1.0 * $1.1 }
    }
}

// MARK: - Vignette

/// Redlamp's post-crop vignette (`Develop.metal`) with roundness 0, so the parameters a
/// measured field maps to.
public struct VignetteModel: Codable, Sendable, Hashable {
    /// -100...100, as the slider.
    public var amount: Double
    public var midpoint: Double
    public var feather: Double

    public init(amount: Double, midpoint: Double = 50, feather: Double = 50) {
        self.amount = amount
        self.midpoint = midpoint
        self.feather = feather
    }

    /// The shader's falloff at normalised radius `d` (0 at the centre, 1 at an edge's middle).
    public static func falloff(_ d: Float, midpoint: Float, feather: Float) -> Float {
        let start = 0.15 + (1.25 - 0.15) * midpoint
        let width = 0.02 + (1.1 - 0.02) * feather
        return ColorMath.smoothstep(start - width / 2, start + width / 2, d)
    }

    /// The factor the shader applies to an encoded value `e` at radius `d`.
    public func gain(_ d: Float, encoded e: Float) -> Float {
        let v = Float(amount / 100)
        let s = Self.falloff(d, midpoint: Float(midpoint / 100), feather: Float(feather / 100))
        return v < 0 ? 1 + v * s : (e + (1 - e) * v * s) / max(e, 1e-4)
    }

    /// Normalised radius of `p` in `frame`, following the frame's aspect.
    public static func radius(_ p: SIMD2<Float>, in frame: CGRect) -> Float {
        let q = SIMD2(
            (p.x - Float(frame.minX)) / Float(frame.width),
            (p.y - Float(frame.minY)) / Float(frame.height),
        ) * 2 - 1
        return simd_length(q)
    }

    /// The best model for gains measured at radii, on a grey whose centre value is `level`.
    /// Only shapes that leave the centre untouched are tried, since the field is normalised
    /// there.
    static func fit(_ points: [(radius: Float, gain: Float)], level: Float) -> (model: VignetteModel, rms: Float) {
        var best = (model: VignetteModel(amount: 0, midpoint: 50, feather: 50), rms: Float.infinity)
        for mi in 0 ... 20 {
            for fi in 0 ... 20 {
                let m = Float(mi) / 20, f = Float(fi) / 20
                let start = 0.15 + 1.1 * m, width = 0.02 + 1.08 * f
                guard start - width / 2 >= 0 else { continue }
                var ss: Float = 0, sg: Float = 0
                let falloffs = points.map { falloff($0.radius, midpoint: m, feather: f) }
                for (s, point) in zip(falloffs, points) {
                    ss += s * s
                    sg += s * (point.gain - 1)
                }
                guard ss > 1e-6 else { continue }
                let k = sg / ss
                let rms = (zip(falloffs, points).reduce(Float(0)) {
                    let e = 1 + k * $1.0 - $1.1.gain
                    return $0 + e * e
                } / Float(points.count)).squareRoot()
                if rms < best.rms {
                    var v = k < 0 ? max(k, -1) : min(k * level / max(1 - level, 0.05), 1)
                    if abs(v) < 0.005 {
                        v = 0
                    }
                    best = (VignetteModel(
                        amount: Double(v * 100),
                        midpoint: Double(m * 100),
                        feather: Double(f * 100),
                    ), rms)
                }
            }
        }
        return best
    }
}

// MARK: - Statistics

func median(_ values: [Float]) -> Float {
    guard !values.isEmpty else { return 0 }
    var sorted = values
    sorted.sort()
    let mid = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

func median(_ values: [SIMD3<Float>]) -> SIMD3<Float> {
    SIMD3(median(values.map(\.x)), median(values.map(\.y)), median(values.map(\.z)))
}

func percentile(_ values: [Float], _ p: Float) -> Float {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Float(sorted.count - 1) * p + 0.5))]
}

extension PixelImage {
    /// Pixels whose centres fall inside `rect`, clipped to the image.
    func pixels(in rect: CGRect) -> [SIMD3<Float>] {
        let x0 = max(0, Int((rect.minX - 0.5).rounded(.up))), x1 = min(width - 1, Int((rect.maxX - 0.5).rounded(.down)))
        let y0 = max(0, Int((rect.minY - 0.5).rounded(.up))), y1 = min(
            height - 1,
            Int((rect.maxY - 0.5).rounded(.down)),
        )
        guard x0 <= x1, y0 <= y1 else { return [] }
        var result: [SIMD3<Float>] = []
        result.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
        for y in y0 ... y1 {
            for x in x0 ... x1 {
                result.append(self[x, y])
            }
        }
        return result
    }

    func contains(_ rect: CGRect) -> Bool {
        rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= CGFloat(width) && rect.maxY <= CGFloat(height)
    }
}
