import CoreGraphics
import Foundation
import RedlampDocument
import Testing

struct ThumbnailPacksTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "packs-\(UUID().uuidString)")
    private let folder = URL(fileURLWithPath: "/Photos/Trip")
    private let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func photo(_ name: String) -> URL {
        folder.appending(path: name)
    }

    @Test func `a stored thumbnail reads back only while the photo is unchanged`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let packs = ThumbnailPacks(directory: directory)
        packs.store(Data("one".utf8), for: photo("A.ARW"), size: 10, modified: date)
        packs.store(Data("two".utf8), for: photo("B.ARW"), size: 20, modified: date)

        #expect(packs.jpeg(for: photo("A.ARW"), size: 10, modified: date) == Data("one".utf8))
        #expect(packs.jpeg(for: photo("A.ARW"), size: 11, modified: date) == nil, "the file was rewritten")
        #expect(packs.jpeg(for: photo("A.ARW"), size: 10, modified: date.addingTimeInterval(1)) == nil)
        #expect(packs.contains(photo("B.ARW"), size: 20, modified: date))
        #expect(packs.jpeg(for: folder.appending(path: "Other/A.ARW"), size: 10, modified: date) == nil)

        let reopened = ThumbnailPacks(directory: directory)
        #expect(reopened.jpeg(for: photo("B.ARW"), size: 20, modified: date) == Data("two".utf8))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 1, "one pack for the folder")
    }

    @Test func `a pack mostly stale is compacted, keeping the latest records`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let packs = ThumbnailPacks(directory: directory)
        let jpeg = Data(repeating: 7, count: 1000)
        for version in 0 ..< 6 {
            packs.store(jpeg + Data([UInt8(version)]), for: photo("A.ARW"), size: Int64(version), modified: date)
        }
        packs.store(jpeg, for: photo("B.ARW"), size: 1, modified: date)
        let attributes = try FileManager.default.attributesOfItem(atPath: packs.packURL(for: folder).path)
        let size = try #require(attributes[.size] as? Int)
        #expect(size < 4000, "six versions of A would be over 6000 bytes")
        #expect(packs.jpeg(for: photo("A.ARW"), size: 5, modified: date) == jpeg + Data([5]))
        #expect(ThumbnailPacks(directory: directory).jpeg(for: photo("B.ARW"), size: 1, modified: date) == jpeg)
    }

    @Test func `past the budget, the least recently opened packs go`() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = ThumbnailPacks(directory: directory)
        old.store(Data(repeating: 1, count: 4000), for: URL(fileURLWithPath: "/Old/A.ARW"), size: 1, modified: date)
        let oldPack = old.packURL(for: URL(fileURLWithPath: "/Old"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: oldPack.path,
        )

        let packs = ThumbnailPacks(directory: directory, budget: 6000)
        packs.store(Data(repeating: 2, count: 4000), for: photo("A.ARW"), size: 1, modified: date)
        #expect(!FileManager.default.fileExists(atPath: oldPack.path))
        #expect(packs.contains(photo("A.ARW"), size: 1, modified: date))
    }

    @Test func `many threads storing into a new pack at once lose nothing`() {
        defer { try? FileManager.default.removeItem(at: directory) }
        for round in 0 ..< 20 {
            let packs = ThumbnailPacks(directory: directory)
            let folder = URL(fileURLWithPath: "/Photos/Round \(round)")
            DispatchQueue.concurrentPerform(iterations: 64) { index in
                packs.store(
                    Data(repeating: UInt8(index), count: 2000), for: folder.appending(path: "\(index).ARW"), size: 1,
                    modified: date,
                )
            }
            let reopened = ThumbnailPacks(directory: directory)
            let found = (0 ..< 64).count {
                reopened.jpeg(for: folder.appending(path: "\($0).ARW"), size: 1, modified: date)
                    == Data(repeating: UInt8($0), count: 2000)
            }
            #expect(found == 64, "round \(round)")
        }
    }

    @Test func `thumbnails round-trip through JPEG`() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 192, height: 128, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 192, height: 128))
        let image = try #require(context.makeImage())
        let jpeg = try #require(ThumbnailPacks.encode(image))
        #expect(jpeg.count < 20000)
        let decoded = try #require(ThumbnailPacks.decode(jpeg))
        #expect(decoded.width == 192 && decoded.height == 128)
    }
}
