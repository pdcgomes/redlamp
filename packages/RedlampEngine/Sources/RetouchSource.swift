import Foundation
import simd

/// Finds a source for a Heal or Clone spot (RM-01): every place near the spot is tried, and the
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
    /// The nearest the source's shape comes to the spot's, centre to centre, in radii: they don't overlap.
    static let separation: Float = 2.2

    /// The pyramid level that makes `radius` (level-0 texels) about `searchRadius` texels.
    static func level(radius: Float, levels: Int) -> Int {
        min(max(Int(floor(log2(max(radius / searchRadius, 1)))), 0), levels - 1)
    }

    /// The most rim and inside texels compared per candidate; more are thinned evenly.
    static let maximumSamples = 3000

    /// The best source for a spot at `center` with `radius` (both in `image`'s texels), or nil
    /// when none fits. `stroke` is a brushed spot's stroke after `center`, relative to it.
    /// `matchBrightness` (Heal) compares texture only, since Heal takes brightness and colour
    /// from the rim anyway.
    static func search(
        _ image: Image, center: SIMD2<Float>, radius: Float, stroke: [SIMD2<Float>] = [], matchBrightness: Bool,
    ) -> SIMD2<Float>? {
        guard center.x.isFinite, center.y.isFinite, radius >= 1, radius < 1000,
              stroke.allSatisfy({ $0.x.isFinite && $0.y.isFinite && simd_reduce_max(simd_abs($0)) < 1e5 })
        else { return nil }
        let shape = [SIMD2<Float>(0, 0)] + stroke
        func distance(_ point: SIMD2<Float>) -> Float {
            var nearest = simd_length(point - shape[0])
            for index in shape.indices.dropFirst() {
                let a = shape[index - 1], ab = shape[index] - a
                let t = min(max(simd_dot(point - a, ab) / max(simd_length_squared(ab), 1e-6), 0), 1)
                nearest = min(nearest, simd_length(point - (a + ab * t)))
            }
            return nearest
        }
        let low = shape.dropFirst().reduce(shape[0], simd_min) - radius * rim
        let high = shape.dropFirst().reduce(shape[0], simd_max) + radius * rim
        let minimum = SIMD2(Int(floor(low.x)), Int(floor(low.y)))
        let maximum = SIMD2(Int(ceil(high.x)), Int(ceil(high.y)))
        var ring: [SIMD2<Int>] = []
        var inside: [SIMD2<Int>] = []
        for dy in minimum.y ... maximum.y {
            for dx in minimum.x ... maximum.x {
                let d = distance(SIMD2(Float(dx), Float(dy)))
                if d >= radius, d <= radius * rim {
                    ring.append(SIMD2(dx, dy))
                } else if d < radius {
                    inside.append(SIMD2(dx, dy))
                }
            }
        }
        func thinned(_ offsets: [SIMD2<Int>]) -> [SIMD2<Int>] {
            guard offsets.count > maximumSamples else { return offsets }
            let stride = Double(offsets.count) / Double(maximumSamples)
            return (0 ..< maximumSamples).map { offsets[Int(Double($0) * stride)] }
        }
        ring = thinned(ring)
        inside = thinned(inside)
        guard !inside.isEmpty else { return nil }
        let cx = Int(floor(center.x)), cy = Int(floor(center.y))
        guard cx >= 0, cy >= 0, cx < image.width, cy < image.height else { return nil }
        func fits(_ x: Int, _ y: Int) -> Bool {
            x + minimum.x >= 0 && y + minimum.y >= 0 && x + maximum.x < image.width && y + maximum.y < image.height
        }
        // The spot's rim, keeping only the part inside the photo.
        let target = ring.filter { offset in
            let x = cx + offset.x, y = cy + offset.y
            return x >= 0 && y >= 0 && x < image.width && y < image.height
        }
        guard target.count >= ring.count / 4 else { return nil }
        let targetValues = target.map { image(cx + $0.x, cy + $0.y) }
        // How strong the texture around the spot is, without the thin things crossing its rim (twigs,
        // wires, the scratch itself running on), which a median absolute deviation ignores.
        let median = targetValues.sorted()[targetValues.count / 2]
        let background = 1.4826 * targetValues.map { abs($0 - median) }.sorted()[targetValues.count / 2]

        let reachTexels = Int(ceil(radius * reach))
        let overlaps = overlapping(shape, radius: radius, reach: reachTexels)
        let side = 2 * reachTexels + 1
        var best: (cost: Float, point: SIMD2<Int>)?
        for y in max(cy - reachTexels, 0) ... min(cy + reachTexels, image.height - 1) {
            for x in max(cx - reachTexels, 0) ... min(cx + reachTexels, image.width - 1) {
                let distance2 = Float((x - cx) * (x - cx) + (y - cy) * (y - cy))
                guard !overlaps[(y - cy + reachTexels) * side + x - cx + reachTexels], fits(x, y) else { continue }
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
                cost += 2 * (rimTexture - background) * (rimTexture - background)
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
                let busier = max(insideTexture - background, 0), calmer = max(background - insideTexture, 0)
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

    /// Which moves of the shape, within `reach` texels each way, bring it within `separation`
    /// radii of itself: a move by the difference of any two of its points, give or take that.
    private static func overlapping(_ shape: [SIMD2<Float>], radius: Float, reach: Int) -> [Bool] {
        var points = [shape[0]]
        for next in shape.dropFirst() {
            let last = points[points.count - 1]
            let steps = max(Int(ceil(simd_distance(last, next) / (radius / 2))), 1)
            for step in 1 ... steps {
                points.append(last + (next - last) * Float(step) / Float(steps))
            }
        }
        var differences = Set<SIMD2<Int>>()
        for a in points {
            for b in points {
                let d = b - a
                differences.insert(SIMD2(Int(d.x.rounded()), Int(d.y.rounded())))
            }
        }
        let side = 2 * reach + 1
        let clearance = radius * separation
        let extent = Int(ceil(clearance))
        var overlaps = [Bool](repeating: false, count: side * side)
        for difference in differences {
            for dy in -extent ... extent {
                let y = difference.y + dy + reach
                guard y >= 0, y < side else { continue }
                for dx in -extent ... extent where Float(dx * dx + dy * dy) < clearance * clearance {
                    let x = difference.x + dx + reach
                    if x >= 0, x < side {
                        overlaps[y * side + x] = true
                    }
                }
            }
        }
        return overlaps
    }
}
