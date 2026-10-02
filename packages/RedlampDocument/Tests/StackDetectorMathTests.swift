import Foundation
import Testing
@testable import RedlampDocument

/// The Accelerate versions of the focus-signature maths against plain loops.
struct StackDetectorMathTests {
    private let thumbnail: StackDetector.Thumbnail = {
        var generator = SystemRandomNumberGenerator()
        let (width, height) = (96, 64)
        let pixels = (0 ..< width * height).map { _ in Float.random(in: 0 ... 1, using: &generator) }
        return StackDetector.Thumbnail(width: width, height: height, pixels: pixels)
    }()

    @Test func `the box blur matches a clamped loop`() {
        let (w, h, radius) = (thumbnail.width, thumbnail.height, 3)
        func pass(_ values: [Float], horizontal: Bool) -> [Float] {
            var out = values
            for y in 0 ..< h {
                for x in 0 ..< w {
                    var sum: Float = 0
                    for k in -radius ... radius {
                        let (sx, sy) = horizontal ? (min(max(x + k, 0), w - 1), y) : (x, min(max(y + k, 0), h - 1))
                        sum += values[sy * w + sx]
                    }
                    out[y * w + x] = sum / Float(2 * radius + 1)
                }
            }
            return out
        }
        let expected = pass(pass(thumbnail.pixels, horizontal: true), horizontal: false)
        let actual = StackDetector.blurred(thumbnail, radius: radius)
        #expect(zip(expected, actual).allSatisfy { abs($0 - $1) < 1e-5 })
    }

    @Test func `cell sharpness matches the interior Laplacian loop`() {
        let (w, h, columns, rows) = (thumbnail.width, thumbnail.height, 6, 4)
        var sums = [Float](repeating: 0, count: columns * rows)
        var counts = [Float](repeating: 0, count: columns * rows)
        let p = thumbnail.pixels
        for y in 1 ..< h - 1 {
            for x in 1 ..< w - 1 {
                let laplacian = 4 * p[y * w + x] - p[y * w + x - 1] - p[y * w + x + 1] - p[(y - 1) * w + x]
                    - p[(y + 1) * w + x]
                let cell = min(y * rows / h, rows - 1) * columns + min(x * columns / w, columns - 1)
                sums[cell] += laplacian * laplacian
                counts[cell] += 1
            }
        }
        let expected = zip(sums, counts).map { $0 / max($1, 1) }
        let actual = StackDetector.cellSharpness(thumbnail, columns: columns, rows: rows)
        #expect(zip(expected, actual).allSatisfy { abs($0 - $1) < 1e-4 * max(abs($0), 1) })
    }

    @Test func `correlation matches Pearson's formula`() {
        let a = thumbnail.pixels
        let b = a.enumerated().map { $1 * 0.5 + Float($0 % 7) * 0.01 }
        let meanA = a.reduce(0, +) / Float(a.count)
        let meanB = b.reduce(0, +) / Float(b.count)
        var (ab, aa, bb): (Float, Float, Float) = (0, 0, 0)
        for (x, y) in zip(a, b) {
            ab += (x - meanA) * (y - meanB)
            aa += (x - meanA) * (x - meanA)
            bb += (y - meanB) * (y - meanB)
        }
        #expect(abs(StackDetector.correlation(a, b) - ab / (aa * bb).squareRoot()) < 1e-4)
    }
}
