import CoreGraphics
import Foundation
import simd

/// Golden renders: every bundled recipe on the lint chart, recorded once per process
/// version and never regenerated, so no engine change can silently alter a shipped look.
public enum GoldenRender {
    /// Renders are this wide (the chart's aspect), small enough to commit.
    public static let width = 256

    public struct Comparison: Sendable {
        public var meanDeltaE: Double
        public var maxDeltaE: Double

        /// Mean under 0.6 and max under 4 (OKLab ΔE × 100).
        public var passes: Bool {
            meanDeltaE < 0.6 && maxDeltaE < 4
        }
    }

    public static func directory(root: URL, processVersion: Int) -> URL {
        root.appendingPathComponent("tests/golden/recipes/process-\(processVersion)", isDirectory: true)
    }

    public static func fileName(for recipe: Recipe) -> String {
        recipe.id.replacingOccurrences(of: "/", with: "~") + "@\(recipe.version).png"
    }

    public static func render(_ recipe: Recipe, with renderer: RecipeRenderer) async throws -> CGImage {
        renderer.prepare(recipe)
        return try await renderer.render(
            edit: recipe.edit(),
            image: RecipeChart.fileURL(),
            maxLongEdge: width,
            sixteenBit: false,
        )
    }

    public static func compare(_ a: CGImage, _ b: CGImage) -> Comparison? {
        guard a.width == b.width, a.height == b.height,
              let pa = PixelImage(a), let pb = PixelImage(b) else { return nil }
        var sum = 0.0, worst = 0.0
        for (x, y) in zip(pa.pixels, pb.pixels) {
            let d = Double(simd_distance(ColorMath.encodedSRGBToOKLab(x), ColorMath.encodedSRGBToOKLab(y))) * 100
            sum += d
            worst = max(worst, d)
        }
        return Comparison(meanDeltaE: sum / Double(pa.pixels.count), maxDeltaE: worst)
    }
}
