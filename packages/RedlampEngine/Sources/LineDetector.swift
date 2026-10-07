import Foundation
import RedlampColor
import RedlampEngineAPI
import simd

/// Straight edges for automatic Upright (LNS-07), by line-support regions (Burns, Hanson and
/// Riseman, "Extracting Straight Lines", 1986): neighbouring pixels whose gradients point the
/// same way, within 22.5°, grow into a region, and a region long and thin enough is a line,
/// fitted through its pixels weighted by gradient strength.
enum LineDetector {
    /// The analysis image's luma, EXIF-oriented, as the square root of linear light so edges
    /// in shadows and highlights weigh alike.
    struct Image {
        let width: Int
        let height: Int
        let values: [Float]
    }

    static let angleTolerance: Float = 22.5 * .pi / 180
    /// Gradients below this (in square-root luma per pixel) are noise or flat.
    static let minimumGradient: Float = 0.012
    /// In analysis pixels.
    static let minimumLength: Float = 20
    /// Region pixels per pixel of the fitted rectangle: below it, the region is a blob, not a line.
    static let minimumDensity: Float = 0.6

    static func lines(in session: ImageSession) -> [DetectedLine] {
        lines(in: image(session))
    }

    static func image(_ session: ImageSession) -> Image {
        let analysis = session.analysis
        let swaps = [5, 6].contains(session.orientation)
        let (width, height) = swaps ? (analysis.height, analysis.width) : (analysis.width, analysis.height)
        let weights = Luma.rec2020
        var values = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let oriented = SIMD2((Double(x) + 0.5) / Double(width), (Double(y) + 0.5) / Double(height))
                let source = sourceCoordinate(oriented, orientation: session.orientation)
                let pixel = analysis.pixel(
                    x: Int(source.x * Double(analysis.width)), y: Int(source.y * Double(analysis.height)),
                )
                values[y * width + x] = max(simd_dot(pixel, weights), 0).squareRoot()
            }
        }
        return Image(width: width, height: height, values: values)
    }

    static func lines(in image: Image) -> [DetectedLine] {
        let (width, height) = (image.width, image.height)
        guard width >= 8, height >= 8 else { return [] }
        // A light blur first: the 3x3 binomial, so pixel noise doesn't break regions apart.
        var smooth = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                var sum: Float = 0
                for dy in -1 ... 1 {
                    for dx in -1 ... 1 {
                        let v = image.values[min(max(y + dy, 0), height - 1) * width + min(max(x + dx, 0), width - 1)]
                        sum += v * Float((dx == 0 ? 2 : 1) * (dy == 0 ? 2 : 1))
                    }
                }
                smooth[y * width + x] = sum / 16
            }
        }
        // Gradients on the 2x2 cell below and right of each pixel; the edge runs across them.
        var magnitude = [Float](repeating: 0, count: width * height)
        var angle = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height - 1 {
            for x in 0 ..< width - 1 {
                let a = smooth[y * width + x], b = smooth[y * width + x + 1]
                let c = smooth[(y + 1) * width + x], d = smooth[(y + 1) * width + x + 1]
                let gx = (b + d - a - c) / 2, gy = (c + d - a - b) / 2
                magnitude[y * width + x] = (gx * gx + gy * gy).squareRoot()
                // The edge's own direction, which keeps which side is brighter.
                angle[y * width + x] = atan2(gx, -gy)
            }
        }
        // Seeds strongest first.
        let order = (0 ..< width * height).filter { magnitude[$0] >= minimumGradient }
            .sorted { magnitude[$0] > magnitude[$1] }
        var used = [Bool](repeating: false, count: width * height)
        var found: [DetectedLine] = []
        var region: [Int] = []
        for seed in order where !used[seed] {
            region.removeAll(keepingCapacity: true)
            region.append(seed)
            used[seed] = true
            var direction = SIMD2(cos(angle[seed]), sin(angle[seed]))
            var regionAngle = angle[seed]
            var next = 0
            while next < region.count {
                let index = region[next]
                next += 1
                let (x, y) = (index % width, index / width)
                for dy in -1 ... 1 {
                    for dx in -1 ... 1 where dx != 0 || dy != 0 {
                        let (nx, ny) = (x + dx, y + dy)
                        guard nx >= 0, ny >= 0, nx < width - 1, ny < height - 1 else { continue }
                        let neighbour = ny * width + nx
                        guard !used[neighbour], magnitude[neighbour] >= minimumGradient else { continue }
                        let difference = abs(remainder(angle[neighbour] - regionAngle, 2 * .pi))
                        guard difference <= angleTolerance else { continue }
                        used[neighbour] = true
                        region.append(neighbour)
                        direction += SIMD2(cos(angle[neighbour]), sin(angle[neighbour]))
                        regionAngle = atan2(direction.y, direction.x)
                    }
                }
            }
            if let line = fit(region, width: width, height: height, magnitude: magnitude) {
                found.append(line)
            }
        }
        return found
    }

    /// The region's principal axis, weighted by gradient strength, and its extent along it.
    private static func fit(_ region: [Int], width: Int, height: Int, magnitude: [Float]) -> DetectedLine? {
        guard Float(region.count) >= minimumLength else { return nil }
        var total: Float = 0
        var centre = SIMD2<Float>.zero
        for index in region {
            let w = magnitude[index]
            // The cell's centre, half a pixel right and down.
            centre += w * SIMD2(Float(index % width) + 1, Float(index / width) + 1)
            total += w
        }
        centre /= total
        var (xx, xy, yy): (Float, Float, Float) = (0, 0, 0)
        for index in region {
            let w = magnitude[index]
            let d = SIMD2(Float(index % width) + 1, Float(index / width) + 1) - centre
            xx += w * d.x * d.x
            xy += w * d.x * d.y
            yy += w * d.y * d.y
        }
        // The larger eigenvector of the inertia matrix.
        let theta = 0.5 * atan2(2 * xy, xx - yy)
        let axis = SIMD2(cos(theta), sin(theta))
        let normal = SIMD2(-axis.y, axis.x)
        var (low, high, nearest, farthest): (Float, Float, Float, Float) = (
            .infinity,
            -.infinity,
            .infinity,
            -.infinity,
        )
        for index in region {
            let d = SIMD2(Float(index % width) + 1, Float(index / width) + 1) - centre
            let along = simd_dot(d, axis), across = simd_dot(d, normal)
            low = min(low, along)
            high = max(high, along)
            nearest = min(nearest, across)
            farthest = max(farthest, across)
        }
        let length = high - low + 1
        let thickness = farthest - nearest + 1
        guard length >= minimumLength, Float(region.count) / (length * thickness) >= minimumDensity,
              length >= 4 * thickness
        else { return nil }
        let start = centre + low * axis, end = centre + high * axis
        func point(_ p: SIMD2<Float>) -> ImagePoint {
            ImagePoint(x: Double(p.x) / Double(width), y: Double(p.y) / Double(height))
        }
        let contrast = total / Float(region.count)
        return DetectedLine(
            line: GuideLine(start: point(start), end: point(end)),
            strength: Double(length * min(contrast / (4 * minimumGradient), 1)),
        )
    }
}
