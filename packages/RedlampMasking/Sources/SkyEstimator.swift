import CoreGraphics
import Foundation
import RedlampEngineAPI
import simd
import Vision

/// The interim Sky mask, until the bake-off (tracker MSK-17) picks a model: a classical estimate.
///
/// Sky is bright, smooth and, where it isn't overcast, bluer than it is red; it reaches the top
/// of the frame. Candidate pixels are grown from the top edge as one connected region, then
/// snapped to the photo's edges with a guided filter. Vision's image classifier (which has no
/// sky *mask*, only labels) confirms there is sky at all. Good on clear and evenly overcast
/// skies; tree lines and hair are where a trained model will do better.
public enum SkyEstimator {
    static let workLongEdge = 512

    public static func estimate(_ image: CGImage) throws -> ProvidedMask {
        let region = try region(image)
        let rough = GrayMask(width: region.width, height: region.height, pixels: region.sky.map { $0 ? 255 : 0 })
        let stored = rough.blurred(radius: 1).resized(to: PixelSize(width: image.width, height: image.height).fitted(
            within: PixelSize(width: VisionMaskProvider.partsLongEdge, height: VisionMaskProvider.partsLongEdge),
        ))
        return ProvidedMask(
            kind: .sky, provider: "redlamp.skyEstimate", revision: 1,
            mask: GuidedFilter.refine(stored, guide: image, radius: 8, epsilon: 2e-3),
        )
    }

    /// Points well inside the estimated sky, spread across it: prompts for a segmentation model
    /// (the auto-prompted Segment Anything candidate of the bake-off).
    public static func seeds(_ image: CGImage, count: Int = 4) throws -> [ImagePoint] {
        let region = try region(image)
        return try seeds(inside: region.sky, width: region.width, height: region.height, count: count, depth: 6)
    }

    /// Segment Anything's and Depth Anything 3's skies as one: averaged where they broadly agree,
    /// but when one covers under 30% of the other's sky it has missed the sky (Depth Anything 3
    /// on some overcast skies, Segment Anything on a patch it wasn't seeded in), and the other
    /// stands alone. A plain mean would leave such a sky half covered, with no sure sky for
    /// `SkyMatte` to learn its colour from.
    public static func arbitrate(_ sam: GrayMask, _ da3: GrayMask) -> GrayMask {
        let da3 = da3.resized(to: PixelSize(width: sam.width, height: sam.height))
        let samArea = sam.pixels.count { $0 > 127 }
        let da3Area = da3.pixels.count { $0 > 127 }
        if Double(da3Area) < 0.3 * Double(samArea) {
            return sam
        }
        if Double(samArea) < 0.3 * Double(da3Area) {
            return da3
        }
        return GrayMask(
            width: sam.width, height: sam.height,
            pixels: zip(sam.pixels, da3.pixels).map { UInt8((Int($0) + Int($1)) / 2) },
        )
    }

    /// Points well inside another model's sky (Depth Anything 3's), for when the classical
    /// estimate finds none: a small patch between buildings is too little for it.
    public static func seeds(inside mask: GrayMask, count: Int = 4) throws -> [ImagePoint] {
        let size = PixelSize(width: mask.width, height: mask.height)
            .fitted(within: PixelSize(width: workLongEdge, height: workLongEdge))
        let small = mask.resized(to: size)
        return try seeds(
            inside: small.pixels.map { $0 > 200 }, width: size.width, height: size.height, count: count, depth: 3,
        )
    }

