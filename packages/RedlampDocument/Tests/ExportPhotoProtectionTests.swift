import Foundation
import ImageIO
import RedlampDocument
import RedlampEngineAPI
import Testing

/// No export, in any naming or rule for existing files, replaces a photo.
struct ExportPhotoProtectionTests {
    /// A JPEG as a camera writes it: an image Redlamp didn't export.
    private static func cameraJPEG(at url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "Sony", kCGImagePropertyTIFFSoftware: "ILCE-7M4 v2.0"]
        CGImageDestinationAddImage(
            destination, ExportWriterTests.image(), [kCGImagePropertyTIFFDictionary: tiff] as CFDictionary,
        )
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func `a name is never an unedited photo, such as the camera's JPEG beside a raw`() throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let raw = folder.appending(path: "IMG_0001.ARW")
        try Data("raw".utf8).write(to: raw)
        try Self.cameraJPEG(at: folder.appending(path: "IMG_0001.JPG"))
        try Data("not an image".utf8).write(to: folder.appending(path: "IMG_0002.jpg"))
        var settings = ExportSettings()
        settings.naming = ExportNaming(suffix: "")
        #expect(ExportDestination.url(for: raw, settings: settings, reading: ImageIOFiles())
            .lastPathComponent == "IMG_0001-2.jpg")
        settings.naming = ExportNaming(mode: .custom, customName: "IMG_0002")
        #expect(ExportDestination.url(for: raw, settings: settings, reading: ImageIOFiles())
            .lastPathComponent == "IMG_0002-2.jpg")
    }

    @Test func `writing over an unedited photo throws and keeps it`() throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let photo = folder.appending(path: "IMG_0001.JPG")
        try Self.cameraJPEG(at: photo)
        let original = try Data(contentsOf: photo)
        #expect(throws: ExportError.wouldReplacePhoto(photo)) {
            try ImageExporter.write(
                ExportWriterTests.image(),
                to: photo,
                settings: ExportSettings(),
                reading: ImageIOFiles(),
            )
        }
        #expect(try Data(contentsOf: photo) == original)
    }

    @Test(arguments: ExportFormat.allCases)
    func `an earlier export is written over, in every format`(format: ExportFormat) throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let photo = folder.appending(path: "IMG_0001.ARW")
        try Data("raw".utf8).write(to: photo)
        var settings = ExportSettings()
        settings.format = format
        let target = ExportDestination.url(for: photo, settings: settings, reading: ImageIOFiles())
        try ImageExporter.write(
            ExportWriterTests.image(),
            to: target,
            settings: settings,
            source: photo,
            reading: ImageIOFiles(),
        )
        #expect(!ExportDestination.isPhoto(target, source: photo, reading: ImageIOFiles()))
        #expect(ExportDestination.url(for: photo, settings: settings, reading: ImageIOFiles()) == target)
        try ImageExporter.write(
            ExportWriterTests.image(),
            to: target,
            settings: settings,
            source: photo,
            reading: ImageIOFiles(),
        )
    }

    @Test func `a name is never the photo's own file, in any letter case`() throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let photo = folder.appending(path: "IMG_0001.JPG")
        try Data("original".utf8).write(to: photo)
        var settings = ExportSettings()
        settings.naming = ExportNaming(suffix: "")
        #expect(ExportDestination.url(for: photo, settings: settings, reading: ImageIOFiles())
            .lastPathComponent == "IMG_0001-2.jpg")
    }

    @Test func `a name is never another photo with edits`() throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let photo = folder.appending(path: "IMG_0001.ARW")
        let other = folder.appending(path: "IMG_0002.JPG")
        try Data("raw".utf8).write(to: photo)
        try Data("other".utf8).write(to: other)
        try SidecarStore().save(Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 3)), for: other)
        var settings = ExportSettings()
        settings.naming = ExportNaming(mode: .custom, customName: "IMG_0002")
        #expect(ExportDestination.url(for: photo, settings: settings, reading: ImageIOFiles())
            .lastPathComponent == "IMG_0002-2.jpg")
        settings.naming = ExportNaming(mode: .custom, customName: "IMG_0003")
        #expect(ExportDestination.url(for: photo, settings: settings, reading: ImageIOFiles())
            .lastPathComponent == "IMG_0003.jpg")
    }

    @Test(arguments: ["IMG_0001.JPG", "IMG_0001.jpg", "img_0001.jpg"])
    func `writing over the photo it came from throws and keeps it`(name: String) throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let photo = folder.appending(path: "IMG_0001.JPG")
        try Data("original".utf8).write(to: photo)
        let target = folder.appending(path: name)
        #expect(throws: ExportError.wouldReplacePhoto(target)) {
            try ImageExporter.write(
                ExportWriterTests.image(),
                to: target,
                settings: ExportSettings(),
                source: photo,
                reading: ImageIOFiles(),
            )
        }
        #expect(try Data(contentsOf: photo) == Data("original".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["IMG_0001.JPG"])
    }

    @Test func `a link to the photo it came from is the photo, even an earlier export`() throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let photo = folder.appending(path: "IMG_0001-redlamp.jpg")
        try ImageExporter.write(
            ExportWriterTests.image(width: 8, height: 8),
            to: photo,
            settings: ExportSettings(),
            reading: ImageIOFiles(),
        )
        let link = folder.appending(path: "link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: photo)
        #expect(ExportDestination.isPhoto(link, source: photo, reading: ImageIOFiles()))
        #expect(!ExportDestination.isPhoto(
            photo,
            source: folder.appending(path: "IMG_0002.ARW"),
            reading: ImageIOFiles(),
        ))
    }

    @Test func `writing over a raw file throws and keeps it`() throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let raw = folder.appending(path: "IMG_0002.ARW")
        try Data("raw".utf8).write(to: raw)
        #expect(throws: ExportError.wouldReplacePhoto(raw)) {
            try ImageExporter.write(
                ExportWriterTests.image(),
                to: raw,
                settings: ExportSettings(),
                reading: ImageIOFiles(),
            )
        }
        #expect(try Data(contentsOf: raw) == Data("raw".utf8))
    }

    @Test func `writing replaces the file and leaves nothing else`() throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let url = folder.appending(path: "out.jpg")
        try ImageExporter.write(
            ExportWriterTests.image(width: 8, height: 8),
            to: url,
            settings: ExportSettings(),
            reading: ImageIOFiles(),
        )
        let old = try Data(contentsOf: url)
        try ImageExporter.write(ExportWriterTests.image(), to: url, settings: ExportSettings(), reading: ImageIOFiles())
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["out.jpg"])
        #expect(try Data(contentsOf: url) != old)
    }

    @Test func `a failed write keeps the existing file`() throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let url = folder.appending(path: "out.jpg")
        try ImageExporter.write(
            ExportWriterTests.image(width: 8, height: 8),
            to: url,
            settings: ExportSettings(),
            reading: ImageIOFiles(),
        )
        let old = try Data(contentsOf: url)
        var settings = ExportSettings()
        settings.limitsFileSize = true
        settings.fileSizeLimitKB = 1
        #expect(throws: ExportError.self) {
            try ImageExporter.write(
                ExportWriterTests.image(width: 1024, height: 768),
                to: url,
                settings: settings,
                reading: ImageIOFiles(),
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["out.jpg"])
        #expect(try Data(contentsOf: url) == old)
    }
}
