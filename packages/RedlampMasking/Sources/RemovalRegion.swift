import CoreGraphics
import Foundation
import RedlampEngineAPI
import simd

/// What a removed person or object takes with it (RM-13): its cast shadow and its reflection,
/// found beside and below its mask, so that removing it leaves neither behind.
///
/// A shadow touches the thing and is darker than the ground around it, in about the same colour
/// or a cooler one: in sunlight a shadow is lit by the sky alone. A reflection is the thing's mirror image
/// below its lowest point, kept as deep as the photo there takes on the thing's colour against
/// what lies beside it, as water does, rippled or not, and ground doesn't. Both are classical
/// estimates on the mask's grid; open instance-shadow models may follow under DEC-24.
public enum RemovalRegion {
    public struct Extended: Sendable {
        /// The thing's mask with its shadow and reflection.
        public var mask: GrayMask
        public var shadow: Bool
        public var reflection: Bool
    }

    /// Shadow is at most this fraction of the ground's luminance around it.
    static let shadowDarkness: Float = 0.6
    /// And its chromaticity at most this far from the ground's, unless it's a cooler version of it.
    static let shadowChroma: Float = 0.06
    /// It reaches at most this many of the thing's sizes from it, on the ground: no higher than
    /// `shadowFloor` of the way down the thing.
    static let shadowReach = 0.5
    static let shadowFloor = 0.75
    /// A reflection's colour lies at least this share of the way from what's beside it to the
    /// thing's, averaged over `reflectionRows` rows.
    static let reflectionShare: Float = 0.3
    static let reflectionRows = 5
    /// It works on a grid at most this many pixels on its long side.
    static let workSide = 1024

    /// `mask`, a removed thing's, with its shadow and reflection in `image` (any size; resampled to
    /// the mask's).
    public static func extended(_ mask: GrayMask, image: CGImage) -> Extended {
        let unchanged = Extended(mask: mask, shadow: false, reflection: false)
        let scale = min(1, Double(workSide) / Double(max(mask.width, mask.height)))
        let work = scale < 1 ? mask.resized(to: PixelSize(
            width: max(Int(Double(mask.width) * scale), 1), height: max(Int(Double(mask.height) * scale), 1),
        )) : mask
        let (width, height) = (work.width, work.height)
        guard width > 8, height > 8, let rgb = pixels(image, width: width, height: height) else { return unchanged }
        let object = largestPiece(work.coverage.map { $0 > 0.5 }, width: width, height: height)
        var (low, high) = (SIMD2(width, height), SIMD2(-1, -1))
        for y in 0 ..< height {
            for x in 0 ..< width where object[y * width + x] {
                low = simd_min(low, SIMD2(x, y))
                high = simd_max(high, SIMD2(x, y))
            }
        }
        guard high.x >= low.x else { return unchanged }
        let size = max(high.x - low.x + 1, high.y - low.y + 1)
        let luminance = rgb.map { simd_dot($0, SIMD3(0.2126, 0.7152, 0.0722)) }
        let chroma = rgb.map { $0 / max($0.x + $0.y + $0.z, 1e-4) }

        let shadow = shadowPixels(
            object: object, luminance: luminance, chroma: chroma, width: width, height: height, size: size,
            floor: low.y + Int(Double(high.y - low.y) * shadowFloor),
        ).flatMap { cast($0, width: width, low: low, high: high, size: size) }
        let reflection = reflectionPixels(object: object, rgb: rgb, width: width, height: height, low: low, high: high)
        guard shadow != nil || reflection != nil else { return unchanged }
        var added = [Float](repeating: 0, count: width * height)
        for index in added.indices where shadow?[index] == true || reflection?[index] == true {
            added[index] = 1
        }
        var soft = GrayMask(width: width, height: height, coverage: added).blurred(radius: 1)
        if soft.width != mask.width || soft.height != mask.height {
            soft = soft.resized(to: PixelSize(width: mask.width, height: mask.height))
        }
        let coverage = zip(mask.coverage, soft.coverage).map { max($0, $1) }
        return Extended(
            mask: GrayMask(width: mask.width, height: mask.height, coverage: coverage), shadow: shadow != nil,
            reflection: reflection != nil,
        )
    }

