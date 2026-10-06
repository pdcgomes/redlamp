import Foundation
import RedlampEngineAPI
import RedlampMasking

/// The colours on either side of an AI mask's edge (MSK-27, process 14): at each texel of the
/// analysis grid, the colour of the nearest pixels wholly inside the mask and of the nearest
/// wholly outside it, filled in by push-pull. The develop kernel splits a partly covered pixel's
/// light by them, so that the mask's edit reaches only the share of the light the masked side
/// gives the pixel.
enum MaskColors {
    /// Coverage at or above which a texel is wholly inside the mask, and at or below which it is
    /// wholly outside it.
    static let inside: Float = 0.98
    static let outside: Float = 0.02

    /// Sky masks split their edge pixels; Subject and People wait for mattes that measure well
    /// enough (MSK-32). Feather asks for a soft edit, which blending by coverage gives.
    static func splits(_ mask: AIMask) -> Bool {
        mask.kind == .sky && mask.feather == 0 && mask.bitmap.png != nil
    }

    /// `mask` (in the oriented frame) on `analysis`'s grid (in the sensor's orientation), as two
    /// arrays of RGBA half floats in its camera RGB: the colour inside, then the colour outside.
    /// Nil if the mask is nowhere wholly inside or nowhere wholly outside.
    static func texels(
        for mask: GrayMask, analysis: AnalysisImage, orientation: Int,
    ) -> (inside: [Float16], outside: [Float16])? {
        let (width, height) = (analysis.width, analysis.height)
        let coverage = MaskEdges.coverage(of: mask, width: width, height: height, orientation: orientation)
        let inside = coverage.map { $0 >= Self.inside }
        let outside = coverage.map { $0 <= Self.outside }
        guard inside.contains(true), outside.contains(true) else { return nil }
        let channels = (0 ..< 3).map { channel in analysis.pixels.map { $0[channel] } }
        func filled(_ known: [Bool]) -> [Float16] {
            var texels = [Float16](repeating: 1, count: width * height * 4)
            for (channel, values) in channels.enumerated() {
                let fill = StackDepthSolver.fill(values, known: known, width: width, height: height, empty: 0)
                for index in fill.indices {
                    texels[index * 4 + channel] = Float16(fill[index])
                }
            }
            return texels
        }
        return (filled(inside), filled(outside))
    }
}
