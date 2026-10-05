import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Syncing photos' XMP in a library: other apps' changes taken into the `.redlamp` sidecars once,
/// and `.xmp` sidecars written only when it's on, keeping what other apps wrote.
struct XMPLibraryTests {
    private static func modified(_ url: URL) throws -> Date {
        try #require(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    private static func inode(_ url: URL) throws -> UInt64 {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64)
    }

    /// Every file below `folder` with its bytes, hidden ones included.
    private static func contents(below folder: URL) throws -> [String: Data] {
        var found: [String: Data] = [:]
        for path in FileManager.default.subpaths(atPath: folder.path) ?? [] {
            var isDirectory: ObjCBool = false
            let url = folder.appending(path: path)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                found[path] = try Data(contentsOf: url)
            }
        }
        return found
    }

    @Test func `writing .xmp is off by default, then written once it's on and only when a field changed`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("IMG_0001.ARW")
        try sandbox.sidecar("IMG_0001.ARW", PhotoMetadata(rating: 4, label: .red))
        try await sandbox.indexAll()
        #expect(try await sandbox.xmp.settings() == XMPSettings(writes: false))

        let before = try Self.contents(below: sandbox.root)
        let off = try await sandbox.sync()
        #expect(try !off.writing && Self.contents(below: sandbox.root) == before)
        #expect(off.photo("IMG_0001.ARW")?.unwritten == [.rating, .label])
        #expect(off.lines
            .contains("Writing .xmp is off: 1 photo with values their .xmp doesn't hold (--write writes them)"))

        try await sandbox.xmp.setSettings(XMPSettings(writes: true))
        let on = try await sandbox.sync()
        #expect(on.writing && on.photo("IMG_0001.ARW")?.written == [.rating, .label])
        #expect(on.lines.contains("1 .xmp file written: 1 new, 0 rewritten keeping other apps' fields"))
        let packet = try #require(XMPPacket(Data(contentsOf: sandbox.url("IMG_0001.xmp"))))
        #expect(packet.text(XMPNamespace.rating) == "4" && packet.text(XMPNamespace.label) == "Red")

        let written = try sandbox.text("IMG_0001.xmp")
        let date = try Self.modified(sandbox.url("IMG_0001.xmp"))
        let again = try await sandbox.sync()
        #expect(again.photo("IMG_0001.ARW")?.unchanged == true && again.xmpWritten.isEmpty)
        #expect(try sandbox.text("IMG_0001.xmp") == written && Self.modified(sandbox.url("IMG_0001.xmp")) == date)
    }

    @Test(arguments: [RootRecord.Sidecars.besidePhotos, .onThisMac])
    func `another app's later change is taken into the .redlamp through its root's locator, keeping what only Redlamp has`(
        _ placement: RootRecord.Sidecars,
    ) async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        let photo = try sandbox.photo("IMG_0002.ARW")
        try sandbox.write("IMG_0002.xmp", OtherApps.lightroom(rating: 2, label: "Red"), modified: -600)
        try await sandbox.indexAll()
        let sidecars = LibrarySidecars(index: sandbox.index)
        let rootPath = LibraryIndexer.path(sandbox.root)
        let root = try #require(try await sandbox.index.read { try $0.root(path: rootPath) })
        try await sidecars.setPlacement(placement, forRoot: root.id)
        let store = try await SidecarStore(locator: sidecars.locator())
        try sandbox.sidecar("IMG_0002.ARW", PhotoMetadata(rating: 2, flag: .pick, label: .red), store: store)
        #expect(FileManager.default
            .fileExists(atPath: SidecarLocator.besidePhoto(photo).path) == (placement == .besidePhotos))

        let first = try await sandbox.sync()
        #expect(first.photo("IMG_0002.ARW")?.taken == [])

        try sandbox.write("IMG_0002.xmp", OtherApps.lightroom(rating: 5, label: "Approved"), modified: 60)
        let report = try await sandbox.sync()
        let synced = try #require(report.photo("IMG_0002.ARW"))
        #expect(synced.taken == [.rating, .label] && synced.problem == nil)
        #expect(report.lines.contains("1 .redlamp sidecar took other apps' changes: rating 1, label 1"))

        let sidecar = try #require(store.load(for: photo))
        #expect(sidecar.metadata == PhotoMetadata(rating: 5, flag: .pick, label: .green))
        #expect(sidecar.recipe[.exposure] == 0.35 && sidecar.snapshots.map(\.name) == ["Before"])
        #expect(sidecar.unknownFields["fromTheFuture"] == .string("kept"))
        let id = try await sandbox.id("IMG_0002.ARW")
        let row = try #require(try await sandbox.index.read { try $0.photo(id: id) })
        #expect(row.rating == 5 && row.flag == .pick && row.label == .green)
        #expect(LibraryXMP.changedPhotos(report) == [id])
        #expect(!sandbox.exists("IMG_0002.ARW.redlamp") || placement == .besidePhotos)
    }

    @Test func `a change once taken isn't taken again, so Redlamp's own change after it stands`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        let photo = try sandbox.photo("IMG_0003.NEF")
        try sandbox.write("IMG_0003.xmp", OtherApps.lightroom(rating: 1), modified: -600)
        try sandbox.sidecar("IMG_0003.NEF", PhotoMetadata(rating: 1))
        try await sandbox.indexAll()
        _ = try await sandbox.sync()
        try sandbox.write("IMG_0003.xmp", OtherApps.lightroom(rating: 4), modified: 60)
        #expect(try await sandbox.sync().photo("IMG_0003.NEF")?.taken == [.rating])
        #expect(sandbox.metadata("IMG_0003.NEF")?.rating == 4)

        // Rated 2 in Redlamp; the .xmp still says 4, and that change was taken already.
        var sidecar = try #require(SidecarStore().load(for: photo))
        sidecar.metadata?.rating = 2
        try SidecarStore().save(sidecar, for: photo)
        let report = try await sandbox.sync()
        #expect(report.photo("IMG_0003.NEF")?.taken == [] && sandbox.metadata("IMG_0003.NEF")?.rating == 2)
        #expect(try await sandbox.sync().photo("IMG_0003.NEF")?.unchanged == true)
        #expect(sandbox.metadata("IMG_0003.NEF")?.rating == 2)
    }

    @Test func `an .xmp rewritten keeps every element and namespace Redlamp doesn't own, byte for byte`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        let photo = try sandbox.photo("IMG_0004.CR3")
        let original = OtherApps.lightroom(rating: 2, label: "Red", keywords: ["Places/Portugal"])
        try sandbox.write("IMG_0004.xmp", original, modified: -600)
        try sandbox.sidecar("IMG_0004.CR3", PhotoMetadata(rating: 2, label: .red))
        try await sandbox.indexAll()
        try await sandbox.xmp.setSettings(XMPSettings(writes: true))
        #expect(try await sandbox.sync().xmpWritten.isEmpty)

        var sidecar = try #require(SidecarStore().load(for: photo))
        sidecar.metadata = PhotoMetadata(rating: 4, label: .blue)
        try SidecarStore().save(sidecar, for: photo)
        let report = try await sandbox.sync()
        #expect(report.photo("IMG_0004.CR3")?.written == [.rating, .label])

        let written = try sandbox.text("IMG_0004.xmp")
        let date = try #require(written.firstRange(of: /xmp:MetadataDate="([^"]+)"/)?.lowerBound)
        let stamp = String(written[date...].prefix { $0 != ">" })
        #expect(written == original.replacingOccurrences(of: "xmp:Rating=\"2\"", with: "xmp:Rating=\"4\"")
            .replacingOccurrences(of: "xmp:Label=\"Red\"", with: "xmp:Label=\"Blue\"")
            .replacingOccurrences(
                of: "acme:Reviewed=\"yes\">", with: "acme:Reviewed=\"yes\"\n   xmp:LabelColor=\"blue\"\n   \(stamp)>",
            ))
        let packet = try #require(XMPPacket(Data(written.utf8)))
        #expect(packet.items(XMPNamespace.hierarchicalSubject) == ["Places|Portugal"])
        #expect(packet.text(XMPProperty("http://example.com/acme/1.0/", "Reviewed")) == "yes")
    }

    @Test func `writes are atomic, only ever .xmp, and never replace a file another app changed meanwhile`() throws {
        let folder = try TemporaryFolder()
        let target = folder.url.appending(path: "IMG_0005.xmp")
        let first = Array(OtherApps.lightroom(rating: 1).utf8)
        let second = Array(OtherApps.lightroom(rating: 2).utf8)

        #expect(try XMPSidecarWriter.write(first, to: target, replacing: nil) != nil)
        #expect(try Data(contentsOf: target) == Data(first))
        #expect(throws: XMPSidecarWriter.Failure.self) { try XMPSidecarWriter.write(second, to: target, replacing: nil)
        }
        #expect(throws: XMPSidecarWriter.Failure.self) { try XMPSidecarWriter.write(
            second,
            to: target,
            replacing: second,
        ) }
        #expect(try Data(contentsOf: target) == Data(first))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let inode = try Self.inode(target)
        #expect(try XMPSidecarWriter.write(second, to: target, replacing: first) != nil)
        #expect(try Data(contentsOf: target) == Data(second))
        #expect(try Self.inode(target) != inode, "replaced by a rename, never written in place")
        #expect(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["IMG_0005.xmp"])

        let photo = folder.url.appending(path: "IMG_0005.ARW")
        try Data([1, 2, 3]).write(to: photo)
        #expect(throws: XMPSidecarWriter.Failure.self) { try XMPSidecarWriter.write(
            first,
            to: photo,
            replacing: [1, 2, 3],
        ) }
        #expect(try Data(contentsOf: photo) == Data([1, 2, 3]))
    }

    @Test func `a raw and its JPEG share name.xmp, and neither one's write removes the other's fields`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("IMG_0006.ARW")
        let jpeg = try sandbox.photo("IMG_0006.JPG")
        let original = OtherApps.lightroom(rating: 0, keywords: ["Birds/Gulls"])
        try sandbox.write("IMG_0006.xmp", original, modified: -600)
        try sandbox.sidecar("IMG_0006.ARW", PhotoMetadata(rating: 5))
        try sandbox.sidecar("IMG_0006.JPG", PhotoMetadata(rating: 2, label: .blue))
        try await sandbox.indexAll()
        try await sandbox.xmp.setSettings(XMPSettings(writes: true))

        let report = try await sandbox.sync(["IMG_0006.JPG"])
        let raw = try #require(report.photo("IMG_0006.ARW"))
        #expect(raw.sharedWith == ["IMG_0006.JPG"] && raw.written == [.rating])
        #expect(report.photo("IMG_0006.JPG")?.written == [.label])
        var packet = try #require(XMPPacket(Data(contentsOf: sandbox.url("IMG_0006.xmp"))))
        #expect(packet.text(XMPNamespace.rating) == "5" && packet.text(XMPNamespace.label) == "Blue")
        #expect(packet.items(XMPNamespace.hierarchicalSubject) == ["Birds|Gulls"])

        // The JPEG clears its label and rates itself 1: the raw's rating stays, and so does the label,
        // which the JPEG doesn't clear for the raw.
        var sidecar = try #require(SidecarStore().load(for: jpeg))
        sidecar.metadata = PhotoMetadata(rating: 1)
        try SidecarStore().save(sidecar, for: jpeg)
        _ = try await sandbox.sync()
        packet = try #require(XMPPacket(Data(contentsOf: sandbox.url("IMG_0006.xmp"))))
        #expect(packet.text(XMPNamespace.rating) == "5" && packet.text(XMPNamespace.label) == "Blue")
        #expect(!sandbox.exists("IMG_0006.JPG.xmp") && !sandbox.exists("IMG_0006.ARW.xmp"))
        #expect(sandbox.metadata("IMG_0006.JPG") == PhotoMetadata(rating: 1))
    }

    @Test func `darktable's name.ext.xmp is read, and never written`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        let photo = try sandbox.photo("IMG_0007.ARW")
        let darktable = OtherApps.darktable(rating: 3, colorLabel: 1)
        try sandbox.write("IMG_0007.ARW.xmp", darktable, modified: -600)
        try sandbox.sidecar("IMG_0007.ARW", PhotoMetadata())
        try await sandbox.indexAll()
        try await sandbox.xmp.setSettings(XMPSettings(writes: true))

        let report = try await sandbox.sync()
        let synced = try #require(report.photo("IMG_0007.ARW"))
        #expect(synced.darktable?.hasSuffix("IMG_0007.ARW.xmp") == true && synced.taken == [.rating, .label])
        #expect(sandbox.metadata("IMG_0007.ARW") == PhotoMetadata(rating: 3, label: .yellow))
        #expect(!sandbox.exists("IMG_0007.xmp"))

        // Rated again in Redlamp: a new IMG_0007.xmp gets the .redlamp's fields, darktable's stays as it was.
        var sidecar = try #require(SidecarStore().load(for: photo))
        sidecar.metadata?.rating = 4
        try SidecarStore().save(sidecar, for: photo)
        #expect(try await sandbox.sync().photo("IMG_0007.ARW")?.written == [.rating, .label])
        let packet = try #require(XMPPacket(Data(contentsOf: sandbox.url("IMG_0007.xmp"))))
        #expect(packet.text(XMPNamespace.rating) == "4" && packet.text(XMPNamespace.label) == "Yellow")
        #expect(try sandbox.text("IMG_0007.ARW.xmp") == darktable)
    }

    @Test func `the originals are never written`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        let names = ["IMG_0008.ARW", "IMG_0008.JPG", "IMG_0009.HEIC", "IMG_0010.DNG"]
        for name in names {
            try sandbox.photo(name)
            try sandbox.sidecar(name, PhotoMetadata(rating: 3, flag: .reject, label: .purple))
        }
        try sandbox.write("IMG_0009.xmp", OtherApps.lightroom(rating: 1, label: "Red"), modified: -600)
        try await sandbox.indexAll()
        let photos = try names.map { name in
            try (
                name,
                Data(contentsOf: sandbox.url(name)),
                Self.modified(sandbox.url(name)),
                Self.inode(sandbox.url(name)),
            )
        }
        _ = try await sandbox.sync()
        _ = try await sandbox.sync(writing: true)
        try sandbox.write("IMG_0009.xmp", OtherApps.lightroom(rating: 5), modified: 60)
        _ = try await sandbox.sync(writing: true)
        for (name, data, modified, inode) in photos {
            let url = sandbox.url(name)
            #expect(try Data(contentsOf: url) == data && Self.modified(url) == modified && Self.inode(url) == inode)
        }
        #expect(try XMPPacket(Data(contentsOf: sandbox.url("IMG_0008.xmp")))?.text(XMPNamespace.rating) == "-1")
    }

    @Test func `the indexer isn't sent back to a photo for an .xmp Redlamp wrote, only for another app's`(
    ) async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        let ours = try sandbox.photo("IMG_0011.ARW")
        let theirs = try sandbox.photo("IMG_0012.ARW")
        try sandbox.sidecar("IMG_0011.ARW", PhotoMetadata(rating: 4))
        try sandbox.sidecar("IMG_0012.ARW", PhotoMetadata(rating: 3))
        try sandbox.write("IMG_0012.xmp", OtherApps.lightroom(rating: 2), modified: -600)
        try await sandbox.indexAll()
        let report = try await sandbox.sync(writing: true)
        #expect(report.xmpWritten.count == 2)

        try sandbox.write("IMG_0012.xmp", OtherApps.lightroom(rating: 1, label: "Green"), modified: 60)
        let counting = CountingFileSystem()
        let indexer = LibraryIndexer(index: sandbox.index, fileSystem: counting, configuration: .testing())
        let run = await IndexerRun.collect(indexer.update([FolderChange(sandbox.root)]))
        #expect(run.failures.isEmpty)
        let reads = counting.counts.reads
        #expect(reads[LibraryIndexer.path(ours)] == nil, "\(reads)")
        #expect(reads[LibraryIndexer.path(theirs)] != nil, "\(reads)")
    }

    @Test func `a dry run works out the merge and the writes and changes nothing`() async throws {
        let sandbox = try await XMPSandbox.make()
        defer { sandbox.remove() }
        try sandbox.photo("IMG_0013.ARW")
        try sandbox.write("IMG_0013.xmp", OtherApps.lightroom(rating: 2), modified: -600)
        try sandbox.sidecar("IMG_0013.ARW", PhotoMetadata(label: .red))
        try await sandbox.indexAll()
        let before = try Self.contents(below: sandbox.root)
        let report = try await sandbox.sync(writing: true, dryRun: true)
        let photo = try #require(report.photo("IMG_0013.ARW"))
        #expect(photo.taken == [.rating] && photo.written == [.label] && photo.merged == XMPFields(
            rating: 2,
            label: .red,
        ))
        #expect(report.lines.last == "A dry run: nothing was written.")
        #expect(try Self.contents(below: sandbox.root) == before)
        let id = try await sandbox.id("IMG_0013.ARW")
        #expect(try await sandbox.index.read { try XMPMergeRecord.records([id], in: $0) }.isEmpty)
    }
}
