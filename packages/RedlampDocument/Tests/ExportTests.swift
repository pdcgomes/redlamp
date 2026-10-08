import CoreGraphics
import Foundation
import ImageIO
import RedlampDocument
import RedlampEngineAPI
import Testing

/// Reads a file's ImageIO properties as RedlampServices' `InProcessDecoder` does, which the
/// decode service is checked against.
struct ImageIOFiles: FileInspecting {
    func captures(of urls: [URL], concurrently _: Bool) -> [CaptureSettings?] {
        urls.map { _ in nil }
    }

    func focusThumbnails(of urls: [URL], concurrently _: Bool) -> [GreyThumbnail?] {
        urls.map { _ in nil }
    }

    func imageProperties(of urls: [URL]) -> [ImageProperties?] {
        urls.map { url in
            CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                .flatMap(ImageProperties.init)
        }
    }

    func haldImage(of _: URL) -> HaldImage? {
        nil
    }

    func embeddedMattes(in _: URL) -> Set<EmbeddedMatte> {
        []
    }

    func embeddedMatte(_: EmbeddedMatte, in _: URL) -> EmbeddedMatteImage? {
        nil
    }
}

/// Export takes what it reads from files from its reader, which in the app is the decode service.
struct ExportReadingTests {
    /// Answers properties from a table, by URL, and records what it was asked.
    final class RecordedProperties: FileInspecting, @unchecked Sendable {
        private let properties: [URL: ImageProperties]
        private let lock = NSLock()
        private var urls: [URL] = []

        var asked: [URL] {
            lock.withLock { urls }
        }

        init(_ properties: [URL: [CFString: Any]]) {
            self.properties = properties.compactMapValues(ImageProperties.init)
        }

        func captures(of urls: [URL], concurrently _: Bool) -> [CaptureSettings?] {
            urls.map { _ in nil }
        }

        func focusThumbnails(of urls: [URL], concurrently _: Bool) -> [GreyThumbnail?] {
            urls.map { _ in nil }
        }

        func imageProperties(of urls: [URL]) -> [ImageProperties?] {
            lock.withLock { self.urls += urls }
            return urls.map { properties[$0] }
        }

        func haldImage(of _: URL) -> HaldImage? {
            nil
        }

        func embeddedMattes(in _: URL) -> Set<EmbeddedMatte> {
            []
        }

        func embeddedMatte(_: EmbeddedMatte, in _: URL) -> EmbeddedMatteImage? {
            nil
        }
    }

    @Test func `an export's metadata comes from the reader, not the file`() {
        let source = URL(fileURLWithPath: "/nowhere/IMG_0001.ARW")
        let files = RecordedProperties([source: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Z 8"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 38.7],
        ]])
        let metadata = ExportMetadata.properties(from: source, reading: files, policy: .all)
        let tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFModel] as? String == "Z 8")
        #expect(tiff?[kCGImagePropertyTIFFSoftware] as? String == ExportMetadata.software)
        #expect(metadata[kCGImagePropertyGPSDictionary] != nil)
        #expect(files.asked == [source])
        _ = ExportMetadata.properties(from: source, reading: files, policy: .none)
        #expect(files.asked == [source], "an export without metadata reads nothing")
    }

    @Test func `whether a file is an export is read through the reader`() throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let file = folder.appending(path: "IMG_0001.jpg")
        try Data("not an image".utf8).write(to: file)
        let files = RecordedProperties([file: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFSoftware: "\(ExportMetadata.software) 0.2.5"],
        ]])
        #expect(ExportMetadata.isExport(file, reading: files))
        #expect(!ExportDestination.isPhoto(file, source: nil, reading: files))
        #expect(files.asked == [file, file])
        #expect(ExportDestination.isPhoto(file, source: nil, reading: UnreadableFiles()), "one it can't read is kept")
    }

    @Test func `an export, a camera JPEG and a damaged file are told apart`() throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let export = folder.appending(path: "IMG_0001.jpg")
        try ImageExporter.write(
            ExportWriterTests.image(),
            to: export,
            settings: ExportSettings(),
            reading: ImageIOFiles(),
        )
        let camera = folder.appending(path: "IMG_0002.JPG")
        let destination = try #require(CGImageDestinationCreateWithURL(
            camera as CFURL,
            "public.jpeg" as CFString,
            1,
            nil,
        ))
        CGImageDestinationAddImage(destination, ExportWriterTests.image(width: 64, height: 48), [
            kCGImagePropertyOrientation: 1, kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Nikon"],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let damaged = folder.appending(path: "IMG_0003.jpg")
        try Data(repeating: 7, count: 4096).write(to: damaged)
        #expect(ExportMetadata.isExport(export, reading: ImageIOFiles()))
        #expect(!ExportMetadata.isExport(camera, reading: ImageIOFiles()))
        #expect(!ExportMetadata.isExport(damaged, reading: ImageIOFiles()))
    }
}

