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

        // The Stack workspace changes the method: a new merge, which opening then shows.
        try FocusStackDocument(frames: urls, strategy: .detail, at: documentURL).write(to: documentURL)
        let preview = try await engine.focusStack(at: documentURL, maxLongEdge: 128) { _ in }
        #expect(max(preview.image.width, preview.image.height) == 128)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path).count == 2)
        _ = try await engine.open(documentURL)
        let detail = try await engine.renderStill(StillRequest(recipe: EditRecipe()))
        #expect(try pixels(detail) != pixels(image))
    }

    @Test func `a stroke blends its source in with a soft edge`() {
        let (width, height) = (100, 50)
        let zero = Float16(0).bitPattern
        let one = Float16(1).bitPattern
        var samples = [UInt16](repeating: zero, count: width * height * 4)
        let source = [UInt16](repeating: one, count: width * height * 4)
        // A dot of radius 20 px (0.2 of the long edge) at the centre, full strength to half radius.
        let stroke = FocusStackStroke(source: .strategy(.detail), radius: 0.2, hardness: 0.5, points: [SIMD2(0.5, 0.5)])
        FocusStackCache.paint(
            stroke, from: source, into: &samples, size: PixelSize(width: width, height: height), orientation: 0,
        )
        func red(_ x: Int, _ y: Int) -> Float {
            Float(Float16(bitPattern: samples[(y * width + x) * 4]))
        }
        #expect(red(50, 25) == 1 && red(55, 25) == 1)
        #expect(red(65, 25) > 0.05 && red(65, 25) < 0.95)
        #expect(red(75, 25) == 0 && red(50, 8) > 0 && red(50, 2) == 0)
        // Rotated 90° clockwise, the image's top-left is the sensor's bottom-left.
        var rotated = [UInt16](repeating: zero, count: width * height * 4)
        let corner = FocusStackStroke(source: .strategy(.detail), radius: 0.05, hardness: 1, points: [SIMD2(0, 0)])
        FocusStackCache.paint(
            corner, from: source, into: &rotated, size: PixelSize(width: width, height: height), orientation: 6,
        )
        #expect(Float(Float16(bitPattern: rotated[((height - 1) * width) * 4])) == 1)
    }

    /// Strokes from a frame and from another method paint exactly those pixels, and only under
    /// the stroke.
    @Test func `retouching paints a frame or another method over the merge`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (width, height) = (240, 160)
        let frames = syntheticStack(frames: 3, width: width, height: height) { x, _ in x < width / 2 ? 0 : 2 }
        let urls = try frames.enumerated().map { index, frame in
            let url = folder.appendingPathComponent("frame\(index).png")
            try writePNG(frame, to: url)
            return url
        }
        let documentURL = folder.appendingPathComponent("stack.redlampstack")
        var document = FocusStackDocument(frames: urls, at: documentURL)
        try document.write(to: documentURL)
        let engine = try RedlampEngine(stillTile: 2048, stackCache: folder.appendingPathComponent("cache"))
        let base = try engine.stacks.stack(at: documentURL)
        let smooth = try engine.stacks.merged(urls, strategy: .smooth, documentURL: documentURL)

        document.retouch = [
            FocusStackStroke(source: .frame("frame2.png"), radius: 0.1, hardness: 1, points: [SIMD2(0.25, 0.5)]),
            FocusStackStroke(source: .strategy(.smooth), radius: 0.1, hardness: 1, points: [SIMD2(0.75, 0.5)]),
        ]
        try document.write(to: documentURL)
        let retouched = try engine.stacks.stack(at: documentURL)
        let w = retouched.decoded.width
        func pixel(_ stack: [UInt16], _ x: Int, _ y: Int) -> UInt16 {
            stack[(y * w + x) * 4 + 1]
        }
        let (h, cy) = (retouched.decoded.height, retouched.decoded.height / 2)
        #expect(retouched.decoded.width == base.decoded.width && h == base.decoded.height)
        // Under the frame stroke: frame 2 (blurred on the left) replaces the sharp merge.
        #expect(pixel(retouched.decoded.samples, w / 4, cy) != pixel(base.decoded.samples, w / 4, cy))
        // Under the method stroke: Smooth's pixel exactly.
        #expect(pixel(retouched.decoded.samples, 3 * w / 4, cy) == pixel(smooth.decoded.samples, 3 * w / 4, cy))
        // Away from both: untouched.
        #expect(pixel(retouched.decoded.samples, w / 2, 5) == pixel(base.decoded.samples, w / 2, 5))
        // A second engine reads the retouched result from the cache.
        let reopened = try RedlampEngine(stillTile: 2048, stackCache: folder.appendingPathComponent("cache"))
            .stacks.stack(at: documentURL)
        #expect(reopened.decoded.samples == retouched.decoded.samples)
    }

    /// The RGBA8 bytes of an image.
    func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
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
