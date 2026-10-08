import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import RedlampEngineAPI
import RedlampMasking
import Testing
import UniformTypeIdentifiers
@testable import RedlampEngine
@testable import RedlampServices

/// A photo's embedded mattes are found once, while its session is built, so asking which masks
/// it offers never reads the file again.
struct EmbeddedMattesTests {
    private static func fixture(_ name: String) -> URL? {
        EngineSmokeTests.fixtures.first { $0.lastPathComponent == name }
    }

    @Test(.enabled(if: EngineSmokeTests.canRender && fixture("IMG_1361.DNG") != nil))
    func `the session keeps the mattes its file carries`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appending(path: "IMG_1361.DNG")
        try FileManager.default.copyItem(at: #require(Self.fixture("IMG_1361.DNG")), to: copy)
        let engine = try RedlampEngine()
        _ = try await engine.open(copy)

        try FileManager.default.removeItem(at: copy)
        #expect(EmbeddedMattes.available(in: copy).isEmpty, "the file is gone")
        #expect(engine.currentSession()?.embeddedMattes == [.sky])
    }

    @Test(.enabled(if: EngineSmokeTests.canRender && fixture("DSC_0750.NEF") != nil))
    func `a photo without mattes has none`() async throws {
        let engine = try RedlampEngine()
        _ = try await engine.open(#require(Self.fixture("DSC_0750.NEF")))
        #expect(engine.currentSession()?.embeddedMattes == [])
    }
}

/// The mattes a file carries are found and read in the decode service, from the bytes it is sent,
/// as the app read them itself.
struct EmbeddedMatteServiceTests {
    /// A listener in this process that answers as the service does, through a real connection.
    final class Listener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        let listener = NSXPCListener.anonymous()
        let exported = DecodeService()

        override init() {
            super.init()
            listener.delegate = self
            listener.resume()
        }

        func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: DecodeServiceProtocol.self)
            connection.exportedObject = exported
            connection.resume()
            return true
        }
    }

    /// An iPhone-style HEIC carrying `mattes`, each `width` × `height` with rows padded as the
    /// camera pads them, in a photo turned by `orientation`.
    static func heic(
        _ mattes: [(type: CFString, format: OSType)], orientation: Int, in folder: URL, name: String,
    ) throws -> URL {
        let (width, height) = (24, 18)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 48, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 36))
        let url = folder.appending(path: name)
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.heic.identifier as CFString, 1, nil,
        ))
        try CGImageDestinationAddImage(
            destination, #require(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary,
        )
        for (index, matte) in mattes.enumerated() {
            let bytesPerValue = switch matte.format {
            case kCVPixelFormatType_DisparityFloat16: 2
            case kCVPixelFormatType_DepthFloat32: 4
            default: 1
            }
            let rowBytes = width * bytesPerValue + 16
            var data = Data(count: rowBytes * height)
            data.withUnsafeMutableBytes { bytes in
                for y in 0 ..< height {
                    for x in 0 ..< width {
                        let offset = y * rowBytes + x * bytesPerValue
                        let value = Float((x * 7 + y * 13 + index * 29) % 97) / 96
                        switch bytesPerValue {
                        case 2: bytes.storeBytes(of: Float16(value * 3 + 0.25), toByteOffset: offset, as: Float16.self)
                        case 4: bytes.storeBytes(of: value * 5 + 0.5, toByteOffset: offset, as: Float.self)
                        default: bytes[offset] = UInt8(value * 255)
                        }
                    }
                }
            }
            let description: [String: Any] = [
                "Width": width, "Height": height, "BytesPerRow": rowBytes, "PixelFormat": matte.format,
            ]
            CGImageDestinationAddAuxiliaryDataInfo(destination, matte.type, [
                kCGImageAuxiliaryDataInfoData: data, kCGImageAuxiliaryDataInfoDataDescription: description,
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// iPhone HEICs with every matte (one with disparity, one with depth), the iPhone ProRAW
    /// fixture with its sky, and a raw and a JPEG with none.
    static func files(in folder: URL) throws -> [URL] {
        let parts: [(CFString, OSType)] = [
            kCGImageAuxiliaryDataTypePortraitEffectsMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte,
        ].map { ($0, kCVPixelFormatType_OneComponent8) }
        let disparity = try heic(
            parts + [(kCGImageAuxiliaryDataTypeDisparity, kCVPixelFormatType_DisparityFloat16)],
            orientation: 6, in: folder, name: "IMG_0001.HEIC",
        )
        let depth = try heic(
            [(kCGImageAuxiliaryDataTypeDepth, kCVPixelFormatType_DepthFloat32)],
            orientation: 3, in: folder, name: "IMG_0002.HEIC",
        )
        let jpeg = folder.appending(path: "plain.jpg")
        let source = try #require(CGImageSourceCreateWithURL(disparity as CFURL, nil))
        let destination = try #require(CGImageDestinationCreateWithURL(
            jpeg as CFURL, UTType.jpeg.identifier as CFString, 1, nil,
        ))
        try CGImageDestinationAddImage(destination, #require(CGImageSourceCreateImageAtIndex(source, 0, nil)), nil)
        #expect(CGImageDestinationFinalize(destination))
        let fixtures = ["IMG_1361.DNG", "DSC_0750.NEF"].compactMap { name in
            EngineSmokeTests.fixtures.first { $0.lastPathComponent == name }
        }
        return [disparity, depth, jpeg] + fixtures
    }

    @Test func `the service finds and reads each file's mattes as the app did`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try Self.files(in: folder)
        let listener = Listener()
        let service = DecodeServiceClient(endpoint: listener.listener.endpoint)
        let inProcess = InProcessDecoder()

        #expect(EmbeddedMattes.available(in: files[0]) == Set(EmbeddedMatte.allCases))
        #expect(EmbeddedMattes.available(in: files[1]) == [.depth])
        #expect(EmbeddedMattes.available(in: files[2]).isEmpty)
        for file in files {
            let name = file.lastPathComponent
            let kinds = EmbeddedMattes.available(in: file)
            #expect(inProcess.embeddedMattes(in: file) == kinds, "\(name) in this process")
            for matte in EmbeddedMatte.allCases {
                let app = EmbeddedMattes.read(matte, from: file)
                #expect((app != nil) == kinds.contains(matte), "\(name): \(matte)")
                #expect(inProcess.embeddedMatte(matte, in: file).map(GrayMask.init) == app, "\(name): \(matte)")
            }
            guard !kinds.isEmpty else {
                #expect(service.embeddedMattes(in: file).isEmpty, "\(name) in the service")
                continue
            }
            withKnownIssue("The service reads no matte until it is asked to") {
                #expect(service.embeddedMattes(in: file) == kinds, "\(name) in the service")
                for matte in kinds {
                    let app = EmbeddedMattes.read(matte, from: file)
                    #expect(service.embeddedMatte(matte, in: file).map(GrayMask.init) == app, "\(name): \(matte)")
                }
            }
        }
    }
}