struct ExportWriterTests {
    /// A gradient with some noise, so lossy sizes respond to quality.
    static func image(
        bits: Int = 8,
        width: Int = 256,
        height: Int = 192,
        space: CFString = CGColorSpace.sRGB,
    ) -> CGImage {
        let bytesPerPixel = bits == 16 ? 8 : 4
        var data = Data(count: width * height * bytesPerPixel)
        var seed: UInt32 = 7
        data.withUnsafeMutableBytes { raw in
            for y in 0 ..< height {
                for x in 0 ..< width {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let noise = Int(seed >> 28)
                    let rgb = [x * 255 / width, y * 255 / height, (x + y + noise * 8) % 256]
                    let index = (y * width + x) * 4
                    for channel in 0 ..< 4 {
                        let value = channel == 3 ? 255 : rgb[channel]
                        if bits == 16 {
                            raw.storeBytes(
                                of: UInt16(value * 257),
                                toByteOffset: (index + channel) * 2,
                                as: UInt16.self,
                            )
                        } else {
                            raw.storeBytes(of: UInt8(value), toByteOffset: index + channel, as: UInt8.self)
                        }
                    }
                }
            }
        }
        let info = CGImageAlphaInfo.noneSkipLast
            .rawValue | (bits == 16 ? CGImageByteOrderInfo.order16Little.rawValue : 0)
        return CGImage(
            width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bytesPerPixel * 8,
            bytesPerRow: width * bytesPerPixel, space: CGColorSpace(name: space)!,
            bitmapInfo: CGBitmapInfo(rawValue: info), provider: CGDataProvider(data: data as CFData)!,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent,
        )!
    }

