import CoreGraphics
import Foundation
import ImageIO
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampLibrary

/// The library's metadata comes from each file's first 256 KiB, read once, and reads as it would from
/// the whole file.
struct PhotoMetadataReaderTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// The development samples and the camera coverage set (`mise run fixtures`), where ImageIO reads
    /// them: on macOS 26 it reads every one.
    static let raws = (raws(in: "tests/fixtures/raw") + raws(in: "tests/fixtures/cameras")).filter { url in
        CGImageSourceCreateWithURL(url as CFURL, nil).map { CGImageSourceGetCount($0) > 0 } ?? false
    }

    static func raws(in folder: String) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root.appending(path: folder), includingPropertiesForKeys: nil,
        )) ?? []
        return files.filter(SupportedFormats.isRaw).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A file's first bytes and its size, as the indexer reads them.
    static func head(of url: URL, length: Int = PhotoMetadataReader.headLength) throws -> (head: Data, size: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: length) ?? Data()
        let size = try handle.seekToEnd()
        return (head, Int(size))
    }

    // MARK: - Camera files

    @Test(.enabled(if: !raws.isEmpty), arguments: raws)
    func `each raw yields a camera, a capture date and a size`(url: URL) throws {
        let (head, size) = try Self.head(of: url)
        let metadata = try #require(PhotoMetadataReader.read(head: head, fileSize: size, url: url))
        #expect(metadata.cameraName != nil)
        #expect(metadata.captured != nil)
        #expect(metadata.pixelSize != nil)
    }

    @Test(.enabled(if: !raws.isEmpty), arguments: raws)
    func `each raw reads from its head as from the whole file`(url: URL) throws {
        let (head, size) = try Self.head(of: url)
        #expect(PhotoMetadataReader.read(head: head, fileSize: size, url: url) == PhotoMetadataReader.read(url: url))
    }

    // MARK: - Files written here

    @Test func `a JPEG's EXIF, GPS, IPTC and XMP read back exactly`() throws {
        let jpeg = try Self.encode(Self.image(), properties: Self.cameraProperties, xmp: Self.organisingXMP())
        let metadata = PhotoMetadataReader.read(
            head: jpeg, fileSize: jpeg.count, url: URL(fileURLWithPath: "/never/read/IMG_0001.jpg"),
        )
        #expect(metadata == CaptureMetadata(
            make: "NIKON CORPORATION", model: "NIKON Z 8", lens: "NIKKOR Z 24-70mm f/2.8 S", iso: 400,
            aperture: 2.8, shutter: 0.004, focalLength: 35, captured: Self.utc("2026-10-01 12:00:00", plus: 0.25),
            capturedOffset: 3600, pixelSize: PixelSize(width: 48, height: 64), orientation: 6, latitude: -38.5,
            longitude: -9.25, rating: 4, label: "Green", keywords: ["Places/Portugal/Lisbon", "Animals/Birds/Gulls"],
            title: "Tram 28", caption: "The tram climbing to Graça.", creator: "Pedro Gomes; Ana Silva",
            copyright: "© 2026 Pedro Gomes",
            location: .init(country: "Portugal", state: "Lisboa", city: "Lisbon", sublocation: "Alfama"),
        ))
        #expect(metadata?.cameraName == "Nikon Z 8")
    }

    @Test func `IPTC's fields stand in for XMP a JPEG doesn't have`() throws {
        var properties = Self.cameraProperties
        properties[kCGImagePropertyIPTCDictionary] = [
            kCGImagePropertyIPTCKeywords: ["harbour", "dusk"],
            kCGImagePropertyIPTCObjectName: "Ferry",
            kCGImagePropertyIPTCCaptionAbstract: "The last ferry to Cacilhas.",
            kCGImagePropertyIPTCByline: ["Pedro Gomes"],
            kCGImagePropertyIPTCCopyrightNotice: "© Pedro Gomes",
            kCGImagePropertyIPTCStarRating: 2,
            kCGImagePropertyIPTCCity: "Lisbon",
        ]
        let jpeg = try Self.encode(Self.image(), properties: properties)
        let metadata = try #require(PhotoMetadataReader.read(
            head: jpeg, fileSize: jpeg.count, url: URL(fileURLWithPath: "/never/read/IMG_0002.jpg"),
        ))
        #expect(metadata.keywords == ["harbour", "dusk"])
        #expect(metadata.title == "Ferry")
        #expect(metadata.caption == "The last ferry to Cacilhas.")
        #expect(metadata.creator == "Pedro Gomes")
        #expect(metadata.copyright == "© Pedro Gomes")
        #expect(metadata.rating == 2)
        #expect(metadata.label == nil)
        #expect(metadata.location == .init(city: "Lisbon"))
    }

    @Test func `a big JPEG reads from its head as from the whole file`() throws {
        let jpeg = try Self.encode(
            Self.image(width: 1024, height: 768), properties: Self.cameraProperties, xmp: Self.organisingXMP(),
        )
        try #require(jpeg.count > 2 * PhotoMetadataReader.headLength)
        let url = URL(fileURLWithPath: "/never/read/IMG_0003.jpg")
        let whole = PhotoMetadataReader.read(head: jpeg, fileSize: jpeg.count, url: url)
        #expect(whole?.pixelSize == PixelSize(width: 768, height: 1024))
        let head = jpeg.prefix(PhotoMetadataReader.headLength)
        #expect(PhotoMetadataReader.read(head: head, fileSize: jpeg.count, url: url) == whole)
    }

    /// ImageIO writes a TIFF's directory after its pixels, beyond any head.
    @Test func `a file whose head doesn't hold its metadata is read whole`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "scan.tif")
        try Self.encode(Self.image(width: 512, height: 512), as: "public.tiff", properties: Self.cameraProperties)
            .write(to: url)
        let (head, size) = try Self.head(of: url)
        try #require(size > head.count)
        #expect(PhotoMetadataReader.headMetadata(head, fileSize: size, url: url) == nil)
        let metadata = PhotoMetadataReader.read(head: head, fileSize: size, url: url)
        #expect(metadata?.captured == Self.utc("2026-10-01 12:00:00", plus: 0.25))
        #expect(metadata == PhotoMetadataReader.read(url: url))
    }

    /// As Adobe's apps leave a DNG or a TIFF whose XMP outgrew its place: IFD0, and the image's size,
    /// in the head, and the XMP appended to the file.
    @Test func `a file whose XMP was appended past its head is read whole`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "IMG_0005.tif")
        let xmp = XMPMetadataTests.xmp("<xmp:Rating>4</xmp:Rating>")
        let appended = Self.tiff(xmp: xmp, after: PhotoMetadataReader.headLength)
        try appended.write(to: url)
        let (head, size) = try Self.head(of: url)
        #expect(PhotoMetadataReader.pointsPastItself(head))
        #expect(PhotoMetadataReader.read(head: head, fileSize: size, url: url)?.rating == 4)
        let inPlace = Self.tiff(xmp: xmp, after: 0)
        #expect(!PhotoMetadataReader.pointsPastItself(inPlace))
        #expect(PhotoMetadataReader.read(head: inPlace, fileSize: inPlace.count, url: url)?.rating == 4)
        let jpeg = try Self.encode(Self.image(), properties: [:])
        #expect(!PhotoMetadataReader.pointsPastItself(jpeg))
    }

    @Test func `the app's LibRaw identity stands in only where ImageIO reads nothing`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let unreadable = folder.appending(path: "DSC_0001.NEF")
        let readable = folder.appending(path: "DSC_0002.NEF")
        let asked = Asked()
        let previous = PhotoMetadataReader.rawIdentity
        PhotoMetadataReader.rawIdentity = { url in
            guard url.deletingLastPathComponent().path == folder.path else { return previous?(url) }
            asked.urls.withLock { $0.append(url) }
            return CaptureMetadata(make: "Nikon", model: "Z 6")
        }
        defer { PhotoMetadataReader.rawIdentity = previous }
        let noise = Data(repeating: 0x5A, count: 4096)
        #expect(PhotoMetadataReader.read(head: noise, fileSize: noise.count, url: unreadable)?
            .cameraName == "Nikon Z 6")
        let jpeg = try Self.encode(Self.image(), properties: Self.cameraProperties)
        #expect(PhotoMetadataReader.read(head: jpeg, fileSize: jpeg.count, url: readable)?.model == "NIKON Z 8")
        #expect(asked.urls.withLock { $0 } == [unreadable])
    }

    final class Asked: Sendable {
        let urls = Mutex<[URL]>([])
    }

    // MARK: - Fields

    @Test func `a capture time with an offset keeps the camera's clock and records the offset`() {
        let date = PhotoMetadataReader.captureDate([
            kCGImagePropertyExifDateTimeOriginal: "2026:10:01 12:00:00",
            kCGImagePropertyExifSubsecTimeOriginal: "5",
            kCGImagePropertyExifOffsetTimeOriginal: "-05:30",
        ])
        #expect(date?.wallClock == Self.utc("2026-10-01 12:00:00", plus: 0.5))
        #expect(date?.offset == -19800)
    }

    @Test func `a capture time without an offset reads as UTC, its zone unknown`() {
        let date = PhotoMetadataReader.captureDate([
            kCGImagePropertyExifDateTimeOriginal: "2018:03:13 16:38:13",
            kCGImagePropertyExifSubsecTimeOriginal: "06",
        ])
        #expect(date?.wallClock == Self.utc("2018-03-13 16:38:13", plus: 0.06))
        #expect(date?.offset == nil)
    }

    @Test func `the digitized time stands in for a missing original, with its own offset`() {
        let date = PhotoMetadataReader.captureDate([
            kCGImagePropertyExifDateTimeDigitized: "1999:12:31 23:59:59",
            kCGImagePropertyExifOffsetTimeDigitized: "+09:00",
            kCGImagePropertyExifOffsetTimeOriginal: "+01:00",
        ])
        #expect(date?.wallClock == Self.utc("1999-12-31 23:59:59"))
        #expect(date?.offset == 32400)
    }

    @Test func `capture times in ISO 8601's form read, and blank or impossible ones don't`() {
        #expect(PhotoMetadataReader.wallClock("2023-05-03T12:45:20") == Self.utc("2023-05-03 12:45:20"))
        #expect(PhotoMetadataReader.wallClock(" 2023:05:03 12:45:20 ") == Self.utc("2023-05-03 12:45:20"))
        for text in ["0000:00:00 00:00:00", "    :  :     :  :  ", "2023:02:30 12:00:00", "2023:05:03", ""] {
            #expect(PhotoMetadataReader.wallClock(text) == nil, "\(text)")
        }
        #expect(PhotoMetadataReader.fraction("1a") == nil)
        #expect(PhotoMetadataReader.fraction("  ") == nil)
        for text in ["+1:00", "+15:00", "01:00", "   :  ", "+01:60", "+0100"] {
            #expect(PhotoMetadataReader.offset(text) == nil, "\(text)")
        }
        #expect(PhotoMetadataReader.offset("+05:45") == 20700)
    }

    @Test func `south and west references make coordinates negative`() {
        let south = PhotoMetadataReader.coordinates([
            kCGImagePropertyGPSLatitude: 33.75, kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 70.5, kCGImagePropertyGPSLongitudeRef: "W",
        ])
        #expect(south?.latitude == -33.75)
        #expect(south?.longitude == -70.5)
        let north = PhotoMetadataReader.coordinates([
            kCGImagePropertyGPSLatitude: 38.75, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 139.5, kCGImagePropertyGPSLongitudeRef: "E",
        ])
        #expect(north?.latitude == 38.75)
        #expect(north?.longitude == 139.5)
        #expect(PhotoMetadataReader.coordinates([kCGImagePropertyGPSLatitude: 38.75]) == nil)
        #expect(PhotoMetadataReader.coordinates([
            kCGImagePropertyGPSLatitude: 98.0, kCGImagePropertyGPSLongitude: 10.0,
        ]) == nil)
    }

    @Test func `ISO falls back to the sensitivity a CR3 records, and past ISOSpeedRatings' cap`() {
        #expect(PhotoMetadataReader.iso([kCGImagePropertyExifISOSpeedRatings: [400]]) == 400)
        #expect(PhotoMetadataReader.iso([
            kCGImagePropertyExifISOSpeed: 640, kCGImagePropertyExifRecommendedExposureIndex: 640,
        ]) == 640)
        #expect(PhotoMetadataReader.iso([
            kCGImagePropertyExifISOSpeedRatings: [65535], kCGImagePropertyExifRecommendedExposureIndex: 102_400,
        ]) == 102_400)
        #expect(PhotoMetadataReader.iso([:]) == nil)
    }

    @Test(arguments: [
        ("NIKON CORPORATION", "NIKON Z 6", "Nikon Z 6"),
        ("SONY", "ILCE-7M3", "Sony ILCE-7M3"),
        ("Canon", "Canon EOS R6", "Canon EOS R6"),
        ("FUJIFILM", "X-T5", "Fujifilm X-T5"),
        ("RICOH IMAGING COMPANY, LTD.", "RICOH GR III", "Ricoh GR III"),
        ("Leica Camera AG", "LEICA M10-R", "Leica M10-R"),
        ("OLYMPUS IMAGING CORP.", "E-M1MarkII", "Olympus E-M1MarkII"),
        ("samsung", "Galaxy S23 Ultra", "Samsung Galaxy S23 Ultra"),
        ("DJI", "FC4382", "DJI FC4382"),
        ("Phase One", "IQ4 150MP", "Phase One IQ4 150MP"),
    ])
    func `camera names read as people write them`(make: String, model: String, name: String) {
        #expect(CaptureMetadata(make: make, model: model).cameraName == name)
    }

    @Test func `a camera with only a make or a model is named by it`() {
        #expect(CaptureMetadata(model: "NX1").cameraName == "NX1")
        #expect(CaptureMetadata(make: "SONY").cameraName == "Sony")
        #expect(CaptureMetadata().cameraName == nil)
    }

    @Test func `metadata round-trips through JSON`() throws {
        let metadata = CaptureMetadata(
            make: "SONY", model: "ILCE-7M3", captured: Self.utc("2018-03-13 16:38:13"), capturedOffset: 3600,
            pixelSize: PixelSize(width: 6000, height: 4000), rating: -1, keywords: ["Places/Portugal"],
            location: .init(city: "Lisbon"),
        )
        let decoded = try JSONDecoder().decode(CaptureMetadata.self, from: JSONEncoder().encode(metadata))
        #expect(decoded == metadata)
    }
}