    /// The deepest point of `region` in each of `count` vertical bands, if at least `depth` work
    /// pixels from its edge.
    static func seeds(inside region: [Bool], width: Int, height: Int, count: Int, depth: Int) throws -> [ImagePoint] {
        // Distance from the region's edge, in work pixels (two-pass chamfer).
        var distance = region.map { $0 ? Int.max / 2 : 0 }
        for y in 0 ..< height {
            for x in 0 ..< width where distance[y * width + x] > 0 {
                let up = y > 0 ? distance[(y - 1) * width + x] + 1 : 1
                let left = x > 0 ? distance[y * width + x - 1] + 1 : 1
                distance[y * width + x] = min(distance[y * width + x], up, left)
            }
        }
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in stride(from: width - 1, through: 0, by: -1) where distance[y * width + x] > 0 {
                let down = y < height - 1 ? distance[(y + 1) * width + x] + 1 : 1
                let right = x < width - 1 ? distance[y * width + x + 1] + 1 : 1
                distance[y * width + x] = min(distance[y * width + x], down, right)
            }
        }
        var points: [ImagePoint] = []
        for band in 0 ..< count {
            let x0 = band * width / count
            let x1 = (band + 1) * width / count
            var best = (distance: 0, index: -1)
            for y in 0 ..< height {
                for x in x0 ..< x1 where distance[y * width + x] > best.distance {
                    best = (distance[y * width + x], y * width + x)
                }
            }
            if best.index >= 0, best.distance >= depth {
                points.append(ImagePoint(
                    x: (Double(best.index % width) + 0.5) / Double(width),
                    y: (Double(best.index / width) + 0.5) / Double(height),
                ))
            }
        }
        guard !points.isEmpty else { throw MaskComputationError.nothingFound(.sky) }
        return points
    }

    /// The sky as a connected region grown from the top edge, at the work size.
    static func region(_ image: CGImage) throws -> (sky: [Bool], width: Int, height: Int) {
        let size = PixelSize(width: image.width, height: image.height)
            .fitted(within: PixelSize(width: workLongEdge, height: workLongEdge))
        guard let pixels = RGBImage(image, size: size) else { throw MaskComputationError.nothingFound(.sky) }
        let width = size.width
        let height = size.height
        let luma = (0 ..< width * height).map { index -> Float in
            let rgb = pixels.rgb(index % width, index / width)
            return 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
        }
        let texture = BoxFilter.blur(
            gradient(luma, width: width, height: height),
            width: width,
            height: height,
            radius: 2,
        )

        // The sky's own brightness: the brightest smooth band along the top.
        let topRows = max(1, height / 12)
        let topLuma = (0 ..< topRows * width).filter { texture[$0] < 0.04 }.map { luma[$0] }.sorted()
        guard !topLuma.isEmpty else { throw MaskComputationError.nothingFound(.sky) }
        let reference = topLuma[topLuma.count / 2]

        var candidate = [Bool](repeating: false, count: width * height)
        for index in candidate.indices {
            let rgb = pixels.rgb(index % width, index / width)
            let smooth = texture[index] < 0.05
            let bright = luma[index] > max(0.25, reference * 0.55)
            let skyColored = rgb.z >= rgb.x * 0.92
            candidate[index] = smooth && bright && skyColored
        }

        // Grown from the top edge, four-connected.
        var sky = [Bool](repeating: false, count: width * height)
        var stack = (0 ..< width).filter { candidate[$0] }
        for index in stack {
            sky[index] = true
        }
        while let index = stack.popLast() {
            let x = index % width
            let y = index / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && nx < width && ny >= 0 && ny < height {
                let next = ny * width + nx
                if candidate[next], !sky[next] {
                    sky[next] = true
                    stack.append(next)
                }
            }
        }
        // Next to branches and roofs the sky isn't smooth, only sky-coloured: grow into that rim.
        for _ in 0 ..< 4 {
            var grown = sky
            for index in sky.indices where !sky[index] {
                let x = index % width
                let y = index / width
                let touches = (x > 0 && sky[index - 1]) || (x < width - 1 && sky[index + 1])
                    || (y > 0 && sky[index - width]) || (y < height - 1 && sky[index + width])
                guard touches else { continue }
                let rgb = pixels.rgb(x, y)
                grown[index] = luma[index] > max(0.25, reference * 0.6) && rgb.z >= rgb.x * 0.95
            }
            sky = grown
        }
        let fraction = Double(sky.count(where: \.self)) / Double(sky.count)
        guard fraction > 0.02, hasSkyLabel(image) || fraction > 0.15 else {
            throw MaskComputationError.nothingFound(.sky)
        }
        return (sky, width, height)
    }

    /// Gives back the sky a segmentation model leaves out between bare branches. Segment Anything
    /// treats a leafless crown as one object and cuts around it, so a darkened sky would keep
    /// bright patches inside every bare tree. This learns the sky's colour where the mask is sure
    /// (per band of rows, as skies brighten towards the horizon), then adds pixels of that colour
    /// above the sky's lowest reach in each column, connected to it, with a soft falloff so pixels
    /// mixed with thin branches get partial coverage. Measured in the bake-off (MSK-17): IoU 0.920
    /// to 0.940, boundary F 0.894 to 0.918.
    public static func refineBetweenBranches(
        _ mask: GrayMask, image: CGImage, tolerance: Float = 0.09, reach: Double = 0.04,
    ) -> GrayMask {
        let width = mask.width
        let height = mask.height
        guard let pixels = RGBImage(image, size: PixelSize(width: width, height: height)) else { return mask }
        let sky = mask.coverage
        let lab = (0 ..< width * height).map { Self.oklab(sRGB: pixels.rgb($0 % width, $0 / width)) }
        let sure = sky.map { $0 > 0.9 }
        guard sure.count(where: \.self) >= 100 else { return mask }

        // A reference colour per band of rows, from the sure sky there or the nearest band with some.
        let bands = 16
        let band = { (y: Int) in min(y * bands / height, bands - 1) }
        var buckets = [[SIMD3<Float>]](repeating: [], count: bands)
        for index in sure.indices where sure[index] {
            buckets[band(index / width)].append(lab[index])
        }
        var references: [SIMD3<Float>?] = buckets.map { samples in
            guard samples.count > 50 else { return nil }
            return SIMD3(Self.median(samples.map(\.x)), Self.median(samples.map(\.y)), Self.median(samples.map(\.z)))
        }
        let filled = references.indices.filter { references[$0] != nil }
        guard !filled.isEmpty else { return mask }
        for b in references.indices where references[b] == nil {
            references[b] = references[filled.min { abs($0 - b) < abs($1 - b) }!]
        }
        let match: [Float] = lab.indices.map { index in
            let reference = references[band(index / width)]!
            let d = (lab[index] - reference) * SIMD3(0.6, 1, 1)
            let distance = simd_length(d)
            return 1 - min(max((distance - tolerance * 0.4) / (tolerance * 0.6), 0), 1)
        }

        // Where crowns can be: above the lowest sure sky in each column, widened across nearby
        // columns and smoothed, plus a little reach below it.
        var lowest = (0 ..< width).map { x -> Float in
            let rows = (0 ..< height).reversed()
            return Float(rows.first { sure[$0 * width + x] } ?? 0)
        }
        lowest = Self.maximum(lowest, window: max(3, width / 20))
        lowest = Self.mean(lowest, window: max(3, width / 40))
        let limit = Float(reach) * Float(height)
        let allowed = { (index: Int) in Float(index / width) <= lowest[index % width] + limit }

        // Grown from the sky through matching pixels, four-connected.
        let passable = (0 ..< width * height).map { (allowed($0) && match[$0] > 0.3) || sky[$0] > 0.5 }
        var connected = [Bool](repeating: false, count: width * height)
        var stack = (0 ..< width * height).filter { sky[$0] > 0.5 }
        for index in stack {
            connected[index] = true
        }
        while let index = stack.popLast() {
            let x = index % width
            for next in [x > 0 ? index - 1 : -1, x < width - 1 ? index + 1 : -1, index - width, index + width]
                where next >= 0 && next < width * height && passable[next] && !connected[next] {
                connected[next] = true
                stack.append(next)
            }
        }
        let refined = sky.indices.map { index in
            connected[index] && allowed(index) ? max(sky[index], match[index]) : sky[index]
        }
        return GrayMask(width: width, height: height, coverage: refined)
    }

    /// OKLab (Björn Ottosson, 2020) of an sRGB-encoded colour.
    static func oklab(sRGB c: SIMD3<Float>) -> SIMD3<Float> {
        func linear(_ v: Float) -> Float {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = linear(c.x)
        let g = linear(c.y)
        let b = linear(c.z)
        let l = cbrt(max(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 0))
        let m = cbrt(max(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 0))
        let s = cbrt(max(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 0))
        return SIMD3(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
        )
    }

    static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Sliding maximum and mean over `window` neighbours, clamped at the ends.
    static func maximum(_ values: [Float], window: Int) -> [Float] {
        values.indices.map { index in
            let range = max(index - window / 2, 0) ... min(index + window / 2, values.count - 1)
            return values[range].max() ?? values[index]
        }
    }

    static func mean(_ values: [Float], window: Int) -> [Float] {
        values.indices.map { index in
            let range = max(index - window / 2, 0) ... min(index + window / 2, values.count - 1)
            return values[range].reduce(0, +) / Float(range.count)
        }
    }

    /// Central-difference gradient magnitude.
    static func gradient(_ values: [Float], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: values.count)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let left = values[y * width + max(x - 1, 0)]
                let right = values[y * width + min(x + 1, width - 1)]
                let up = values[max(y - 1, 0) * width + x]
                let down = values[min(y + 1, height - 1) * width + x]
                out[y * width + x] = hypot(right - left, down - up) / 2
            }
        }
        return out
    }

    /// Whether Vision's classifier labels the photo with any kind of sky.
    static func hasSkyLabel(_ image: CGImage) -> Bool {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return false }
        return (request.results ?? []).contains { observation in
            observation.identifier.contains("sky") && observation.confidence > 0.1
        }
    }
}