    static func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    static func temporaryFolder() throws -> (URL, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, { try? FileManager.default.removeItem(at: folder) })
    }

    @Test(arguments: [
        (ExportFormat.jpeg, 8, 8), (.jpeg, 16, 8),
        (.heic, 8, 8), (.heic, 16, 10),
        (.avif, 8, 8), (.avif, 16, 10),
        (.png, 8, 8), (.png, 16, 16),
        (.tiff, 8, 8), (.tiff, 16, 16),
    ])
    func `each format keeps its type, depth, profile and resolution`(
        format: ExportFormat,
        bits: Int,
        depth: Int,
    ) throws {
        var settings = ExportSettings()
        settings.setFormat(format)
        settings.sizing.ppi = 240
        let data = try ImageExporter.encode(Self.image(bits: bits, space: CGColorSpace.displayP3), settings: settings)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == format.typeIdentifier)
        let properties = try Self.properties(data)
        #expect(properties[kCGImagePropertyDepth] as? Int == depth)
        #expect(properties[kCGImagePropertyProfileName] as? String == "Display P3")
        #expect(properties[kCGImagePropertyDPIWidth] as? Int == 240)
        #expect(properties[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
    }

    @Test(arguments: TIFFCompression.allCases)
    func `TIFF compression is written`(compression: TIFFCompression) throws {
        var settings = ExportSettings()
        settings.setFormat(.tiff)
        settings.tiffCompression = compression
        let data = try ImageExporter.encode(Self.image(bits: 16), settings: settings)
        let tiff = try #require(Self.properties(data)[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        let expected = switch compression {
        case .none: 1
        case .lzw: 5
        case .zip: 8
        }
        #expect(tiff[kCGImagePropertyTIFFCompression] as? Int == expected)
    }

    @Test func `AVIF at quality 100 encodes`() throws {
        var settings = ExportSettings()
        settings.setFormat(.avif)
        settings.quality = 100
        #expect(try ImageExporter.encode(Self.image(), settings: settings).count > 0)
    }

    @Test func `quality changes the size of lossy files`() throws {
        var settings = ExportSettings()
        settings.quality = 95
        let high = try ImageExporter.encode(Self.image(), settings: settings)
        settings.quality = 20
        let low = try ImageExporter.encode(Self.image(), settings: settings)
        #expect(low.count < high.count)
    }

    @Test(arguments: ExportFormat.lossy)
    func `a file size limit is met`(format: ExportFormat) throws {
        var settings = ExportSettings()
        settings.setFormat(format)
        settings.quality = 100
        let unlimited = try ImageExporter.encode(Self.image(width: 512, height: 384), settings: settings)
        settings.limitsFileSize = true
        settings.fileSizeLimitKB = max(1, unlimited.count / 2000)
        let limited = try ImageExporter.encode(Self.image(width: 512, height: 384), settings: settings)
        #expect(limited.count <= settings.fileSizeLimitKB * 1000)
    }

    @Test func `an unreachable size limit throws`() {
        var settings = ExportSettings()
        settings.limitsFileSize = true
        settings.fileSizeLimitKB = 1
        #expect(throws: ExportError.self) {
            try ImageExporter.encode(Self.image(width: 1024, height: 768), settings: settings)
        }
    }

    @Test func `lossless formats ignore the size limit`() throws {
        var settings = ExportSettings()
        settings.setFormat(.png)
        settings.limitsFileSize = true
        settings.fileSizeLimitKB = 1
        #expect(try ImageExporter.encode(Self.image(), settings: settings).count > 1000)
    }

    @Test func `a missing folder throws`() {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "out.jpg")
        #expect(throws: ExportError.folderMissing(url.deletingLastPathComponent())) {
            try ImageExporter.write(Self.image(), to: url, settings: ExportSettings(), reading: ImageIOFiles())
        }
    }
}

struct ExportMetadataTests {
    /// A JPEG shot "sideways", with a capture date, a camera, a location and a city.
    private func source(in folder: URL) throws -> URL {
        let url = folder.appending(path: "IMG_0001.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:01 12:00:00",
                kCGImagePropertyExifFNumber: 2.8,
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Nikon", kCGImagePropertyTIFFModel: "Z 8"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 38.7, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCity: "Lisbon",
                kCGImagePropertyIPTCCopyrightNotice: "© Pedro",
            ],
        ]
        CGImageDestinationAddImage(
            destination,
            ExportWriterTests.image(width: 64, height: 48),
            properties as CFDictionary,
        )
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func exported(_ policy: ExportMetadataPolicy) throws -> [CFString: Any] {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let metadata = try ExportMetadata.properties(from: source(in: folder), reading: ImageIOFiles(), policy: policy)
        let data = try ImageExporter.encode(ExportWriterTests.image(), settings: ExportSettings(), metadata: metadata)
        return try ExportWriterTests.properties(data)
    }

    @Test func `all keeps the camera, date and location`() throws {
        let properties = try exported(.all)
        let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:10:01 12:00:00")
        let tiff = try #require(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        #expect(tiff[kCGImagePropertyTIFFModel] as? String == "Z 8")
        #expect(tiff[kCGImagePropertyTIFFSoftware] as? String == "Redlamp")
        #expect(properties[kCGImagePropertyGPSDictionary] != nil)
        let iptc = try #require(properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any])
        #expect(iptc[kCGImagePropertyIPTCCity] as? String == "Lisbon")
    }

