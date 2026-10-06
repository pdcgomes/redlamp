import Foundation
import Testing
@testable import RedlampLibrary

struct ImportSourceTests {
    @Test func `a card is told apart from the Mac's disks, other drives, network shares and folders`() throws {
        let folder = try TemporaryFolder()
        let root = folder.url.appending(path: "EOS_DIGITAL", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root.appending(path: "DCIM/100CANON"),
            withIntermediateDirectories: true,
        )
        let entries = try LocalFileSystem().contentsOfDirectory(at: root)
        let card = ImportMedium.card(at: root)
        #expect(ImportSource.isCard(root, medium: card, entries: entries))
        // An external drive that ejects, a camera on USB whose medium only ejects.
        #expect(ImportSource.isCard(root, medium: ImportMedium(root: root, isEjectable: true), entries: entries))

        let cases: [(String, ImportMedium, [FileEntry])] = [
            ("the Mac's own disk", ImportMedium(root: root, isInternal: true), entries),
            (
                "the startup volume",
                ImportMedium(root: root, isRemovable: true, isEjectable: true, isRootFileSystem: true),
                entries,
            ),
            ("a network share", ImportMedium(root: root, isEjectable: true, isLocal: false), entries),
            ("a card without DCIM", card, [FileEntry(name: "Documents", isDirectory: true)]),
            ("a file named DCIM", card, [FileEntry(name: "DCIM", size: 10)]),
        ]
        for (what, medium, listing) in cases {
            #expect(!ImportSource.isCard(root, medium: medium, entries: listing), "\(what)")
        }
        // A folder inside a card is a folder, not the card.
        let inside = root.appending(path: "DCIM", directoryHint: .isDirectory)
        #expect(try !ImportSource.isCard(
            inside,
            medium: card,
            entries: LocalFileSystem().contentsOfDirectory(at: inside),
        ))

        let source = try ImportSource.at(root, medium: card)
        #expect(source.kind == .card && source.photosFolder.lastPathComponent == "DCIM")
        // This Mac's temporary folder, on its own disk, is a folder, DCIM or not.
        let mac = try ImportSource.at(root)
        #expect(mac.kind == .folder && mac.photosFolder == mac.url && mac.name == "EOS_DIGITAL")
        #expect(ImportMedium.of(root)?.isRemovable == false)
    }

    @Test func `a folder's photos are each grouped with their raw or JPEG and the sidecars named after them`() {
        let date = cameraTime()
        let entries = [
            "IMG_0001.CR3", "IMG_0001.JPG", "IMG_0001.xmp", "IMG_0001.CR3.xmp", "img_0001.jpg.redlamp", "IMG_0002.JPG",
            "IMG_0003.HEIC", "MVI_0004.MP4", "MVI_0004.THM", "IMG_0005.xmp",
        ].map { FileEntry(name: $0, isDirectory: $0.hasSuffix(".redlamp"), size: 10, modified: date) }
            + [FileEntry(name: "101CANON", isDirectory: true)]
        let (photos, others) = ImportPhoto.group(entries, folder: "/Card/DCIM/100CANON", source: "card")
        #expect(photos.map(\.primary.name) == ["IMG_0001.CR3", "IMG_0002.JPG", "IMG_0003.HEIC"])
        let first = photos[0]
        #expect(first.id == "/Card/DCIM/100CANON/IMG_0001.CR3")
        #expect(first.photoFiles.map(\.name) == ["IMG_0001.CR3", "IMG_0001.JPG"])
        #expect(Set(first.files.filter { $0.role != .photo }.map(\.name))
            == ["IMG_0001.xmp", "IMG_0001.CR3.xmp", "img_0001.jpg.redlamp"])
        #expect(first.files.first { $0.name == "img_0001.jpg.redlamp" }?.role == .sidecar)
        #expect(photos[1].files.count == 1 && photos[2].files.count == 1)
        #expect(Set(others.map(\.name)) == ["MVI_0004.MP4", "MVI_0004.THM", "IMG_0005.xmp"])
    }
}
