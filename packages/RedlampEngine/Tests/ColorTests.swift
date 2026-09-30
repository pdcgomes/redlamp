import CoreGraphics
import Foundation
import Metal
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
}