    @Test func `all except location drops GPS and the city`() throws {
        let properties = try exported(.allExceptLocation)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let iptc = try #require(properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any])
        #expect(iptc[kCGImagePropertyIPTCCity] == nil)
        #expect(iptc[kCGImagePropertyIPTCCopyrightNotice] as? String == "© Pedro")
        let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] != nil)
    }

    @Test func `none drops the camera metadata`() throws {
        let properties = try exported(.none)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFModel] == nil)
    }

    @Test(arguments: ExportMetadataPolicy.allCases)
    func `exports are always upright`(policy: ExportMetadataPolicy) throws {
        #expect(try exported(policy)[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
    }
}

struct ExportSizingTests {
    private let landscape = PixelSize(width: 6000, height: 4000)
    private let portrait = PixelSize(width: 4000, height: 6000)
    private let square = PixelSize(width: 3000, height: 3000)

    private func sizing(_ mode: ExportSizing.Mode, _ configure: (inout ExportSizing) -> Void = { _ in
    }) -> ExportSizing {
        var sizing = ExportSizing(mode: mode)
        configure(&sizing)
        return sizing
    }

    @Test func `each mode resolves to the expected size`() {
        #expect(sizing(.full).resolve(landscape) == landscape)
        #expect(sizing(.longEdge) { $0.longEdge = 2048 }.resolve(landscape) == PixelSize(width: 2048, height: 1365))
        #expect(sizing(.longEdge) { $0.longEdge = 2048 }.resolve(portrait) == PixelSize(width: 1365, height: 2048))
        #expect(sizing(.shortEdge) { $0.shortEdge = 1080 }.resolve(portrait) == PixelSize(width: 1080, height: 1620))
        #expect(sizing(.dimensions) {
            $0.width = 1920
            $0.height = 1080
        }.resolve(landscape) == PixelSize(width: 1620, height: 1080))
        #expect(sizing(.megapixels) { $0.megapixels = 6 }.resolve(landscape) == PixelSize(width: 3000, height: 2000))
        #expect(sizing(.percentage) { $0.percentage = 25 }.resolve(square) == PixelSize(width: 750, height: 750))
    }

    @Test func `never enlarges`() {
        let small = PixelSize(width: 1200, height: 800)
        #expect(sizing(.longEdge) { $0.longEdge = 4000 }.resolve(small) == small)
        #expect(sizing(.longEdge) { $0.longEdge = 4000 }.maxLongEdge(for: small) == nil)
        #expect(sizing(.megapixels) { $0.megapixels = 50 }.resolve(small) == small)
        #expect(sizing(.full).maxLongEdge(for: small) == nil)
    }

    @Test func `the engine's long-edge fit lands on the resolved size`() {
        for width in stride(from: 3001, through: 6007, by: 97) {
            for height in [2000, 2667, 3333, 4001, 4499] {
                let source = PixelSize(width: width, height: height)
                for sizing in [
                    sizing(.shortEdge) { $0.shortEdge = 1080 },
                    sizing(.dimensions) {
                        $0.width = 1920
                        $0.height = 1080
                    },
                    sizing(.megapixels) { $0.megapixels = 2 },
                ] {
                    let resolved = sizing.resolve(source)
                    let limit = sizing.maxLongEdge(for: source) ?? source.longEdge
                    #expect(source.fitted(within: PixelSize(width: limit, height: limit)) == resolved)
                    if sizing.mode == .shortEdge {
                        #expect(min(resolved.width, resolved.height) == 1080, "\(source)")
                    }
                    if sizing.mode == .dimensions {
                        #expect(resolved.width <= 1920 && resolved.height <= 1080, "\(source)")
                    }
                }
            }
        }
    }
}

struct ExportSettingsTests {
    private let source = URL(fileURLWithPath: "/Photos/IMG_1234.NEF")

