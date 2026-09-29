import Foundation

/// The combined parametric + point tone curve, in display-referred (gamma-encoded) space.
///
/// Lives in the API so the engine's LUT and the UI's curve graph are the same function.
public enum ToneCurveMath {
    public static let lutSize = 1024

    /// Samples the full curve at `count` evenly spaced inputs over 0...1.
    public static func lut(for recipe: EditRecipe, count: Int = lutSize) -> [Float] {
        let point = pointCurve(recipe.pointCurve)
        var samples = [Float](repeating: 0, count: count)
        var previous = 0.0
        for index in 0 ..< count {
            let x = Double(index) / Double(count - 1)
            let y = point(parametric(x, recipe: recipe))
            previous = max(previous, min(max(y, 0), 1))
            samples[index] = Float(previous)
        }
        return samples
    }

    public static func isIdentity(_ recipe: EditRecipe) -> Bool {
        !recipe.hasPointCurve && [
            ParameterID.curveHighlights, .curveLights, .curveDarks, .curveShadows,
        ].allSatisfy { recipe.isDefault($0) }
    }

    /// The parametric curve: four region sliders shift the curve within regions bounded by
    /// the three split points.
    public static func parametric(_ x: Double, recipe: EditRecipe) -> Double {
        let s1 = recipe[.curveSplitShadows] / 100
        let s2 = recipe[.curveSplitMidtones] / 100
        let s3 = recipe[.curveSplitHighlights] / 100
        let regions: [(amount: Double, lower: Double, upper: Double, strength: Double)] = [
            (recipe[.curveShadows], 0, s1, 0.12),
            (recipe[.curveDarks], s1, s2, 0.16),
            (recipe[.curveLights], s2, s3, 0.16),
            (recipe[.curveHighlights], s3, 1, 0.12),
        ]
        var shift = 0.0
        for region in regions where region.amount != 0 {
            let centre = (region.lower + region.upper) / 2
            let halfWidth = max(region.upper - region.lower, 0.05)
            let distance = abs(x - centre) / halfWidth
            guard distance < 1 else { continue }
            let weight = pow(cos(distance * .pi / 2), 2)
            shift += region.amount / 100 * region.strength * weight
        }
        let envelope = smoothstep(0, 0.06, x) * smoothstep(1, 0.94, x)
        return x + shift * envelope
    }

    /// Monotone cubic (Fritsch–Carlson) interpolation through the point curve.
    public static func pointCurve(_ points: [CurvePoint]) -> (Double) -> Double {
        let sorted = points.sorted { $0.x < $1.x }
        guard sorted.count >= 2 else { return { $0 } }
        if sorted == EditRecipe.linearPointCurve {
            return { $0 }
        }

        let xs = sorted.map(\.x)
        let ys = sorted.map(\.y)
        let n = xs.count
        var slopes = [Double](repeating: 0, count: n - 1)
        for i in 0 ..< n - 1 {
            let dx = max(xs[i + 1] - xs[i], 1e-6)
            slopes[i] = (ys[i + 1] - ys[i]) / dx
        }
        var tangents = [Double](repeating: 0, count: n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for i in 1 ..< n - 1 {
            tangents[i] = slopes[i - 1] * slopes[i] <= 0 ? 0 : (slopes[i - 1] + slopes[i]) / 2
        }
        for i in 0 ..< n - 1 where slopes[i] != 0 {
            let a = tangents[i] / slopes[i]
            let b = tangents[i + 1] / slopes[i]
            let magnitude = a * a + b * b
            if magnitude > 9 {
                let scale = 3 / sqrt(magnitude)
                tangents[i] = scale * a * slopes[i]
                tangents[i + 1] = scale * b * slopes[i]
            }
        }

        return { x in
            if x <= xs[0] {
                return ys[0]
            }
            if x >= xs[n - 1] {
                return ys[n - 1]
            }
            var i = 0
            while i < n - 2, x > xs[i + 1] {
                i += 1
            }
            let h = xs[i + 1] - xs[i]
            let t = (x - xs[i]) / h
            let t2 = t * t
            let t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            return h00 * ys[i] + h10 * h * tangents[i] + h01 * ys[i + 1] + h11 * h * tangents[i + 1]
        }
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
