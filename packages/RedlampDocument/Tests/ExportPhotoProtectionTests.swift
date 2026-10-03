import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing

/// No export, in any naming or rule for existing files, replaces a photo.
struct ExportPhotoProtectionTests {
    @Test func `a name is never the photo's own file, in any letter case`() throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let photo = folder.appending(path: "IMG_0001.JPG")
        try Data("original".utf8).write(to: photo)
        var settings = ExportSettings()
        settings.naming = ExportNaming(suffix: "")
        #expect(ExportDestination.url(for: photo, settings: settings).lastPathComponent == "IMG_0001-2.jpg")
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
        #expect(ExportDestination.url(for: photo, settings: settings).lastPathComponent == "IMG_0002-2.jpg")
        settings.naming = ExportNaming(mode: .custom, customName: "IMG_0003")
        #expect(ExportDestination.url(for: photo, settings: settings).lastPathComponent == "IMG_0003.jpg")
    }

    @Test(arguments: ["IMG_0001.JPG", "IMG_0001.jpg", "img_0001.jpg"])
    func `writing over the photo it came from throws and keeps it`(name: String) throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let photo = folder.appending(path: "IMG_0001.JPG")
        try Data("original".utf8).write(to: photo)
        let target = folder.appending(path: name)
        #expect(throws: ExportError.wouldReplacePhoto(target)) {
            try ImageExporter.write(ExportWriterTests.image(), to: target, settings: ExportSettings(), source: photo)
        }
        #expect(try Data(contentsOf: photo) == Data("original".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["IMG_0001.JPG"])
    }

    @Test func `writing over a raw file throws and keeps it`() throws {
        let (folder, cleanup) = try ExportWriterTests.temporaryFolder()
        defer { cleanup() }
        let raw = folder.appending(path: "IMG_0002.ARW")
        try Data("raw".utf8).write(to: raw)
        #expect(throws: ExportError.wouldReplacePhoto(raw)) {
            try ImageExporter.write(ExportWriterTests.image(), to: raw, settings: ExportSettings())
        }
        #expect(try Data(contentsOf: raw) == Data("raw".utf8))
    }
}
