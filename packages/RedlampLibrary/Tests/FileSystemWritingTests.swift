import Foundation
import Testing
@testable import RedlampLibrary

struct FileSystemWritingTests {
    @Test func `the Mac's file system never replaces a file, and renames one in case or form alone`() throws {
        let folder = try TemporaryFolder()
        try folder.write("IMG_0001.ARW", bytes: 10)
        try folder.write("IMG_0002.ARW", bytes: 20)
        let local = LocalFileSystem()
        let (first, second) = (folder.url.appending(path: "IMG_0001.ARW"), folder.url.appending(path: "IMG_0002.ARW"))
        #expect(throws: POSIXError(.EEXIST)) { try local.moveItem(at: first, to: second) }
        #expect(try local.attributes(of: second).size == 20)

        let lower = folder.url.appending(path: "img_0001.ARW")
        try local.moveItem(at: first, to: lower)
        #expect(try local.contentsOfDirectory(at: folder.url).map(\.name).sorted() == ["IMG_0002.ARW", "img_0001.ARW"])
        let composed = "Caf\u{E9}.ARW"
        try local.moveItem(at: lower, to: folder.url.appending(path: composed))
        let name = try #require(try local.contentsOfDirectory(at: folder.url).map(\.name).first { $0.hasPrefix("Caf") })
        #expect(name.unicodeScalars.count == composed.unicodeScalars.count, "the composed name stays composed")

        try local.createDirectory(at: folder.url.appending(path: "A/B"), withIntermediateDirectories: true)
        try local.createDirectory(at: folder.url.appending(path: "A/B"), withIntermediateDirectories: true)
        #expect(throws: POSIXError(.EEXIST)) {
            try local.createDirectory(at: folder.url.appending(path: "A"), withIntermediateDirectories: false)
        }
    }

    @Test func `a copy keeps its date and its folder's files, and never replaces one`() throws {
        let folder = try TemporaryFolder()
        try folder.write("Pack/edit.json", bytes: 300)
        try folder.write("Pack/masks/a.png", bytes: 50)
        try folder.write("IMG_0001.ARW", bytes: 4000)
        let local = LocalFileSystem()
        let photo = folder.url.appending(path: "IMG_0001.ARW")
        let date = Date(timeIntervalSince1970: 1_600_000_000.25)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: photo.path)
        let copy = folder.url.appending(path: "Copy.ARW")
        try local.copyItem(at: photo, to: copy)
        #expect(try Data(contentsOf: copy) == Data(contentsOf: photo))
        #expect(try abs(local.attributes(of: copy).modified.timeIntervalSince(date)) < 1e-3)
        #expect(throws: POSIXError(.EEXIST)) { try local.copyItem(at: photo, to: copy) }
        try local.copyItem(at: folder.url.appending(path: "Pack"), to: folder.url.appending(path: "Pack 2"))
        #expect(try Data(contentsOf: folder.url.appending(path: "Pack 2/masks/a.png")).count == 50)
        try local.removeItem(at: folder.url.appending(path: "Pack 2"))
        #expect(!local.exists(folder.url.appending(path: "Pack 2")))
    }

    @Test func `simulated writes fail as told, keep their Trash in a folder and cross mounted volumes only by copying`(
    ) throws {
        let folder = try TemporaryFolder()
        try folder.write("A/IMG_0001.JPG", bytes: 100)
        try folder.write("A/IMG_0002.JPG", bytes: 100)
        try FileManager.default.createDirectory(at: folder.url.appending(path: "B"), withIntermediateDirectories: true)
        let simulated = SimulatedFileSystem(profile: .ssd)
        simulated.mount(folder.url.appending(path: "B"), uuid: "OTHER")
        simulated.useTrash(folder.url.appending(path: "Trash"))
        let photo = folder.url.appending(path: "A/IMG_0001.JPG")
        #expect(try simulated.volume(of: folder.url.appending(path: "B")).uuid == "OTHER")
        #expect(try simulated.volume(of: photo).uuid != "OTHER")
        #expect(throws: POSIXError(.EXDEV)) { try simulated.moveItem(
            at: photo,
            to: folder.url.appending(path: "B/x.JPG"),
        ) }

        simulated.inject(.init(.copy, name: "IMG_0001.JPG", effect: .error(.ENOSPC), count: 1))
        #expect(throws: POSIXError(.ENOSPC)) { try simulated.copyItem(
            at: photo,
            to: folder.url.appending(path: "B/x.JPG"),
        ) }
        #expect(!simulated.exists(folder.url.appending(path: "B/x.JPG")))
        simulated.inject(.init(.copy, effect: .corruptCopy))
        try simulated.copyItem(at: photo, to: folder.url.appending(path: "B/x.JPG"))
        #expect(try Data(contentsOf: folder.url.appending(path: "B/x.JPG")) != Data(contentsOf: photo))
        try simulated.copyItem(at: photo, to: folder.url.appending(path: "B/y.JPG"))
        #expect(try Data(contentsOf: folder.url.appending(path: "B/y.JPG")) == Data(contentsOf: photo))

        let first = try simulated.trashItem(at: photo)
        try folder.write("A/IMG_0001.JPG", bytes: 10)
        let second = try simulated.trashItem(at: photo)
        #expect(first.lastPathComponent == "IMG_0001.JPG" && second.lastPathComponent == "IMG_0001 2.JPG")
        #expect(try simulated.trashDirectory(for: photo) == folder.url.appending(path: "Trash"))
        try simulated.moveItem(at: first, to: photo)
        #expect(try simulated.attributes(of: photo).size == 100)
        #expect(simulated.writes.map { $0.split(separator: " ")[0] } == ["copy", "copy", "trash", "trash", "move"])

        struct ReadOnly: LibraryFileSystem {
            func contentsOfDirectory(at _: URL) throws -> [FileEntry] {
                []
            }

            func attributes(of url: URL) throws -> FileEntry {
                FileEntry(name: url.lastPathComponent)
            }

            func read(_: URL, range _: Range<Int>) throws -> Data {
                Data()
            }

            func volume(of _: URL) throws -> VolumeInfo {
                VolumeInfo(
                    uuid: nil,
                    name: nil,
                    isLocal: true,
                    isInternal: true,
                )
            }
        }
        #expect(throws: POSIXError(.EROFS)) { try ReadOnly().moveItem(at: photo, to: photo) }
    }
}