    /// The largest eight-connected piece of `region`: stray pixels a mask holds away from the thing
    /// would stretch its extent.
    static func largestPiece(_ region: [Bool], width: Int, height: Int) -> [Bool] {
        var label = [Int32](repeating: -1, count: region.count)
        var (best, most, next): (Int32, Int, Int32) = (-1, 0, 0)
        var stack: [Int] = []
        for start in region.indices where region[start] && label[start] < 0 {
            label[start] = next
            stack.append(start)
            var count = 0
            while let index = stack.popLast() {
                count += 1
                let (x, y) = (index % width, index / width)
                for ny in max(y - 1, 0) ... min(y + 1, height - 1) {
                    for nx in max(x - 1, 0) ... min(x + 1, width - 1) where region[ny * width + nx] {
                        let neighbour = ny * width + nx
                        guard label[neighbour] < 0 else { continue }
                        label[neighbour] = next
                        stack.append(neighbour)
                    }
                }
            }
            if count > most {
                (best, most) = (next, count)
            }
            next += 1
        }
        return label.map { $0 == best }
    }

    /// The darker ground in the thing's colour that touches it, or nil for none worth taking.
    static func shadowPixels(
        object: [Bool], luminance: [Float], chroma: [SIMD3<Float>], width: Int, height: Int, size: Int, floor: Int,
    ) -> [Bool]? {
        let reach = max(2, Int(Double(size) * shadowReach))
        let near = dilated(object, width: width, height: height, radius: reach)
            .enumerated().map { $0.element && $0.offset / width >= floor }
        // The ground around: what isn't the thing, then again without the first pass's shadow.
        var excluded = object
        var candidates = [Bool](repeating: false, count: width * height)
        for _ in 0 ..< 2 {
            let weight = excluded.map { $0 ? Float(0) : 1 }
            let radius = max(4, size / 2)
            let total = BoxFilter.blur(weight, width: width, height: height, radius: radius)
            let ground = BoxFilter.blur(zip(luminance, weight).map(*), width: width, height: height, radius: radius)
            let tint = (0 ..< 3).map { channel in
                BoxFilter.blur(
                    zip(chroma, weight).map { $0[channel] * $1 }, width: width, height: height, radius: radius,
                )
            }
            for index in candidates.indices {
                let sum = max(total[index], 1e-4)
                let around = SIMD3(tint[0][index], tint[1][index], tint[2][index]) / sum
                let colour = chroma[index]
                let cooler = colour.z >= around.z && colour.x <= around.x + 0.02
                candidates[index] = near[index] && !object[index]
                    && luminance[index] < shadowDarkness * ground[index] / sum
                    && (simd_length(colour - around) < shadowChroma || cooler)
            }
            excluded = zip(object, candidates).map { $0 || $1 }
        }
        // Only what reaches the thing, through itself.
        var shadow = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        for index in candidates.indices where candidates[index] {
            let (x, y) = (index % width, index / width)
            let touches = [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { dx, dy in
                let (nx, ny) = (x + dx, y + dy)
                return nx >= 0 && ny >= 0 && nx < width && ny < height && object[ny * width + nx]
            }
            if touches {
                shadow[index] = true
                stack.append(index)
            }
        }
        while let index = stack.popLast() {
            let (x, y) = (index % width, index / width)
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let (nx, ny) = (x + dx, y + dy)
                guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                let next = ny * width + nx
                if candidates[next], !shadow[next] {
                    shadow[next] = true
                    stack.append(next)
                }
            }
        }
        let area = shadow.filter(\.self).count
        guard area > max(object.filter(\.self).count / 50, 4) else { return nil }
        // A shadow ends: past its edge the ground goes on lit. Darker ground that goes on (water
        // under a boat, a dark road) has an edge that's no darker than what's beyond it.
        var (edge, lit) = (0, 0)
        for index in shadow.indices where shadow[index] {
            let (x, y) = (index % width, index / width)
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let (nx, ny) = (x + dx, y + dy)
                guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                let next = ny * width + nx
                guard !shadow[next], !object[next] else { continue }
                edge += 1
                lit += luminance[next] > luminance[index] * 1.05 ? 1 : 0
            }
        }
        guard edge > 0, Double(lit) / Double(edge) > 0.5 else { return nil }
        // Close the speckle a shadow over texture leaves.
        let closed = BoxFilter.blur(shadow.map { $0 ? Float(1) : 0 }, width: width, height: height, radius: 2)
        return zip(closed, near).map { $0 > 0.4 && $1 }
    }

    /// What of `shadow` the thing casts, as far as its colour and brightness can't tell: what lies
    /// on the ground around its base, up to a quarter of its width beyond either end and a third of
    /// its size below it. Another thing's shade it touches (a wall's) is as dark and as blue, so
    /// it's bounded rather than told apart.
    static func cast(_ shadow: [Bool], width: Int, low: SIMD2<Int>, high: SIMD2<Int>, size: Int) -> [Bool]? {
        let beyond = (high.x - low.x + 1) / 4
        let (left, right) = (low.x - beyond, high.x + beyond)
        let bottom = high.y + Int(Double(size) * 0.35)
        let kept = shadow.indices.map { index in
            let (x, y) = (index % width, index / width)
            return shadow[index] && x >= left && x <= right && y <= bottom
        }
        return kept.contains(true) ? kept : nil
    }

    /// The thing mirrored below its lowest point, as deep as the photo there takes on the thing's
    /// colour against what lies beside it, or nil.
    static func reflectionPixels(
        object: [Bool], rgb: [SIMD3<Float>], width: Int, height: Int, low: SIMD2<Int>, high: SIMD2<Int>,
    ) -> [Bool]? {
        let bottom = high.y
        let depth = min(bottom - low.y + 1, height - 1 - bottom)
        guard depth > 4 else { return nil }
        var (thing, count) = (SIMD3<Float>.zero, Float(0))
        for index in object.indices where object[index] {
            thing += rgb[index]
            count += 1
        }
        thing /= max(count, 1)
        let span = low.x ... high.x
        let flank = max(span.count / 4, 4)
        var (shares, reach): ([Float], Int) = ([], 0)
        for y in bottom + 1 ... bottom + depth {
            let source = 2 * bottom - y + 1
            var (mirror, mirrored, beside, besides) = (SIMD3<Float>.zero, Float(0), SIMD3<Float>.zero, Float(0))
            for x in max(low.x - flank, 0) ... min(high.x + flank, width - 1) {
                if !span.contains(x) {
                    beside += rgb[y * width + x]
                    besides += 1
                } else if object[source * width + x] {
                    mirror += rgb[y * width + x]
                    mirrored += 1
                }
            }
            guard besides >= 4 else { break }
            guard mirrored >= 4 else { continue }
            let water = beside / besides
            let away = thing - water
            let distance = simd_dot(away, away)
            guard distance > 1e-4 else { break }
            shares.append(simd_dot(mirror / mirrored - water, away) / distance)
            let recent = shares.suffix(reflectionRows)
            guard recent.reduce(0, +) / Float(recent.count) >= reflectionShare else { break }
            reach = y - bottom
        }
        guard reach > max(4, (high.y - low.y + 1) / 10) else { return nil }
        var region = [Bool](repeating: false, count: width * height)
        for y in bottom + 1 ... bottom + reach {
            let source = 2 * bottom - y + 1
            for x in span where object[source * width + x] {
                region[y * width + x] = true
            }
        }
        return dilated(region, width: width, height: height, radius: max(2, span.count / 50))
    }

    /// `region` grown by `radius` pixels: what a box of that radius around a pixel of it reaches.
    /// The box's running sums leave a residue far below one pixel's share, down whole columns.
    static func dilated(_ region: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        let share = 0.5 / Float((2 * radius + 1) * (2 * radius + 1))
        return BoxFilter.blur(region.map { $0 ? Float(1) : 0 }, width: width, height: height, radius: radius)
            .map { $0 > share }
    }

    /// `image` as linear RGB at `width` × `height`.
    static func pixels(_ image: CGImage, width: Int, height: Int) -> [SIMD3<Float>]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
              )
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        func linear(_ value: UInt8) -> Float {
            let v = Float(value) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return (0 ..< width * height).map { index in
            SIMD3(linear(bytes[index * 4]), linear(bytes[index * 4 + 1]), linear(bytes[index * 4 + 2]))
        }
    }
}
