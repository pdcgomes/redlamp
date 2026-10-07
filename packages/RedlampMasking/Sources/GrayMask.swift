import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI

/// An 8-bit coverage map in mask space (the oriented frame): 0 none, 255 full.
public struct GrayMask: Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel count must match the size")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, coverage: [Float]) {
        self.init(
            width: width, height: height,
            pixels: coverage.map { UInt8((min(max($0, 0), 1) * 255).rounded()) },
        )
    }

    public var coverage: [Float] {
        pixels.map { Float($0) / 255 }
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        pixels[y * width + x]
    }

    /// The share of the frame covered (0...1).
    public var coveredFraction: Double {
        pixels.reduce(0.0) { $0 + Double($1) } / (255 * Double(max(pixels.count, 1)))
    }

    /// The coverage-weighted centre, for the mask's pin.
    public var centroid: ImagePoint {
        var sum = SIMD2<Double>.zero
        var total = 0.0
        for y in 0 ..< height {
            for x in 0 ..< width {
                let weight = Double(pixels[y * width + x])
                guard weight > 0 else { continue }
                sum += SIMD2(Double(x) + 0.5, Double(y) + 0.5) * weight
                total += weight
            }
        }
        guard total > 0 else { return ImagePoint(x: 0.5, y: 0.5) }
        return ImagePoint(x: sum.x / total / Double(width), y: sum.y / total / Double(height))
    }

    public var inverted: GrayMask {
        GrayMask(width: width, height: height, pixels: pixels.map { 255 - $0 })
    }

    /// Bilinear resampling to `size`.
    public func resized(to size: PixelSize) -> GrayMask {
        guard size.width != width || size.height != height else { return self }
        var out = [UInt8](repeating: 0, count: size.width * size.height)
        let sx = Double(width) / Double(size.width)
        let sy = Double(height) / Double(size.height)
        let (width, height, pixels) = (width, height, pixels)
        // Each row writes only its own pixels.
        out.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let result = buffer
            DispatchQueue.concurrentPerform(iterations: size.height) { y in
                let fy = min(max((Double(y) + 0.5) * sy - 0.5, 0), Double(height - 1))
                let y0 = Int(fy)
                let y1 = min(y0 + 1, height - 1)
                let ty = fy - Double(y0)
                for x in 0 ..< size.width {
                    let fx = min(max((Double(x) + 0.5) * sx - 0.5, 0), Double(width - 1))
                    let x0 = Int(fx)
                    let x1 = min(x0 + 1, width - 1)
                    let tx = fx - Double(x0)
                    let top = Double(pixels[y0 * width + x0]) * (1 - tx) + Double(pixels[y0 * width + x1]) * tx
                    let bottom = Double(pixels[y1 * width + x0]) * (1 - tx) + Double(pixels[y1 * width + x1]) * tx
                    result[y * size.width + x] = UInt8((top * (1 - ty) + bottom * ty).rounded())
                }
            }
        }
        return GrayMask(width: size.width, height: size.height, pixels: out)
    }

    /// Resized so the long edge is at most `longEdge`, keeping the aspect ratio.
    public func fitted(longEdge: Int) -> GrayMask {
        resized(to: PixelSize(width: width, height: height).fitted(within: PixelSize(
            width: longEdge,
            height: longEdge,
        )))
    }

    /// Per pixel: the larger (union) of two masks of the same size.
    public func union(_ other: GrayMask) -> GrayMask {
        let other = other.resized(to: PixelSize(width: width, height: height))
        return GrayMask(width: width, height: height, pixels: zip(pixels, other.pixels).map { max($0, $1) })
    }

    public func intersection(_ other: GrayMask) -> GrayMask {
        let other = other.resized(to: PixelSize(width: width, height: height))
        return GrayMask(
            width: width, height: height,
            pixels: zip(pixels, other.pixels).map { UInt8((Int($0) * Int($1) + 127) / 255) },
        )
    }

    public func subtracting(_ other: GrayMask) -> GrayMask {
        intersection(other.inverted)
    }

    /// This mask cut between `people` (masks of this size), one piece each, in their order: each
    /// pixel goes to the person nearest it (city-block distance from where they cover more than
    /// half), so hair beyond a person's own mask is still theirs; what is more than `reach`
    /// pixels from everyone (someone Vision didn't find) is no one's. With no one, all of it is
    /// the first's.
    public func split(among people: [GrayMask], reach: Int = .max) -> [GrayMask] {
        guard !people.isEmpty else { return [] }
        let count = width * height
        var owner = [Int8](repeating: -1, count: count)
        var queue = [Int32]()
        queue.reserveCapacity(count)
        for index in 0 ..< count {
            var best = -1
            var strongest: UInt8 = 127
            for (person, mask) in people.enumerated() where mask.pixels[index] > strongest {
                (best, strongest) = (person, mask.pixels[index])
            }
            if best >= 0 {
                owner[index] = Int8(best)
                queue.append(Int32(index))
            }
        }
        guard !queue.isEmpty else {
            let none = GrayMask(width: width, height: height, pixels: [UInt8](repeating: 0, count: count))
            return [self] + people.dropFirst().map { _ in none }
        }
        func claim(_ next: Int, by person: Int8) {
            if owner[next] < 0 {
                owner[next] = person
                queue.append(Int32(next))
            }
        }
        // Breadth first, a ring of one more pixel's distance at a time.
        var head = 0
        var distance = 0
        while head < queue.count, distance < reach {
            let ring = queue.count
            while head < ring {
                let index = Int(queue[head])
                head += 1
                let x = index % width
                let person = owner[index]
                if x > 0 {
                    claim(index - 1, by: person)
                }
                if x < width - 1 {
                    claim(index + 1, by: person)
                }
                if index >= width {
                    claim(index - width, by: person)
                }
                if index + width < count {
                    claim(index + width, by: person)
                }
            }
            distance += 1
        }
        return people.indices.map { person in
            var piece = [UInt8](repeating: 0, count: count)
            for index in 0 ..< count where owner[index] == person {
                piece[index] = pixels[index]
            }
            return GrayMask(width: width, height: height, pixels: piece)
        }
    }

    /// A box blur of `radius` pixels, twice (close to a Gaussian), to feather drawn shapes.
    public func blurred(radius: Int) -> GrayMask {
        guard radius > 0 else { return self }
        var values = coverage
        for _ in 0 ..< 2 {
            values = BoxFilter.blur(values, width: width, height: height, radius: radius)
        }
        return GrayMask(width: width, height: height, coverage: values)
    }

    /// Feather and Edge, as an AI mask's sliders set them: Edge (-100...100) moves the edge out
    /// or in by up to `reach` pixels, Feather (0...100) softens it over about twice that. The mask
    /// is blurred (twice a box of half the larger reach, so a straight edge ramps over twice it),
    /// then cut at a level Edge moves from the middle, as sharply as Feather allows. At 0 and 0 it
    /// is the mask itself.
    ///
    /// Stray hairs and soft wisps blur to almost nothing and fall below the cut, so with
    /// `keepingDetail` (process 14) only the mask's body is shaped, what a grey opening keeps
    /// (`detailRadius`), and the rest is added back: whole for Feather and an outward Edge, faded
    /// by an inward Edge's share. On hair_bench's heads at Feather 50, 48% of strands are kept
    /// against 35%, with less background taken in (`edge_feather.py`, MSK-31).
    public func shaped(feather: Double, edge: Double, reach: Int, keepingDetail: Bool = false) -> GrayMask {
        guard feather != 0 || edge != 0, reach > 0 else { return self }
        guard keepingDetail else { return shapedWhole(feather: feather, edge: edge, reach: reach) }
        let values = coverage
        let body = Self.opening(values, width: width, height: height, radius: detailRadius)
        let shapedBody = GrayMask(width: width, height: height, coverage: body)
            .shapedWhole(feather: feather, edge: edge, reach: reach).coverage
        let gain = Float(1 - min(max(-edge, 0), 100) / 100)
        return GrayMask(width: width, height: height, coverage: values.indices.map {
            min(shapedBody[$0] + (values[$0] - body[$0]) * gain, 1)
        })
    }

    /// The widest detail Feather and Edge leave as it is, either side of its centre: 3 px at the
    /// size AI masks are stored at (4096 on the long side), less in smaller masks.
    var detailRadius: Int {
        max(1, Int((3 * Double(max(width, height)) / 4096).rounded()))
    }

    private func shapedWhole(feather: Double, edge: Double, reach: Int) -> GrayMask {
        let featherReach = min(max(feather, 0), 100) / 100 * Double(reach)
        let edgeReach = min(abs(edge), 100) / 100 * Double(reach)
        let larger = max(featherReach, edgeReach)
        let blurred = blurred(radius: max(Int((larger / 2).rounded()), 1)).coverage
        let softness = Float(max(0.5 * featherReach / larger, 0.02))
        let level = min(max(Float(0.5 - min(max(edge, -100), 100) / 200 * edgeReach / larger), softness), 1 - softness)
        return GrayMask(width: width, height: height, coverage: blurred.map { value in
            let t = min(max((value - (level - softness)) / (2 * softness), 0), 1)
            return t * t * (3 - 2 * t)
        })
    }

    /// A grey opening by a square `2 * radius + 1` px wide: erosion (the least value around), then
    /// dilation (the most), each as a row pass and a column pass, in parallel.
    static func opening(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        func pass(_ input: [Float], along rows: Bool, keep: @escaping @Sendable (Float, Float) -> Float) -> [Float] {
            var output = input
            Parallel.fill(&output) { index in
                let (x, y) = (index % width, index / width)
                let (position, length) = rows ? (x, width) : (y, height)
                var value = input[index]
                for offset in max(0, position - radius) ... min(length - 1, position + radius) {
                    value = keep(value, input[rows ? y * width + offset : offset * width + x])
                }
                return value
            }
            return output
        }
        let eroded = pass(pass(values, along: true, keep: min), along: false, keep: min)
        return pass(pass(eroded, along: true, keep: max), along: false, keep: max)
    }

    /// Rotates or flips a mask stored in a file's native orientation into the oriented frame
    /// (EXIF orientation codes 1-8).
    public func oriented(exif orientation: Int) -> GrayMask {
        guard orientation > 1, orientation <= 8 else { return self }
        let swaps = orientation >= 5
        let outWidth = swaps ? height : width
        let outHeight = swaps ? width : height
        var out = [UInt8](repeating: 0, count: pixels.count)
        for y in 0 ..< outHeight {
            for x in 0 ..< outWidth {
                let (sx, sy): (Int, Int) = switch orientation {
                case 2: (width - 1 - x, y)
                case 3: (width - 1 - x, height - 1 - y)
                case 4: (x, height - 1 - y)
                case 5: (y, x)
                case 6: (y, height - 1 - x)
                case 7: (width - 1 - y, height - 1 - x)
                default: (width - 1 - y, x)
                }
                out[y * outWidth + x] = pixels[sy * width + sx]
            }
        }
        return GrayMask(width: outWidth, height: outHeight, pixels: out)
    }

    // MARK: - PNG

    public static func decode(_ png: Data) -> GrayMask? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return GrayMask(image)
    }

    /// Any image, drawn as grayscale.
    public init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue,
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }

    public var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
        )
    }

    public func pngData() -> Data? {
        let data = NSMutableData()
        guard let image = cgImage,
              let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The bitmap an edit stores: this mask as a PNG, with its content hash.
    public func bitmap() -> MaskBitmap? {
        pngData().map { MaskBitmap(png: $0, width: width, height: height) }
    }
}

