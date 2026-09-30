import CoreGraphics
import Foundation
import RedlampEngine
import RedlampEngineAPI
import Testing

/// Exports below full size are the full-resolution render, downscaled (EDT-13).
struct ExportTests {
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let data = try #require(image.dataProvider?.data) as Data
        return [UInt8](data)
    }

    private static let decode: [Double] = (0 ..< 256).map { value in
        let c = Double(value) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func encode(_ linear: Double) -> Double {
        let c = min(max(linear, 0), 1)
        return 255 * (c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
    }

    @Test(.enabled(if: EngineSmokeTests.canRender))
    func `a smaller export is the full render downscaled`() async throws {
        let url = try #require(EngineSmokeTests.fixtures.first { $0.lastPathComponent == "DSC_0750.NEF" })
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        var recipe = EditRecipe()
        recipe[.sharpenAmount] = 100
        let full = try await engine.renderStill(StillRequest(recipe: recipe, purpose: .export))
        let small = try await engine.renderStill(StillRequest(recipe: recipe, maxLongEdge: 1000, purpose: .export))
        let fullPixels = try pixels(full)
        let smallPixels = try pixels(small)

        // Area-average the full render in linear light onto the small grid.
        var sums = [Double](repeating: 0, count: small.width * small.height * 3)
        var counts = [Double](repeating: 0, count: small.width * small.height)
        let fullStride = full.bytesPerRow
        let bytesPerPixel = full.bitsPerPixel / 8
        for y in 0 ..< full.height {
            let sy = y * small.height / full.height
            for x in 0 ..< full.width {
                let sx = x * small.width / full.width
                let target = sy * small.width + sx
                let offset = y * fullStride + x * bytesPerPixel
                for channel in 0 ..< 3 {
                    sums[target * 3 + channel] += Self.decode[Int(fullPixels[offset + channel])]
                }
                counts[target] += 1
            }
        }
        var difference = 0.0
        var samples = 0.0
        for y in 4 ..< small.height - 4 {
            for x in 4 ..< small.width - 4 {
                let target = y * small.width + x
                let offset = y * small.bytesPerRow + x * (small.bitsPerPixel / 8)
                for channel in 0 ..< 3 {
                    let expected = Self.encode(sums[target * 3 + channel] / counts[target])
                    difference += abs(expected - Double(smallPixels[offset + channel]))
                    samples += 1
                }
            }
        }
        #expect(difference / samples < 1.5, "mean difference \(difference / samples) levels")
    }
}
