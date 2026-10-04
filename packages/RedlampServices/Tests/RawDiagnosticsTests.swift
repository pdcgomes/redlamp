import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI
import Testing
@testable import RedlampServices

/// The decode diagnostics the camera bench judges (CAM-14), on every sample camera.
struct RawDiagnosticsTests {
    static let samples = DecodeRegressionTests.fixtures + DecodeRegressionTests.cameras
    /// Newer Canon CR3s embed their preview as HEVC, which isn't a JPEG to compare with.
    static let hevcPreviews: Set = ["Canon_EOS-R5-Mark-II.CR3"]

    @Test(.enabled(if: !samples.isEmpty), .serialized, arguments: samples)
    func `every sample's decode carries its identity and measurements`(url: URL) throws {
        let image = try ImageDecoder.decode(url)
        let diagnostics = try #require(image.info.diagnostics)
        let identity = diagnostics.identity
        let measured = diagnostics.measurements
        #expect(identity.decoder != nil)
        #expect(identity.normalizedMake != nil && identity.normalizedModel != nil)
        #expect(identity.imageSize == PixelSize(width: image.width, height: image.height))
        #expect(identity.refusal == nil)
        #expect(
            measured.black < measured.white,
            "\(url.lastPathComponent): black \(measured.black), white \(measured.white)",
        )
        #expect(
            measured.darkEdges?.widest ?? 0 == 0,
            "\(url.lastPathComponent): dark edges \(String(describing: measured.darkEdges))",
        )
        if let optical = measured.opticalBlack, let noise = measured.opticalBlackNoise {
            #expect(
                abs(optical - measured.black) <= max(2, 3 * noise),
                "\(url.lastPathComponent): margins at \(optical), black \(measured.black)",
            )
        }
    }

    @Test(.enabled(if: !samples.isEmpty), arguments: samples.prefix(6))
    func `identifying a file agrees with decoding it`(url: URL) throws {
        let identified = try #require(ImageDecoder.identify(url))
        let decoded = try #require(try ImageDecoder.decode(url).info.diagnostics?.identity)
        #expect(identified == decoded)
    }

    @Test(.enabled(if: !samples.isEmpty), arguments: samples)
    func `a file that lists a preview gives the camera's JPEG`(url: URL) throws {
        let identity = try #require(ImageDecoder.identify(url))
        guard identity.previews.contains(where: { max($0.width, $0.height) >= 640 }),
              !Self.hevcPreviews.contains(url.lastPathComponent)
        else { return }
        let preview = try #require(Thumbnails.cameraPreview(of: url, maxPixelSize: 1024), "\(url.lastPathComponent)")
        #expect(max(preview.width, preview.height) >= 640)
    }

    @Test(.enabled(if: !samples.isEmpty))
    func `the decode service's archive carries the diagnostics`() throws {
        let url = try #require(Self.samples.first)
        let image = try ImageDecoder.decode(url)
        let restored = try DecodedImage(archive: image.archived())
        #expect(restored.info.diagnostics == image.info.diagnostics)
    }

    @Test func `a strip at the black level along an edge is found`() {
        let (width, height) = (240, 120)
        var samples = (0 ..< width * height).map { UInt16(3000 + ($0 * 7919) % 200) }
        for y in height - 9 ..< height {
            for x in 0 ..< width {
                samples[y * width + x] = UInt16(512 + (x % 3))
            }
        }
        let edges = RawMeasurement.darkEdges(samples, width: width, height: height, black: 512, white: 16383)
        #expect(edges == DarkEdges(bottom: 9))
    }

    @Test func `a dark frame has no strips`() {
        let samples = [UInt16](repeating: 514, count: 240 * 120)
        #expect(RawMeasurement.darkEdges(samples, width: 240, height: 120, black: 512, white: 16383) == DarkEdges())
    }

    @Test func `a file LibRaw refuses is identified from its EXIF`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "refused.NEF")
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "NIKON CORPORATION",
                kCGImagePropertyTIFFModel: "NIKON Z 8",
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [400]],
        ]
        let image = try #require(context.makeImage())
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let identity = try #require(ImageDecoder.identify(url))
        #expect(identity.refusal != nil)
        #expect(identity.model == "NIKON Z 8")
        #expect(identity.iso == 400)
        #expect(identity.format == "NEF")
    }

    @Test func `bitmaps aren't identified`() {
        #expect(ImageDecoder.identify(URL(fileURLWithPath: "/tmp/photo.jpg")) == nil)
    }
}