/// Box filters through running sums, O(1) per pixel whatever the radius.
public enum BoxFilter {
    /// The mean over a (2r+1)² window, clamped at the edges.
    public static func blur(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        guard radius > 0, width > 0, height > 0 else { return values }
        var rows = [Float](repeating: 0, count: values.count)
        for y in 0 ..< height {
            var sum: Float = 0
            let base = y * width
            for x in -radius ... radius {
                sum += values[base + min(max(x, 0), width - 1)]
            }
            for x in 0 ..< width {
                rows[base + x] = sum / Float(2 * radius + 1)
                sum += values[base + min(x + radius + 1, width - 1)] - values[base + max(x - radius, 0)]
            }
        }
        var out = [Float](repeating: 0, count: values.count)
        for x in 0 ..< width {
            var sum: Float = 0
            for y in -radius ... radius {
                sum += rows[min(max(y, 0), height - 1) * width + x]
            }
            for y in 0 ..< height {
                out[y * width + x] = sum / Float(2 * radius + 1)
                sum += rows[min(y + radius + 1, height - 1) * width + x] - rows[max(y - radius, 0) * width + x]
            }
        }
        return out
    }
}

/// The guided filter (He, Sun and Tang, ECCV 2010) with a grayscale guide: snaps a soft mask's
/// edges to the photo's edges. Freedom-to-operate is pending (tracker DEC-05).
public enum GuidedFilter {
    /// `mask` and `guide` are the same size; `epsilon` is in the guide's units squared.
    public static func filter(
        _ mask: [Float], guide: [Float], width: Int, height: Int, radius: Int, epsilon: Float,
    ) -> [Float] {
        let (a, b) = coefficients(mask, guide: guide, width: width, height: height, radius: radius, epsilon: epsilon)
        return mask.indices.map { min(max(a[$0] * guide[$0] + b[$0], 0), 1) }
    }

