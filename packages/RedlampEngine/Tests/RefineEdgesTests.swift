import CoreGraphics
import Foundation
import ImageIO
import Metal
import RedlampEngine
import RedlampEngineAPI
import RedlampMasking
import Testing
import UniformTypeIdentifiers

/// Refine Edges solves an AI mask's edge again per pixel, as masks of its kind are made now
/// (MSK-31), rather than blurring it with a guided filter.
struct RefineEdgesTests {
    static let canRender = MTLCreateSystemDefaultDevice() != nil
    static let width = 600
    static let height = 400

    private static func isHead(_ x: Int, _ y: Int) -> Bool {
        hypot(Double(x - 300), Double(y - 260)) < 120
    }

    /// A dark head on a light wall, with a strand two pixels wide reaching out of its top.
    private static func photo() throws -> URL {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let strand = (300 ... 301).contains(x) && y >= 112 && y < 140
                let value: UInt8 = isHead(x, y) || strand ? 40 : 200
                let index = (y * width + x) * 4
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
        ))
        let url = FileManager.default.temporaryDirectory.appending(path: "refine-edges-\(UUID().uuidString).png")
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil),
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test(.enabled(if: Self.canRender))
    func `Refine Edges brings back a strand a Subject mask missed`() async throws {
        let url = try Self.photo()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try RedlampEngine()
        _ = try await engine.open(url)
        var coverage = [Float](repeating: 0, count: Self.width * Self.height)
        for index in coverage.indices
            where hypot(Double(index % Self.width - 300), Double(index / Self.width - 260)) < 121 {
            coverage[index] = 1
        }
        let bitmap = try #require(GrayMask(width: Self.width, height: Self.height, coverage: coverage).bitmap())
        let mask = AIMask(
            kind: .subject, provider: "test", revision: 1, analysisHash: "", center: ImagePoint(x: 0.5, y: 0.65),
            bitmap: bitmap,
        )
        let png = try #require(try await engine.refineMaskEdges(mask).png)
        let refined = try #require(GrayMask.decode(png)).resized(to: PixelSize(width: Self.width, height: Self.height))
        // 6 px out from the head: inside the band closed-form solves (2% of the long side), out of
        // reach of the guided filter Refine Edges used to run (radius 4).
        let strand: UInt8 = refined[300, 134]
        let wall: UInt8 = refined[310, 134]
        let head: UInt8 = refined[300, 260]
        #expect(strand > 100, "the strand: \(strand)")
        #expect(wall < 30, "the wall beside it: \(wall)")
        #expect(head > 250, "inside the head: \(head)")
    }
}
