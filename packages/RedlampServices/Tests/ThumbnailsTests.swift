import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RedlampServices

/// Raw thumbnails from the smallest embedded preview that fits, against ImageIO's.
struct ThumbnailsTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "tests/fixtures/raw")

    private static var raws: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension != "redlamp" }
    }

    private static func imageIOThumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 192,
        ] as CFDictionary)
    }

    /// The image as 24 × 24 grey levels, to compare pictures whatever their exact size.
    private static func signature(_ image: CGImage) -> [Float] {
        var pixels = [UInt8](repeating: 0, count: 24 * 24)
        let context = CGContext(
            data: &pixels, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 24,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue,
        )
        context?.interpolationQuality = .medium
        context?.draw(image, in: CGRect(x: 0, y: 0, width: 24, height: 24))
        return pixels.map { Float($0) }
    }

    private static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let meanA = a.reduce(0, +) / Float(a.count)
        let meanB = b.reduce(0, +) / Float(b.count)
        var ab: Float = 0
        var aa: Float = 0
        var bb: Float = 0
        for (x, y) in zip(a, b) {
            ab += (x - meanA) * (y - meanB)
            aa += (x - meanA) * (x - meanA)
            bb += (y - meanB) * (y - meanB)
        }
        return ab / max((aa * bb).squareRoot(), 1e-6)
    }

    @Test(.enabled(if: !raws.isEmpty), arguments: raws)
    func `a raw's thumbnail is its smallest fitting preview, upright like ImageIO's`(_ url: URL) throws {
        let expected = try #require(Self.imageIOThumbnail(url))
        let thumbnail = try #require(Thumbnails.thumbnail(for: url, maxPixelSize: 192))
        #expect(max(thumbnail.width, thumbnail.height) == 192)
        #expect((thumbnail.width > thumbnail.height) == (expected.width > expected.height), "same orientation")
        let similarity = Self.correlation(Self.signature(thumbnail), Self.signature(expected))
        #expect(similarity > 0.9, "the same picture, the same way up (\(similarity))")
    }

    @Test(.enabled(if: !raws.isEmpty))
    func `a preview is decoded in place in the mapped raw file, never copied`() throws {
        let url = try #require(Self.raws.first)
        var file: NSData? = try NSData(contentsOf: url, options: .alwaysMapped)
        let (preview, _) = try #require(try Thumbnails.smallestPreview(
            in: Data(referencing: #require(file)),
            atLeast: 192,
        ))
        let bytes = try #require(try Thumbnails.bytes(of: preview, in: #require(file)))
        let start = try #require(file?.bytes) + preview.offset
        file = nil
        #expect(bytes.withUnsafeBytes { $0.baseAddress } == start, "a view into the mapping")
        #expect(bytes.count == preview.length)
        #expect(Array(bytes.prefix(2)) == [0xFF, 0xD8], "a JPEG, still mapped once the file is let go")
        let outside = Thumbnails.Preview(offset: 1 << 40, length: 1, width: 192, height: 128)
        #expect(Thumbnails.bytes(of: outside, in: NSData()) == nil)
    }

    @Test func `the smallest preview that fits is chosen`() {
        let small = Thumbnails.Preview(offset: 0, length: 1, width: 160, height: 120)
        let medium = Thumbnails.Preview(offset: 1, length: 1, width: 1616, height: 1080)
        let large = Thumbnails.Preview(offset: 2, length: 1, width: 6000, height: 4000)
        let unknown = Thumbnails.Preview(offset: 3, length: 1, width: 0, height: 0)
        #expect(Thumbnails.choose([large, small, medium], atLeast: 192) == medium)
        #expect(Thumbnails.choose([small, unknown], atLeast: 192) == unknown)
        #expect(Thumbnails.choose([small], atLeast: 192) == nil)
    }

    @Test func `orientations turn the image upright`() throws {
        // 2 × 1: red on the left, blue on the right.
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let image = try #require(context.makeImage())

        func pixels(_ image: CGImage) -> [String] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let out = CGContext(
                data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            )
            out?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            // Rows top to bottom, as the memory holds them.
            return stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] > 128 ? "R" : "B" }
        }
        #expect(try pixels(#require(Thumbnails.oriented(image, exifOrientation: 1))) == ["R", "B"])
        #expect(try pixels(#require(Thumbnails.oriented(image, exifOrientation: 3))) == ["B", "R"])
        // 6: the stored top row is the right side, so turning clockwise puts the left (red) on top.
        #expect(try pixels(#require(Thumbnails.oriented(image, exifOrientation: 6))) == ["R", "B"])
        #expect(try pixels(#require(Thumbnails.oriented(image, exifOrientation: 8))) == ["B", "R"])
        #expect(try #require(Thumbnails.oriented(image, exifOrientation: 6)).height == 2)
        #expect(Thumbnails.exifOrientation(libRawFlip: 6) == 6)
        #expect(Thumbnails.exifOrientation(libRawFlip: 5) == 8)
    }
}