    /// The filter's two coefficients per pixel, each averaged over its window: the output is
    /// `a * guide + b`. Computed on a small map, they can be applied to a larger guide (K. He &
    /// J. Sun, "Fast guided filter", 2015).
    public static func coefficients(
        _ input: [Float], guide: [Float], width: Int, height: Int, radius: Int, epsilon: Float,
    ) -> (a: [Float], b: [Float]) {
        let meanI = BoxFilter.blur(guide, width: width, height: height, radius: radius)
        let meanP = BoxFilter.blur(input, width: width, height: height, radius: radius)
        let corrI = BoxFilter.blur(zip(guide, guide).map(*), width: width, height: height, radius: radius)
        let corrIP = BoxFilter.blur(zip(guide, input).map(*), width: width, height: height, radius: radius)
        var a = [Float](repeating: 0, count: input.count)
        var b = [Float](repeating: 0, count: input.count)
        for index in input.indices {
            let variance = corrI[index] - meanI[index] * meanI[index]
            let covariance = corrIP[index] - meanI[index] * meanP[index]
            a[index] = covariance / (variance + epsilon)
            b[index] = meanP[index] - a[index] * meanI[index]
        }
        return (
            BoxFilter.blur(a, width: width, height: height, radius: radius),
            BoxFilter.blur(b, width: width, height: height, radius: radius),
        )
    }

    /// Refines `mask` against the luminance of `image` (any size; resampled to the mask's).
    public static func refine(
        _ mask: GrayMask,
        guide image: CGImage,
        radius: Int = 6,
        epsilon: Float = 1e-3,
    ) -> GrayMask {
        guard let guide = GrayMask(image)?.resized(to: PixelSize(width: mask.width, height: mask.height)) else {
            return mask
        }
        let refined = filter(
            mask.coverage, guide: guide.coverage, width: mask.width, height: mask.height, radius: radius,
            epsilon: epsilon,
        )
        return GrayMask(width: mask.width, height: mask.height, coverage: refined)
    }
}