/// Opening a photo and making its masks asks the engine's decoder for the file's mattes, so the
/// Mac app reads them in the decode service.
struct EmbeddedMatteDecoderTests {
    /// Decodes in this process, and says every file has a sky and a hair matte of its own.
    final class RecordingDecoder: ImageDecoding, FileInspecting, @unchecked Sendable {
        private let decoder = InProcessDecoder()
        private let lock = NSLock()
        private var calls: [String] = []

        var asked: [String] {
            lock.withLock { calls }
        }

        static let matte = EmbeddedMatteImage(
            width: 8, height: 6, coverage: (0 ..< 48).map { $0 < 24 ? 1 : 0 }, orientation: 1,
        )

        func decode(_ url: URL) throws -> DecodedImage {
            try decoder.decode(url)
        }

        func captures(of urls: [URL], concurrently: Bool) -> [CaptureSettings?] {
            decoder.captures(of: urls, concurrently: concurrently)
        }

        func focusThumbnails(of urls: [URL], concurrently: Bool) -> [GreyThumbnail?] {
            decoder.focusThumbnails(of: urls, concurrently: concurrently)
        }

        func imageProperties(of urls: [URL]) -> [ImageProperties?] {
            decoder.imageProperties(of: urls)
        }

        func haldImage(of url: URL) -> HaldImage? {
            decoder.haldImage(of: url)
        }

        func embeddedMattes(in _: URL) -> Set<EmbeddedMatte> {
            lock.withLock { calls.append("mattes") }
            return [.sky, .hair]
        }

        func embeddedMatte(_ matte: EmbeddedMatte, in _: URL) -> EmbeddedMatteImage? {
            lock.withLock { calls.append(matte.rawValue) }
            return [.sky, .hair].contains(matte) ? Self.matte : nil
        }
    }

    @Test(.enabled(if: EngineSmokeTests.canRender
            && EngineSmokeTests.fixtures.contains { $0.lastPathComponent == "DSC_0750.NEF" }))
    func `opening a photo and making Sky, Hair and Subject masks asks the decoder for its mattes`() async throws {
        let decoder = RecordingDecoder()
        let engine = try RedlampEngine(decoder: decoder)
        _ = try await engine.open(#require(EngineSmokeTests.fixtures.first { $0.lastPathComponent == "DSC_0750.NEF" }))

        withKnownIssue("The engine reads mattes itself until it asks its decoder") {
            #expect(decoder.asked == ["mattes"])
            #expect(engine.currentSession()?.embeddedMattes == [.sky, .hair])
        }
        let sky = try? await engine.computeMasks(MaskRequest(kind: .sky))
        let hair = try? await engine.computeMasks(MaskRequest(kind: .people, part: .hair))
        withKnownIssue("The engine reads mattes itself until it asks its decoder") {
            #expect(sky?.map(\.provider) == ["apple.embedded.sky"])
            #expect(hair?.map(\.provider) == ["apple.embedded.hair"])
            #expect(decoder.asked.filter { $0 != "mattes" }.allSatisfy { ["sky", "hair"].contains($0) })
            #expect(decoder.asked.contains("sky") && decoder.asked.contains("hair"))
        }
        let before = decoder.asked
        _ = try? await engine.computeMasks(MaskRequest(kind: .subject))
        #expect(decoder.asked == before, "a Subject mask reads no matte")
    }
}
