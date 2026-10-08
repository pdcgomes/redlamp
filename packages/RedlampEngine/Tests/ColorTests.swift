import CoreGraphics
import Foundation
import Metal
import RedlampColor
import RedlampEngine
import RedlampEngineAPI
import Testing

/// Colour behaviour on the sample cameras, through the public engine API.
struct ColorTests {
    /// The share of clearly coloured pixels with a channel pinned at 0 or 255.
    private func pinned(_ image: CGImage) throws -> Double {
        let data = try #require(image.dataProvider?.data) as Data
        let bytesPerPixel = image.bitsPerPixel / 8
        var count = 0
        var total = 0
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for row in 0 ..< image.height {
                for column in 0 ..< image.width {
                    let offset = row * image.bytesPerRow + column * bytesPerPixel
                    let rgb = (0 ..< 3).map { Int(bytes[offset + $0]) }
                    let high = rgb.max()!
                    let low = rgb.min()!
                    if high - low > 60, high >= 255 || low <= 0 {
                        count += 1
                    }
                    total += 1
                }
            }
        }
        return Double(count) / Double(total)
    }

    /// Gamut-relative saturation: a strong boost moves colours towards the gamut boundary
    /// instead of piling them up on it.
    @Test(.enabled(if: EngineSmokeTests.canRender))
    func `saturation stays inside the gamut`() async throws {
        for url in EngineSmokeTests.fixtures where SupportedFormats.isRaw(url) {
            let engine = try RedlampEngine()
            _ = try await engine.open(url)
            var boosted = EditRecipe()
            boosted[.saturation] = 100
            let base = try await pinned(engine.renderStill(StillRequest(recipe: EditRecipe(), maxLongEdge: 600)))
            let more = try await pinned(engine.renderStill(StillRequest(recipe: boosted, maxLongEdge: 600)))
            #expect(more - base < 0.1, "\(url.lastPathComponent): \(base) → \(more)")
        }
    }

    /// A low temperature with a strong magenta tint turns the photo blue and keeps its detail, as
    /// in Lightroom: past the tint where the white reaches x + y = 1, every pixel came out the same
    /// blue (#342). So a photo keeps most of the lightness range it has just short of that tint, at
    /// the report's settings and at Lightroom's beside them. It's measured against that tint
    /// because a bright scene under so much blue clips on both sides of it, as the Sony's snow does.
    @Test(.enabled(if: EngineSmokeTests.canRender))
    func `a cool white balance with a strong magenta tint keeps the photo's detail`() async throws {
        for url in EngineSmokeTests.fixtures where SupportedFormats.isRaw(url) {
            let engine = try RedlampEngine()
            _ = try await engine.open(url)
            /// The range of L* over the middle 90% of the pixels.
            func spread(kelvin: Double, tint: Double, exposure: Double) async throws -> Double {
                var recipe = EditRecipe()
                recipe.whiteBalanceMode = .custom
                recipe[.temperature] = kelvin
                recipe[.tint] = tint
                recipe[.exposure] = exposure
                let image = try await engine.renderStill(StillRequest(recipe: recipe, maxLongEdge: 300))
                let lightness = try ProcessStabilityTests.linearSRGB(image).map { CIELab.fromLinearSRGB($0).x }
                    .sorted()
                return lightness[lightness.count * 95 / 100] - lightness[lightness.count * 5 / 100]
            }
            for (kelvin, tint, shortOfEdge, exposure) in [(2800.0, 102.0, 75.0, 1.53), (2000, 110, 30, 0)] {
                let past = try await spread(kelvin: kelvin, tint: tint, exposure: exposure)
                let short = try await spread(kelvin: kelvin, tint: shortOfEdge, exposure: exposure)
                #expect(
                    past > short / 2,
                    "\(url.lastPathComponent), \(Int(kelvin)) K: L* spans \(past), and \(short) short of the edge",
                )
            }
        }
    }
}
