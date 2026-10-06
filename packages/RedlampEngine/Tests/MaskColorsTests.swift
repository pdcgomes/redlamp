import RedlampMasking
import simd
import Testing
@testable import RedlampEngine

struct MaskColorsTests {
    static let sky = SIMD3<Float>(0.3, 0.45, 0.8)
    static let branch = SIMD3<Float>(0.05, 0.04, 0.03)

    private func colour(_ texels: [Float16], at index: Int) -> SIMD3<Float> {
        SIMD3(Float(texels[index * 4]), Float(texels[index * 4 + 1]), Float(texels[index * 4 + 2]))
    }

    /// Sky on the left and a branch on the right, with a four-pixel edge between: the colour
    /// inside is the sky's and the colour outside the branch's, on both sides of the edge.
    @Test func `each side's colour is filled in across the edge`() throws {
        let (width, height) = (64, 16)
        let coverage = (0 ..< width * height).map { index -> Float in
            let x = index % width
            return x < 30 ? 1 : x < 34 ? Float(34 - x) / 4 : 0
        }
        let analysis = AnalysisImage(
            width: width, height: height, pixels: coverage.map { $0 * Self.sky + (1 - $0) * Self.branch },
        )
        let texels = try #require(MaskColors.texels(
            for: GrayMask(width: width, height: height, coverage: coverage), analysis: analysis, orientation: 1,
        ))
        for x in [0, 31, 63] {
            let index = 8 * width + x
            #expect(simd_distance(colour(texels.inside, at: index), Self.sky) < 0.01, "inside at \(x)")
            #expect(simd_distance(colour(texels.outside, at: index), Self.branch) < 0.01, "outside at \(x)")
        }
    }

    /// With nothing wholly outside it, a mask has no colour to fill in there.
    @Test func `a mask nowhere wholly outside has no colours`() {
        let (width, height) = (32, 8)
        let analysis = AnalysisImage(
            width: width, height: height, pixels: [SIMD3<Float>](repeating: Self.sky, count: width * height),
        )
        let coverage = (0 ..< width * height).map { Float($0 % width) / Float(width - 1) * 0.5 + 0.5 }
        #expect(MaskColors.texels(
            for: GrayMask(width: width, height: height, coverage: coverage), analysis: analysis, orientation: 1,
        ) == nil)
    }
}
