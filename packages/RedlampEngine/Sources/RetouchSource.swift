import Foundation
import simd

/// Finds a source for a Heal or Clone spot (RM-01): every circle near the spot is tried, and the
/// one whose surroundings match the spot's best wins. The spot's own inside is the blemish, so
/// only its rim is compared, and a candidate busier inside than the spot's rim (another blemish,
/// an edge) is passed over. The search is exhaustive, not PatchMatch's randomised one.
enum RetouchSource {
    /// Log luma at one pyramid level, in sensor coordinates.
    struct Image {
        let width: Int
        let height: Int
        let values: [Float]

        func callAsFunction(_ x: Int, _ y: Int) -> Float {
            values[y * width + x]
        }
    }

    /// The spot's radius in the texels searched.
    static let searchRadius: Float = 8
    /// How far from the spot candidates go, in radii.
    static let reach: Float = 10
    /// The rim compared, as a multiple of the radius.
    static let rim: Float = 1.6
    /// The nearest a source's centre comes to the spot's, in radii: the circles don't overlap.
    static let separation: Float = 2.2

    /// The pyramid level that makes `radius` (level-0 texels) about `searchRadius` texels.
    static func level(radius: Float, levels: Int) -> Int {
        min(max(Int(floor(log2(max(radius / searchRadius, 1)))), 0), levels - 1)
    }

    /// The best source for a spot at `center` with `radius` (both in `image`'s texels), or nil
    /// when no circle fits. `matchBrightness` (Heal) compares texture only, since Heal takes
    /// brightness and colour from the rim anyway.
    static func search(
        _ image: Image, center: SIMD2<Float>, radius: Float, matchBrightness: Bool,
    ) -> SIMD2<Float>? {
        guard center.x.isFinite, center.y.isFinite, radius >= 1, radius < 1000 else { return nil }
        let outer = Int(ceil(radius * rim))
        let inner2 = radius * radius
        let outer2 = radius * rim * radius * rim
        var ring: [SIMD2<Int>] = []
        var inside: [SIMD2<Int>] = []
        for dy in -outer ... outer {
            for dx in -outer ... outer {
                let d2 = Float(dx * dx + dy * dy)
                if d2 >= inner2, d2 <= outer2 {
                    ring.append(SIMD2(dx, dy))
                } else if d2 < inner2 {
                    inside.append(SIMD2(dx, dy))
                }
            }
        }
        let cx = Int(floor(center.x)), cy = Int(floor(center.y))
        guard cx >= 0, cy >= 0, cx < image.width, cy < image.height else { return nil }
        func fits(_ x: Int, _ y: Int) -> Bool {
            x - outer >= 0 && y - outer >= 0 && x + outer < image.width && y + outer < image.height
        }
        // The spot's rim, keeping only the part inside the photo.
        let target = ring.filter { offset in
            let x = cx + offset.x, y = cy + offset.y
            return x >= 0 && y >= 0 && x < image.width && y < image.height
        }
        guard target.count >= ring.count / 4 else { return nil }
        let targetValues = target.map { image(cx + $0.x, cy + $0.y) }
        let targetMean = targetValues.reduce(0, +) / Float(targetValues.count)
        let texture = (targetValues.map { ($0 - targetMean) * ($0 - targetMean) }.reduce(0, +)
            / Float(targetValues.count)).squareRoot()

        let reachTexels = Int(ceil(radius * reach))
        let separation2 = radius * separation * radius * separation
        var best: (cost: Float, point: SIMD2<Int>)?
        for y in max(cy - reachTexels, 0) ... min(cy + reachTexels, image.height - 1) {
            for x in max(cx - reachTexels, 0) ... min(cx + reachTexels, image.width - 1) {
                let distance2 = Float((x - cx) * (x - cx) + (y - cy) * (y - cy))
                guard distance2 >= separation2, fits(x, y) else { continue }
                var sum: Float = 0
                var sum2: Float = 0
                var own: Float = 0
                var own2: Float = 0
                for (index, offset) in target.enumerated() {
                    let value = image(x + offset.x, y + offset.y)
                    let difference = value - targetValues[index]
                    sum += difference
                    sum2 += difference * difference
                    own += value
                    own2 += value * value
                }
                let count = Float(target.count)
                let shift = matchBrightness ? sum / count : 0
                // Two unrelated textures differ by twice their variance, a flat area and a texture
                // by once, so the difference alone would prefer flat sources: their textures'
                // strengths have to match as well, on the rim and inside.
                let ownMean = own / count
                let rimTexture = max(own2 / count - ownMean * ownMean, 0).squareRoot()
                var cost = sum2 / count - shift * shift
                cost += 2 * (rimTexture - texture) * (rimTexture - texture)
                if let best, cost >= best.cost {
                    continue
                }
                var insideSum: Float = 0
                var insideSum2: Float = 0
                for offset in inside {
                    let value = image(x + offset.x, y + offset.y)
                    insideSum += value
                    insideSum2 += value * value
                }
                let insideMean = insideSum / Float(inside.count)
                let insideTexture = max(insideSum2 / Float(inside.count) - insideMean * insideMean, 0).squareRoot()
                // Busier inside than the spot's surroundings is another blemish or an edge.
                let busier = max(insideTexture - texture, 0), calmer = max(texture - insideTexture, 0)
                cost += 2 * busier * busier + calmer * calmer
                // Nearer wins a tie.
                cost += 1e-5 * distance2.squareRoot() / radius
                if best.map({ cost < $0.cost }) ?? true {
                    best = (cost, SIMD2(x, y))
                }
            }
        }
        // Whole texels away, so the source keeps the spot's place within its texel.
        let fraction = center - SIMD2(Float(cx), Float(cy))
        return best.map { SIMD2(Float($0.point.x), Float($0.point.y)) + fraction }
    }
}
