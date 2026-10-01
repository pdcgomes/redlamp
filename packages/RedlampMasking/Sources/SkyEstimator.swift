import CoreGraphics
import Foundation
import RedlampEngineAPI
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
        let width = region.width
        let height = region.height
        // Distance from the region's edge, in work pixels (two-pass chamfer).
        var distance = region.sky.map { $0 ? Int.max / 2 : 0 }
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
            if best.index >= 0, best.distance >= 6 {
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