    @Test func `names follow the rule and the format`() {
        var settings = ExportSettings()
        #expect(ExportDestination.url(for: source, settings: settings, reading: ImageIOFiles())
            .path == "/Photos/IMG_1234-redlamp.jpg")
        settings.setFormat(.tiff)
        settings.naming = ExportNaming(mode: .custom, customName: " Harbour: dusk/2 ")
        settings.destinationFolder = URL(fileURLWithPath: "/Exports")
        #expect(ExportDestination.url(for: source, settings: settings, reading: ImageIOFiles())
            .path == "/Exports/Harbour- dusk-2.tif")
        settings.naming = ExportNaming(mode: .custom, customName: "  ")
        #expect(!settings.naming.isValid)
        #expect(ExportDestination.url(for: source, settings: settings, reading: ImageIOFiles())
            .lastPathComponent == "IMG_1234.tif")
    }

    @Test func `numbering skips names that are taken`() throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let url = folder.appending(path: "IMG_1234-redlamp.jpg")
        #expect(ExportDestination.firstFree(url) == url)
        try Data().write(to: url)
        try Data().write(to: folder.appending(path: "IMG_1234-redlamp-2.jpg"))
        #expect(ExportDestination.firstFree(url).lastPathComponent == "IMG_1234-redlamp-3.jpg")
    }

    @Test func `changing format keeps a bit depth it can hold`() {
        var settings = ExportSettings()
        settings.setFormat(.png)
        settings.bitDepth = 16
        settings.setFormat(.tiff)
        #expect(settings.bitDepth == 16)
        settings.setFormat(.heic)
        #expect(settings.bitDepth == 8)
        settings.bitDepth = 10
        #expect(settings.bitsPerComponent == 16)
        settings.setFormat(.jpeg)
        #expect(settings.bitsPerComponent == 8)
    }

    @Test func `the still request follows the settings`() {
        var settings = ExportSettings()
        settings.setFormat(.avif)
        settings.bitDepth = 10
        settings.colorSpace = .displayP3
        settings.sizing = ExportSizing(mode: .longEdge)
        settings.sizing.longEdge = 1000
        let request = settings.stillRequest(
            recipe: EditRecipe(),
            source: source,
            size: PixelSize(width: 6000, height: 4000),
        )
        #expect(request.maxLongEdge == 1000)
        #expect(request.bitsPerComponent == 16)
        #expect(request.colorSpace == .displayP3)
        #expect(request.purpose == .export)
        #expect(request.source == source)
    }

    @Test func `settings round trip and missing keys take defaults`() throws {
        var settings = ExportSettings()
        settings.setFormat(.heic)
        settings.limitsFileSize = true
        settings.sizing = ExportSizing(mode: .megapixels)
        settings.destinationFolder = URL(fileURLWithPath: "/Exports")
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(ExportSettings.self, from: data) == settings)

        let old = #"{"format":"png","quality":70,"sizing":{"mode":"longEdge"},"future":true}"#
        let decoded = try JSONDecoder().decode(ExportSettings.self, from: Data(old.utf8))
        #expect(decoded.format == .png)
        #expect(decoded.quality == 70)
        #expect(decoded.sizing.mode == .longEdge)
        #expect(decoded.sizing.longEdge == ExportSizing().longEdge)
        #expect(decoded.naming == ExportNaming())

        let newer = #"{"format":"jxl","metadata":"copyrightOnly"}"#
        let fallback = try JSONDecoder().decode(ExportSettings.self, from: Data(newer.utf8))
        #expect(fallback.format == .jpeg)
        #expect(fallback.metadata == .all)
    }

    @Test func `built-in presets are distinct`() {
        let presets = ExportPreset.builtIns
        #expect(Set(presets.map(\.id)).count == presets.count)
        let anyCustom = presets.contains { !$0.isBuiltIn }
        #expect(!anyCustom)
        #expect(!ExportPreset(name: "Mine", settings: ExportSettings()).isBuiltIn)
    }
}
