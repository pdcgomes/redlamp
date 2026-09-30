import CoreGraphics
import Foundation
import simd

/// The synthetic chart recipes are linted on: one image with known regions, rendered
/// through the real pipeline so lint sees exactly what users see.
///
/// Rows, top to bottom: a grey ramp, a hue and chroma sweep, eight skin patches, and two
/// smooth gradients (sky to white, sunset to dark) for spotting banding.
public enum RecipeChart {
    /// Bumped when the chart changes; lint results and golden renders are per version.
    public static let version = 2
    public static let width = 1024
    public static let height = 400

    public static let ramp = 0 ..< 64
    public static let sweep = 64 ..< 184
    public static let skin = 184 ..< 264
    public static let gradients = 264 ..< 400
    public static let skinPatchWidth = 128

    /// Skin tones from light to deep, in OKLCh (L, C, h).
    public static let skinTones: [SIMD3<Float>] = [
        SIMD3(0.86, 0.045, 62), SIMD3(0.80, 0.060, 58), SIMD3(0.74, 0.075, 55), SIMD3(0.68, 0.085, 52),
        SIMD3(0.62, 0.090, 50), SIMD3(0.55, 0.085, 48), SIMD3(0.48, 0.075, 46), SIMD3(0.40, 0.060, 45),
    ]

    /// The chart as encoded sRGB.
    public static func image() -> PixelImage {
        var pixels = [SIMD3<Float>](repeating: .zero, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                pixels[y * width + x] = color(x: x, y: y)
            }
        }
        return PixelImage(width: width, height: height, pixels: pixels)
    }

    static func color(x: Int, y: Int) -> SIMD3<Float> {
        let u = Float(x) / Float(width - 1)
        switch y {
        case ramp:
            return SIMD3(repeating: u)
        case sweep:
            let v = Float(y - sweep.lowerBound) / Float(sweep.count - 1)
            // Chroma stays inside sRGB at every hue, so the chart itself never clips.
            return ColorMath.okLabToEncodedSRGB(ColorMath.lab(l: 0.68, c: 0.01 + 0.1 * v, h: u * 360))
        case skin:
            let tone = skinTones[min(x / skinPatchWidth, skinTones.count - 1)]
            return ColorMath.okLabToEncodedSRGB(ColorMath.lab(l: tone.x, c: tone.y, h: tone.z))
        default:
            let v = Float(y - gradients.lowerBound) / Float(gradients.count - 1)
            if x < width / 2 {
                let t = Float(x) / Float(width / 2 - 1)
                let sky = ColorMath.lab(l: 0.55 + 0.4 * t, c: 0.11 * (1 - t) * (0.6 + 0.4 * v), h: 245)
                return ColorMath.okLabToEncodedSRGB(sky)
            }
            let t = Float(x - width / 2) / Float(width / 2 - 1)
            let sunset = ColorMath.lab(l: 0.82 - 0.7 * t, c: 0.14 * (1 - 0.6 * t) * (0.7 + 0.3 * v), h: 55 - 25 * t)
            return ColorMath.okLabToEncodedSRGB(sunset)
        }
    }

    /// The chart as a 16-bit PNG in the temporary directory, written once per version.
    public static func fileURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("redlamp-recipe-chart-v\(version).png")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        guard let cgImage = image().cgImage() else { throw CocoaError(.fileWriteUnknown) }
        try LookTableImport.writePNG(cgImage, to: url)
        return url
    }
}
