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

    // MARK: - In the decode service (DATA-17)

    /// Every sample, a Nikon HE NEF and a damaged raw, the last two in a folder of their own.
    static func parityFiles() throws -> (files: [URL], highEfficiency: URL, damaged: URL, cleanup: () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let highEfficiency = try Self.highEfficiencyNEF(in: folder)
        let damaged = folder.appending(path: "damaged.CR3")
        try Data(repeating: 7, count: 4096).write(to: damaged)
        return (samples + [highEfficiency, damaged], highEfficiency, damaged, {
            try? FileManager.default.removeItem(at: folder)
        })
    }

    /// DSC_0750.NEF with its raw image opening on JPEG XS's markers, as an HE NEF's does.
    static func highEfficiencyNEF(in folder: URL) throws -> URL {
        let source = try #require(samples.first { $0.lastPathComponent == "DSC_0750.NEF" })
        var data = try Data(contentsOf: source)
        let strip = data.withUnsafeBytes { bytes in
            TIFFReader(bytes: bytes).flatMap { reader in
                reader.imageFileDirectories().lazy.compactMap { entries -> Int? in
                    let tags = Dictionary(entries.map { ($0.tag, $0) }) { first, _ in first }
                    let value = { (tag: UInt16) in tags[tag].flatMap { reader.integers($0).first } }
                    guard value(254) ?? 0 == 0, value(259) == NikonHighEfficiency.nefCompression,
                          value(256) ?? 0 > 0
                    else { return nil }
                    return value(273)
                }.first
            }
        }
        let offset = try #require(strip)
        data.replaceSubrange(offset ..< offset + NikonHighEfficiency.markers.count, with: NikonHighEfficiency.markers)
        #expect(NikonHighEfficiency.isHighEfficiency(data))
        let url = folder.appending(path: "DSC_0750_HE.NEF")
        try data.write(to: url)
        return url
    }

    /// An image's colour space and its pixels drawn in sRGB, 8 bits a channel.
    static func drawn(_ image: CGImage?) -> (profile: Data?, width: Int, height: Int, pixels: [UInt8])? {
        guard let image, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image.colorSpace?.copyICCData() as Data?, image.width, image.height, pixels)
    }

    @Test(.enabled(if: samples.count > 1))
    func `the decode service identifies each file as the app does`() throws {
        let (files, highEfficiency, damaged, cleanup) = try Self.parityFiles()
        defer { cleanup() }
        let local = files.map { ImageDecoder.identify($0) }
        #expect(local.allSatisfy { $0 != nil })
        #expect(try local[#require(files.firstIndex(of: highEfficiency))]?.decoder == NikonHighEfficiency.libRawDecoder)
        #expect(try local[#require(files.firstIndex(of: damaged))]?.refusal != nil)
        #expect(InProcessDecoder().rawIdentities(of: files) == local)

        let listener = FileInspectionTests.Listener()
        let service = DecodeServiceClient(endpoint: listener.listener.endpoint)
        withKnownIssue("the decode service doesn't identify files yet") {
            let served = service.rawIdentities(of: files)
            for (url, (served, local)) in zip(files, zip(served, local)) {
                #expect(served == local, "\(url.lastPathComponent)")
            }
            #expect(served.count == files.count)
        }
    }

    @Test(.enabled(if: samples.count > 1))
    func `the decode service's camera previews are the app's, pixel for pixel`() throws {
        let (files, _, damaged, cleanup) = try Self.parityFiles()
        defer { cleanup() }
        let size = 1024
        let local = files.map { Thumbnails.cameraPreview(of: $0, maxPixelSize: size) }
        #expect(local.compactMap(\.self).count >= files.count - 5)
        #expect(try local[#require(files.firstIndex(of: damaged))] == nil)

        let listener = FileInspectionTests.Listener()
        let service = DecodeServiceClient(endpoint: listener.listener.endpoint)
        withKnownIssue("the decode service doesn't read camera previews yet") {
            let served = service.cameraPreviews(of: files, maxLongEdge: size)
            #expect(served.count == files.count)
            for (url, (served, local)) in zip(files, zip(served, local)) {
                let (theirs, ours) = (Self.drawn(served), Self.drawn(local))
                #expect(theirs?.profile == ours?.profile, "\(url.lastPathComponent)")
                #expect(theirs?.width == ours?.width && theirs?.height == ours?.height, "\(url.lastPathComponent)")
                #expect(theirs?.pixels == ours?.pixels, "\(url.lastPathComponent)")
            }
        }
    }
}
