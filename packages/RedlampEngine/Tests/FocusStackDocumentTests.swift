import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI
import RedlampServices
import Testing
import UniformTypeIdentifiers
@testable import RedlampEngine

extension FocusStackTests {
    @Test func `a stack document stores frames relative to its folder`() {
        let folder = URL(fileURLWithPath: "/tmp/shoot", isDirectory: true)
        let document = FocusStackDocument(
            frames: [
                folder.appendingPathComponent("a.cr3"),
                folder.appendingPathComponent("raw/b.cr3"),
                URL(fileURLWithPath: "/elsewhere/c.cr3"),
            ],
            at: folder.appendingPathComponent("stack.redlampstack"),
        )
        #expect(document.frames == ["a.cr3", "raw/b.cr3", "/elsewhere/c.cr3"])
        let moved = URL(fileURLWithPath: "/Volumes/card/shoot/stack.redlampstack")
        #expect(document.frameURLs(at: moved).map(\.path) == [
            "/Volumes/card/shoot/a.cr3", "/Volumes/card/shoot/raw/b.cr3", "/elsewhere/c.cr3",
        ])
        #expect(SupportedFormats.isSupported(moved) && SupportedFormats.isStack(moved))
    }

    @Test func `the covered crop trims the edges frames don't reach`() {
        // Uncovered: a 3-pixel band on the left and a wedge in the top-right corner.
        let rect = FocusStackCache.coveredRect(width: 40, height: 30) { x, y in
            x >= 3 && !(x > 30 && y < x - 30)
        }
        #expect(rect.x == 3)
        for y in rect.y ..< rect.y + rect.height {
            for x in rect.x ..< rect.x + rect.width {
                #expect(x >= 3 && !(x > 30 && y < x - 30))
            }
        }
        #expect(rect.width * rect.height >= 30 * 25)
    }

    /// A document over bitmap frames opens like a photo, and a second engine reopens it from the
    /// cache with the same pixels.
    @Test func `a stack document opens through the cache`() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (width, height) = (320, 240)
        let frames = syntheticStack(frames: 3, width: width, height: height) { x, _ in x < width / 2 ? 0 : 2 }
        let urls = try frames.enumerated().map { index, frame in
            let url = folder.appendingPathComponent("frame\(index).png")
            try writePNG(frame, to: url)
            return url
        }
        let documentURL = folder.appendingPathComponent("stack.redlampstack")
        try FocusStackDocument(frames: urls, at: documentURL).write(to: documentURL)
        let cacheRoot = folder.appendingPathComponent("cache")

        let engine = try RedlampEngine(stillTile: 2048, stackCache: cacheRoot)
        let info = try await engine.open(documentURL)
        #expect(info.url == documentURL)
        #expect(info.sensorDescription.hasPrefix("Focus stack of 3"))
        #expect(info.pixelSize.width <= width && info.pixelSize.width > width - 16)
        let image = try await engine.renderStill(StillRequest(recipe: EditRecipe()))
        #expect(image.width == info.pixelSize.width)
        let merged = try engine.stacks.stack(at: documentURL)
        let entries = try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path)
        #expect(entries.count == 1)

        let reopened = try RedlampEngine(stillTile: 2048, stackCache: cacheRoot).stacks.stack(at: documentURL)
        #expect(reopened.decoded.samples == merged.decoded.samples)
        #expect(reopened.report == merged.report)
        #expect(reopened.crop == merged.crop)
        let thumbnail = await engine.thumbnail(for: documentURL, maxPixelSize: 128)
        #expect(thumbnail != nil)
    }

    /// A 16-bit sRGB PNG of a luma image.
    func writePNG(_ image: LumaImage, to url: URL) throws {
        var samples = [UInt16](repeating: 65535, count: image.width * image.height * 4)
        for index in 0 ..< image.width * image.height {
            let value = UInt16((min(max(image.pixels[index], 0), 1) * 65535).rounded())
            samples[index * 4] = value
            samples[index * 4 + 1] = value
            samples[index * 4 + 2] = value
        }
        let data = samples.withUnsafeBytes { Data($0) }
        let image = try #require(CGImage(
            width: image.width, height: image.height, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: image.width * 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGImageByteOrderInfo.order16Little.rawValue,
            ),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent,
        ))
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil,
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
