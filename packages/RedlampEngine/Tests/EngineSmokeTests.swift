import CoreGraphics
import Foundation
import Metal
import RedlampEngine
import RedlampEngineAPI
import Testing

/// Renders every downloaded fixture (tests/fixtures/raw, fetched from raw.pixls.us).
struct EngineSmokeTests {
    /// Needs the sample files and a Metal GPU (hosted CI VMs may have neither).
    static let canRender = !fixtures.isEmpty && MTLCreateSystemDefaultDevice() != nil

    static let fixtures: [URL] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/fixtures/raw")
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.filter(SupportedFormats.isSupported).sorted { $0.path < $1.path }
    }()

    @Test(.enabled(if: canRender), arguments: fixtures)
    func `opens and renders`(url: URL) async throws {
        let engine = try RedlampEngine()
        let info = try await engine.open(url)
        #expect(info.pixelSize.width > 0)
        #expect(info.isRaw)
        let image = try await engine.renderStill(StillRequest(recipe: EditRecipe(), maxLongEdge: 512))
        #expect(max(image.width, image.height) == 512)
    }

    @Test(.enabled(if: canRender))
    func `interactive render delivers frame`() async throws {
        let engine = try RedlampEngine()
        _ = try await engine.open(Self.fixtures[0])
        let frames = engine.frames()
        engine.render(RenderRequest(
            recipe: EditRecipe(),
            targetSize: PixelSize(width: 800, height: 800),
            generation: 7,
        ))
        var iterator = frames.makeAsyncIterator()
        let frame = try #require(await iterator.next())
        #expect(frame.generation == 7)
        #expect(frame.size.longEdge == 800)
        #expect(frame.histogram.totalCount > 0)
    }

    /// A linear gradient darkening the top darkens the top rows and leaves the bottom
    /// rows untouched.
    @Test(.enabled(if: canRender))
    func `linear mask darkens only its region`() async throws {
        let engine = try RedlampEngine()
        _ = try await engine.open(Self.fixtures[0])
        let plain = try await engine.renderStill(StillRequest(recipe: EditRecipe(), maxLongEdge: 256))

        var recipe = EditRecipe()
        var mask = MaskLayer(name: "Top", components: [
            MaskComponent(shape: .linear(LinearMask(start: ImagePoint(x: 0.5, y: 0), end: ImagePoint(x: 0.5, y: 0.5)))),
        ])
        mask[.localExposure] = -2
        recipe.masks = [mask]
        let masked = try await engine.renderStill(StillRequest(recipe: recipe, maxLongEdge: 256))

        let bottomRows = (plain.height - 10) ..< plain.height
        #expect(brightness(masked, rows: 0 ..< 10) < brightness(plain, rows: 0 ..< 10) * 0.6)
        #expect(abs(brightness(masked, rows: bottomRows) - brightness(plain, rows: bottomRows)) < 0.5)
    }

    private func brightness(_ image: CGImage, rows: Range<Int>) -> Double {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var total = 0.0
        for row in rows {
            for x in 0 ..< width {
                let index = (row * width + x) * 4
                total += Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])
            }
        }
        return total / Double(rows.count * width * 3)
    }
}
