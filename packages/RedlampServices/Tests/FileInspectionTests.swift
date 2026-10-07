import Foundation
import ImageIO
import RedlampEngineAPI
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import RedlampServices

/// The library's reads of capture settings and focus thumbnails give the same answers in the
/// decode service as in the app, so moving them out of the app finds the same focus stacks
/// (DATA-17).
struct FileInspectionTests {
    /// A run of one camera's frames (DSC_0750 to DSC_0757) whose thumbnails detection reads before
    /// it finds no sweep, then every raw sample.
    static let series = DecodeRegressionTests.raws(in: "tests/fixtures/shoots/nikon-z6")
    static let files = series + DecodeRegressionTests.fixtures

    /// A listener in this process that answers as the service does, through a real connection.
    final class Listener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        let listener = NSXPCListener.anonymous()
        let exported: any DecodeServiceProtocol

        init(exporting exported: any DecodeServiceProtocol = DecodeService()) {
            self.exported = exported
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

    /// The service, recording how many files each captures or focus-thumbnails call carries.
    final class RecordingService: NSObject, DecodeServiceProtocol, @unchecked Sendable {
        private let service = DecodeService()
        private let recorded = Mutex<[Int]>([])

        var batches: [Int] {
            recorded.withLock { $0 }
        }

        func decode(_ file: Data, path: String, reply: @escaping @Sendable (Data?, Data?) -> Void) {
            service.decode(file, path: path, reply: reply)
        }

        func captures(
            _ files: [Data],
            paths: [String],
            concurrently: Bool,
            reply: @escaping @Sendable (Data?) -> Void,
        ) {
            recorded.withLock { $0.append(files.count) }
            service.captures(files, paths: paths, concurrently: concurrently, reply: reply)
        }

        func focusThumbnails(
            _ files: [Data], paths: [String], concurrently: Bool, reply: @escaping @Sendable (Data?) -> Void,
        ) {
            recorded.withLock { $0.append(files.count) }
            service.focusThumbnails(files, paths: paths, concurrently: concurrently, reply: reply)
        }
    }

    @Test(.enabled(if: !series.isEmpty))
    func `the series' frames have the dates and settings a stack is found by`() {
        let captures = InProcessDecoder().captures(of: Self.series, concurrently: false)
        #expect(captures.count == 8)
        #expect(captures.allSatisfy { $0?.date != nil && $0?.model != nil && $0?.aperture != nil })
        #expect(Set(captures.map { $0?.date }).count == 8)
        #expect(Set(captures.map { $0.map { [$0.model, $0.lens] } }).count == 1)
    }

    @Test(.enabled(if: !series.isEmpty), arguments: [false, true])
    func `the service reads the same captures and focus thumbnails as the app`(concurrently: Bool) {
        let listener = Listener()
        let service = DecodeServiceClient(endpoint: listener.listener.endpoint)
        let local = InProcessDecoder()
        let captures = local.captures(of: Self.files, concurrently: concurrently)
        let thumbnails = local.focusThumbnails(of: Self.series, concurrently: concurrently)
        #expect(captures.compactMap(\.self).count == Self.files.count)
        #expect(thumbnails.allSatisfy { $0?.width == GreyThumbnail.longEdge })
        #expect(service.captures(of: Self.files, concurrently: concurrently) == captures)
        #expect(service.focusThumbnails(of: Self.series, concurrently: concurrently) == thumbnails)
    }

    @Test(.enabled(if: !series.isEmpty))
    func `a file that can't be read has no capture or thumbnail, and the rest are read`() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).NEF")
        let junk = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).CR3")
        try Data(repeating: 7, count: 4096).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        let listener = Listener()
        let service = DecodeServiceClient(endpoint: listener.listener.endpoint)
        let files = [missing, junk] + Self.series.prefix(1)
        let local = InProcessDecoder().captures(of: files, concurrently: false)
        #expect(local.prefix(2).allSatisfy { $0 == nil })
        #expect(service.captures(of: files, concurrently: false) == local)
        #expect(service.focusThumbnails(of: files, concurrently: false).map { $0 == nil } == [true, true, false])
    }

    /// 1,001 hard links, beside the samples so they can be made, to the three smallest in turn.
    @Test(.enabled(if: DecodeRegressionTests.fixtures.count >= 3))
    func `a folder over the cap is read in calls of at most 1,000, and reads as in the app`() throws {
        let samples = DecodeRegressionTests.fixtures.sorted { size($0) < size($1) }.prefix(3)
        let folder = DecodeRegressionTests.root.appending(path: "build/file-inspection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try (0 ..< 1001).map { index in
            let sample = samples[samples.startIndex + index % samples.count]
            let link = folder.appending(path: String(format: "IMG_%04d.", index) + sample.pathExtension)
            try FileManager.default.linkItem(at: sample, to: link)
            return link
        }
        let recording = RecordingService()
        let listener = Listener(exporting: recording)
        let service = DecodeServiceClient(endpoint: listener.listener.endpoint)
        let local = InProcessDecoder()
        let captures = local.captures(of: files, concurrently: true)
        #expect(captures.compactMap(\.self).count == files.count)
        #expect(service.captures(of: files, concurrently: true) == captures)
        #expect(service.focusThumbnails(of: files, concurrently: true) == local.focusThumbnails(
            of: files,
            concurrently: true,
        ))
        let cap = DecodeServiceClient.filesPerCall
        #expect(recording.batches == [cap, files.count - cap, cap, files.count - cap])
    }

    private func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
    }

    /// What an export copies from its source, and the tags that tell an earlier export.
    static var exportedProperties: [CFString] {
        [
            kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyTIFFDictionary,
            kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyPNGDictionary,
            kCGImagePropertyOrientation,
        ]
    }

    /// A 16-pixel JPEG carrying `properties`.
    private func jpeg(at url: URL, _ properties: [CFString: Any]) throws {
        let context = try #require(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil),
        )
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test(.enabled(if: !DecodeRegressionTests.fixtures.isEmpty))
    func `the service reads each file's properties as ImageIO does in the app`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let export = folder.appending(path: "IMG_0001.jpg")
        let camera = folder.appending(path: "IMG_0002.JPG")
        let damaged = folder.appending(path: "IMG_0003.jpg")
        try jpeg(at: export, [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFSoftware: "Redlamp 0.2.5", kCGImagePropertyTIFFArtist: "A. Photographer",
            ],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 38.7, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "Lisbon"],
            kCGImagePropertyOrientation: 6,
        ])
        try jpeg(at: camera, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Camera"], kCGImagePropertyOrientation: 1,
        ])
        try Data(repeating: 7, count: 4096).write(to: damaged)
        let files = DecodeRegressionTests.fixtures + DecodeRegressionTests.cameras + [export, camera, damaged]
        let local = InProcessDecoder().imageProperties(of: files)
        for (url, read) in zip(files.dropLast(), local) {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let imageIO = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let properties = try #require(read, "\(url.lastPathComponent)").dictionary
            for key in Self.exportedProperties {
                #expect(properties[key] as? NSObject == imageIO[key] as? NSObject, "\(url.lastPathComponent): \(key)")
            }
        }
        #expect(local[files.count - 1] == nil, "a damaged file has none")

        let listener = Listener()
        let service = DecodeServiceClient(endpoint: listener.listener.endpoint)
        withKnownIssue("The service reads no properties until it is asked them") {
            #expect(service.imageProperties(of: files) == local)
        }
    }

    @Test func `a thumbnail of a size the reader never draws is refused`() {
        let edge = GreyThumbnail.longEdge
        #expect(FocusThumbnail(width: edge, height: 2, bytes: Data(count: 2 * edge)).grey?.height == 2)
        #expect(FocusThumbnail(width: edge, height: 2, bytes: Data(count: edge)).grey == nil)
        #expect(FocusThumbnail(width: 2 * edge, height: 2, bytes: Data(count: 4 * edge)).grey == nil)
        #expect(FocusThumbnail(width: 2, height: 2, bytes: Data(count: 4)).grey == nil)
        #expect(FocusThumbnail(width: -edge, height: -1, bytes: Data(count: edge)).grey == nil)
    }
}