// MARK: - Throughput

extension PhotoMetadataReaderTests {
    static let benchmarking = ProcessInfo.processInfo.environment["REDLAMP_METADATA_BENCH"] == "1"

    /// Reads per second by format, from 256 KiB heads held in memory, on one core and on all of them,
    /// each for a second; files read with `read(url:)` come from the page cache.
    /// `TEST_RUNNER_REDLAMP_METADATA_BENCH=1` runs it.
    @Test(.enabled(if: benchmarking && !raws.isEmpty))
    func `measure reads per second by format`() throws {
        let samples = try Self.raws.map { url in
            let (head, size) = try Self.head(of: url)
            return Sample(url: url, head: head, size: size)
        }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        var lines = ["format  files  from the head  1 core/s  \(cores) cores/s"]
        for (format, files) in Dictionary(grouping: samples, by: \.format).sorted(by: { $0.key < $1.key }) {
            let fromHead = files.count { file in
                PhotoMetadataReader.headMetadata(file.head, fileSize: file.size, url: file.url) != nil
            }
            let one = Self.readsPerSecond(files, workers: 1)
            let all = Self.readsPerSecond(files, workers: cores)
            lines.append([format, "\(files.count)", "\(fromHead)", "\(Int(one))", "\(Int(all))"].map {
                $0.padding(toLength: 10, withPad: " ", startingAt: 0)
            }.joined())
        }
        let start = ContinuousClock.now
        for index in 0 ..< 10000 {
            _ = ContentKey(fileSize: samples[index % samples.count].size, head: samples[index % samples.count].head)
        }
        lines.append("content keys: \(Int(10000 / ((ContinuousClock.now - start) / .seconds(1))))/s on one core")
        print(lines.joined(separator: "\n"))
    }

