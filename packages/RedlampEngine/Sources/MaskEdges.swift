import Foundation
import Metal
import RedlampEngineAPI
import RedlampMasking

/// AI mask edges at full resolution (MSK-07, process 13), for masks coarser than the size masks are
/// stored at: embedded mattes, face parts and masks made before edges were solved per pixel (MSK-26;
/// masks solved per pixel are drawn as they are). Drawn at 60 MP, a coarse mask's edge would be its
/// pixels upsampled. Instead the develop kernel and the detail stage refine it with a guided filter
/// guided by the photo's own log luminance, as the tone base is (`ToneBase`): the filter's
/// coefficients are computed here on the analysis image's grid, in the sensor's orientation, and
/// applied to each pixel's log luminance, so the edge follows the photo at any size (K. He &
/// J. Sun, "Fast guided filter", 2015).
///
/// Where the photo has no edge for the mask's to follow (a person against a wall as bright as
/// they are), the filter would only blur the mask, so a third coefficient says how far to trust
/// it there: the guide's local variance against `epsilon`. The rest is the mask as drawn before.
enum MaskEdges {
    /// The filter's window radius, in analysis texels (about 1500 on the long side, as AI masks
    /// are): wide enough to span an upsampled mask pixel's ramp, narrow enough not to reach the
    /// photo's next edge.
    static let radius = 3

    /// Guide variance (stops squared) below which an edge is the mask's rather than the photo's.
    static let epsilon: Float = 0.02
    /// Feather and Edge's reach, as a fraction of the mask's long edge.
    static let reachFraction = 0.015

    static func reach(_ mask: GrayMask) -> Int {
        max(1, Int((Double(max(mask.width, mask.height)) * reachFraction).rounded()))
    }

    /// The photo's log luminance as the guide, less `offset`, its mean, so the coefficients stay
    /// small enough for half floats.
    static func guide(_ analysis: AnalysisImage) -> (values: [Float], offset: Float) {
        let values = analysis.pixels.map(ToneBase.logLuminance)
        let offset = values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count)
        return (values.map { $0 - offset }, offset)
    }

    /// `mask` (in the oriented frame) on the guide's grid (the analysis image's, in the sensor's
    /// orientation), as RGBA half floats: a, b and how far to trust them.
    static func texels(
        for mask: GrayMask, guide: [Float], width: Int, height: Int, orientation: Int,
    ) -> [Float16] {
        let input = coverage(of: mask, width: width, height: height, orientation: orientation)
        let (a, b) = GuidedFilter.coefficients(
            input, guide: guide, width: width, height: height, radius: radius, epsilon: epsilon,
        )
        let mean = BoxFilter.blur(guide, width: width, height: height, radius: radius)
        let square = BoxFilter.blur(guide.map { $0 * $0 }, width: width, height: height, radius: radius)
        let trust = BoxFilter.blur(
            zip(square, mean).map { square, mean in
                let variance = max(square - mean * mean, 0)
                return variance / (variance + epsilon)
            },
            width: width, height: height, radius: radius,
        )
        var texels = [Float16](repeating: 0, count: width * height * 4)
        for index in 0 ..< width * height {
            texels[index * 4] = Float16(a[index])
            texels[index * 4 + 1] = Float16(b[index])
            texels[index * 4 + 2] = Float16(trust[index])
        }
        return texels
    }

    /// `mask` (in the oriented frame) at each texel of a grid in the sensor's orientation.
    static func coverage(of mask: GrayMask, width: Int, height: Int, orientation: Int) -> [Float] {
        let coverage = mask.coverage
        var grid = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let source = SIMD2((Double(x) + 0.5) / Double(width), (Double(y) + 0.5) / Double(height))
                let oriented = orientedCoordinate(source, orientation: orientation)
                grid[y * width + x] = sample(coverage, width: mask.width, height: mask.height, at: oriented)
            }
        }
        return grid
    }

    /// Bilinear coverage at normalised `point`, as the GPU samples it.
    private static func sample(_ values: [Float], width: Int, height: Int, at point: SIMD2<Double>) -> Float {
        let x = min(max(point.x * Double(width) - 0.5, 0), Double(width - 1))
        let y = min(max(point.y * Double(height) - 0.5, 0), Double(height - 1))
        let (x0, y0) = (Int(x), Int(y))
        let (x1, y1) = (min(x0 + 1, width - 1), min(y0 + 1, height - 1))
        let (fx, fy) = (Float(x - Double(x0)), Float(y - Double(y0)))
        let top = values[y0 * width + x0] * (1 - fx) + values[y0 * width + x1] * fx
        let bottom = values[y1 * width + x0] * (1 - fx) + values[y1 * width + x1] * fx
        return top * (1 - fy) + bottom * fy
    }
}
