import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import RedlampLibrary

struct ImportPreviewTests {
    @Test(arguments: (try? FileManager.default.contentsOfDirectory(atPath: FixtureTests.rawFolder.path))?
        .filter { NamingJob.isRaw(NamingJob.split($0).ext) }.sorted() ?? [])
    func `each raw's preview is found and read alone, big enough for the grid`(_ name: String) async throws {
        let url = FixtureTests.rawFolder.appending(path: name)
        let size = try Int(LocalFileSystem().attributes(of: url).size)
        let head = try LocalFileSystem().read(url, range: 0 ..< PhotoMetadataReader.headLength)
        let fetched = Mutex(0)
        var bytes = PreviewBytes(head: head, size: size) { range in
            let data = try LocalFileSystem().read(url, range: range)
            fetched.withLock { $0 += data.count }
            return data
        }
        let preview = try #require(try await EmbeddedPreviews.best(
            in: &bytes,
            reaching: PhotoStore.Tier.grid.pixelSize,
        ))
        #expect((preview.longEdge ?? 0) >= PhotoStore.Tier.grid.pixelSize, "\(preview)")
        // The search reads a few blocks past the head at most; the preview is a part of the file.
        #expect(fetched.withLock { $0 } <= 16 * PreviewBytes.block, "\(fetched.withLock { $0 })")
        #expect(preview.length < size / 4, "\(preview.length) of \(size)")
        let jpeg = try LocalFileSystem().read(url, range: preview.range)
        let image = try #require(EmbeddedPreviews.thumbnail(ofJPEG: jpeg, edge: 384, orientation: nil))
        #expect(max(image.width, image.height) == 384)
    }

    @Test func `a preview without an orientation of its own is turned upright as its raw says`() throws {
        // Two pixels: red on the left, blue on the right.
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
        // Rows from the top, each pixel "r" or "b".
        func pixels(_ image: CGImage) throws -> [String] {
            let reading = try #require(CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
            ))
            reading.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let data = try #require(reading.data).assumingMemoryBound(to: UInt8.self)
            return (0 ..< image.height).map { row in
                (0 ..< image.width).map { column in
                    data[(row * image.width + column) * 4] > 128 ? "r" : "b"
                }.joined()
            }
        }
        #expect(try pixels(image) == ["rb"])
        let cases: [(Int, [String])] = [
            (2, ["br"]), (3, ["br"]), (4, ["rb"]), (5, ["r", "b"]), (6, ["r", "b"]), (7, ["b", "r"]), (8, ["b", "r"]),
        ]
        for (orientation, expected) in cases {
            #expect(try pixels(#require(EmbeddedPreviews.oriented(image, orientation))) == expected, "\(orientation)")
        }
    }
}