    struct Sample {
        var url: URL
        var head: Data
        var size: Int

        var format: String {
            url.pathExtension.uppercased()
        }
    }

    /// Reads per second over `workers` threads, each reading `files` in turn for a second.
    static func readsPerSecond(_ files: [Sample], workers: Int) -> Double {
        for file in files {
            _ = PhotoMetadataReader.read(head: file.head, fileSize: file.size, url: file.url)
        }
        let reads = Atomic<Int>(0)
        let start = ContinuousClock.now
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            var index = worker
            while ContinuousClock.now - start < .seconds(1) {
                let file = files[index % files.count]
                _ = PhotoMetadataReader.read(head: file.head, fileSize: file.size, url: file.url)
                reads.add(1, ordering: .relaxed)
                index += 1
            }
        }
        return Double(reads.load(ordering: .relaxed)) / ((ContinuousClock.now - start) / .seconds(1))
    }
}

// MARK: - Writing test files

extension PhotoMetadataReaderTests {
    /// A Nikon's EXIF with a zone offset, a place south and west, and IPTC's location fields.
    static var cameraProperties: [CFString: Any] {
        [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "NIKON CORPORATION", kCGImagePropertyTIFFModel: "NIKON Z 8",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:01 12:00:00",
                kCGImagePropertyExifSubsecTimeOriginal: "25",
                kCGImagePropertyExifOffsetTimeOriginal: "+01:00",
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifExposureTime: 0.004,
                kCGImagePropertyExifISOSpeedRatings: [400],
                kCGImagePropertyExifFocalLength: 35,
                kCGImagePropertyExifLensModel: "NIKKOR Z 24-70mm f/2.8 S",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 38.5, kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 9.25, kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCity: "Lisbon", kCGImagePropertyIPTCProvinceState: "Lisboa",
                kCGImagePropertyIPTCCountryPrimaryLocationName: "Portugal", kCGImagePropertyIPTCSubLocation: "Alfama",
            ],
        ]
    }

    /// The organising fields as Lightroom writes them into a photo's XMP.
    static func organisingXMP() -> CGImageMetadata {
        let xmp = CGImageMetadataCreateMutable()
        #expect(CGImageMetadataRegisterNamespaceForPrefix(
            xmp, "http://ns.adobe.com/lightroom/1.0/" as CFString, "lr" as CFString, nil,
        ))
        let values: [(String, CFTypeRef)] = [
            ("xmp:Rating", "4" as CFString),
            ("xmp:Label", "Green" as CFString),
            ("lr:hierarchicalSubject", ["Places|Portugal|Lisbon", "Animals|Birds|Gulls"] as CFArray),
            ("dc:subject", ["Lisbon", "Gulls"] as CFArray),
            ("dc:title", "Tram 28" as CFString),
            ("dc:description", "The tram climbing to Graça." as CFString),
            ("dc:creator", ["Pedro Gomes", "Ana Silva"] as CFArray),
            ("dc:rights", "© 2026 Pedro Gomes" as CFString),
        ]
        for (path, value) in values {
            #expect(CGImageMetadataSetValueWithPath(xmp, nil, path as CFString, value), "\(path)")
        }
        return xmp
    }

    static func encode(
        _ image: CGImage, as type: String = "public.jpeg", properties: [CFString: Any], xmp: CGImageMetadata? = nil,
    ) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data as CFMutableData,
            type as CFString,
            1,
            nil,
        ))
        if let xmp {
            CGImageDestinationAddImageAndMetadata(destination, image, xmp, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A one-pixel grey TIFF, its IFD0 first and its XMP last, `gap` bytes after its pixel.
    static func tiff(xmp: Data, after gap: Int) -> Data {
        let (directory, pixel) = (8, 8 + 2 + 10 * 12 + 4)
        let entries = [
            (256, 3, 1, 1), (257, 3, 1, 1), (258, 3, 1, 8), (259, 3, 1, 1), (262, 3, 1, 1),
            (273, 4, 1, pixel), (277, 3, 1, 1), (278, 3, 1, 1), (279, 4, 1, 1), (700, 7, xmp.count, pixel + 1 + gap),
        ]
        func littleEndian(_ value: Int, _ length: Int) -> [UInt8] {
            (0 ..< length).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
        }
        var bytes = Array("II".utf8) + littleEndian(42, 2) + littleEndian(directory, 4) + littleEndian(entries.count, 2)
        for (tag, type, count, value) in entries {
            bytes += littleEndian(tag, 2) + littleEndian(type, 2) + littleEndian(count, 4) + littleEndian(value, 4)
        }
        bytes += littleEndian(0, 4) + [0x80] + [UInt8](repeating: 0, count: gap)
        return Data(bytes) + xmp
    }

    /// Noise, which JPEG can't compress much: a big image makes a file bigger than a head.
    static func image(width: Int = 64, height: Int = 48) -> CGImage {
        var state: UInt32 = 2_463_534_242
        let bytes = (0 ..< width * height * 4).map { _ in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return UInt8(truncatingIfNeeded: state)
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent,
        )!
    }

    /// "2026-10-01 12:00:00" in UTC, `plus` seconds.
    static func utc(_ text: String, plus fraction: TimeInterval = 0) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!.addingTimeInterval(fraction)
    }
}
