import Foundation
import RedlampDocument
import RedlampEngineAPI
import Testing
@testable import RedlampLibrary
@_spi(Harness) @testable import RedlampUI

/// Undo leaves every photo's files as they were (LIB-15, LIB-24): after culling, a keyword, a preset or a rename
/// and its Undo, a photo that had no `.redlamp` has none, one that had one has it as it was, and the keywords,
/// caption, creator and label another app wrote stay in its `.xmp`, never copied into a `.redlamp`: with the XMP
/// sync on and off, through Redo, and for a photo the library hasn't indexed yet. Change tracking is stopped, and
/// reads the photos again only as it does when it lists their folder while a batch writes their sidecars.
@MainActor
struct UndoSidecarsTests {
    /// What another app wrote beside a photo, as Lightroom Classic writes it: two keywords, a caption, a creator
    /// and a label, and no rating.
    static let otherApp = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
       xmp:Label="Yellow">
       <dc:subject><rdf:Bag><rdf:li>Trams</rdf:li><rdf:li>Lisbon</rdf:li></rdf:Bag></dc:subject>
       <dc:description><rdf:Alt><rdf:li xml:lang="x-default">Tram 28 in Alfama</rdf:li></rdf:Alt></dc:description>
       <dc:creator><rdf:Seq><rdf:li>Ana Sousa</rdf:li></rdf:Seq></dc:creator>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>

    """

    static func xmp(of photo: URL) -> URL {
        photo.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// Writes the other app's `.xmp` beside each of `photos`, in folders that may not be there yet.
    static func writeOtherApp(beside photos: [URL]) throws {
        for photo in photos {
            try FileManager.default.createDirectory(
                at: photo.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try Data(otherApp.utf8).write(to: xmp(of: photo))
        }
    }

    /// What the photo's `.xmp` holds, as other apps read it.
    static func fields(of photo: URL) -> XMPFields? {
        (try? Data(contentsOf: xmp(of: photo))).flatMap { XMPSource(xmp: $0) }?.fields
    }

    static func hasSidecar(_ photo: URL) -> Bool {
        FileManager.default.fileExists(atPath: SidecarStore().url(for: photo).path)
    }

    /// The files of the photo's `.redlamp` and each one's bytes, its edit's without the date it was saved, which
    /// every save writes anew; none without one.
    static func sidecarFiles(of photo: URL) throws -> [String: Data] {
        let sidecar = SidecarStore().url(for: photo)
        guard let found = FileManager.default.enumerator(atPath: sidecar.path) else { return [:] }
        var files: [String: Data] = [:]
        for case let path as String in found {
            let url = sidecar.appending(path: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
            else { continue }
            var data = try Data(contentsOf: url)
            if path == SidecarStore.editFile {
                let text = String(decoding: data, as: UTF8.self)
                data = Data(text.replacing(#/"modified" : "[^"]*"/#, with: #""modified" : """#).utf8)
            }
            files[path] = data
        }
        return files
    }

    /// Reads `folder` again as change tracking does when it lists it while a batch writes the sidecars of
    /// `photos`, before the batch has recorded their dates: the folder's listing isn't the one its photos were
    /// indexed at, their rows hold no date for their sidecars, the indexer reads them again, and the app follows
    /// its events; then the XMP syncs they start are done. A photo the index doesn't have yet is indexed.
    static func readAgain(_ photos: [URL], in folder: URL, service: LibraryService) async throws {
        let core = try #require(service.core)
        let ids = await LibraryService.indexIDs(of: photos, in: core.index)
        try await core.index.write { writer in
            for id in ids.values {
                try writer.setSidecarModified(nil, forPhoto: id)
            }
            if let listed = try LibraryService.folder(at: LibraryService.path(folder), in: writer) {
                try writer.setIndexedSignature(nil, forFolder: listed.id)
            }
        }
        for await event in core.indexer.update([FolderChange(folder, recursive: true)]) {
            await LibraryService.followed(.indexer(event), core: core) { _ in }
        }
        await service.xmpSynced()
    }

    /// `CullingTests.IndexedFolder`'s four photos, the second with a `.redlamp` holding an edit and two stars and
    /// the third with none, both with the other app's `.xmp`; the XMP sync writing `.xmp` when `writing`, and
    /// change tracking stopped.
    static func open(writing: Bool) async throws -> CullingTests.IndexedFolder {
        let folder = CullingTests.IndexedFolder()
        try writeOtherApp(beside: [1, 2].map { folder.root.appending(path: String(format: "IMG_%04d.JPG", $0)) })
        try await folder.open(count: 4)
        let service = try #require(folder.service)
        try #require(service.core).tracker.stop()
        if writing {
            #expect(await service.setXMPSettings(XMPSettings(writes: true)))
        }
        return folder
    }

    /// Until the changes asked for are made, the syncs after them done, and the folder read again as change
    /// tracking reads it while they're written.
    static func written(_ folder: CullingTests.IndexedFolder) async throws {
        await folder.written()
        await folder.service.xmpSynced()
        try await readAgain(folder.photos, in: folder.root, service: folder.service)
    }

    // MARK: - Culling

    @Test(arguments: [false, true])
    func `culling, its Undo and its Redo leave other apps' fields in their .xmp, never in a .redlamp`(
        writing: Bool,
    ) async throws {
        let folder = try await Self.open(writing: writing)
        defer { folder.cleanUp() }
        let model = try #require(folder.model)
        let (edited, bare) = (folder.photos[1], folder.photos[2])
        let theirs = try #require(Self.fields(of: bare))
        #expect(theirs.keywords == ["Trams", "Lisbon"] && theirs.caption == "Tram 28 in Alfama")
        #expect(theirs.creator == "Ana Sousa" && theirs.label == .yellow && theirs.rating == nil)
        let xmps = try [edited, bare].map { try Data(contentsOf: Self.xmp(of: $0)) }
        let sidecar = try Self.sidecarFiles(of: edited)
        #expect(!sidecar.isEmpty && !Self.hasSidecar(bare))

        model.click(edited)
        model.click(bare, extending: true)
        #expect(model.perform(.rating3))
        try await Self.written(folder)
        #expect(folder.sidecar(2) == PhotoMetadata(rating: 3), "the .redlamp the rating made holds it alone")
        #expect(folder.sidecar(1)?.keywords == nil && folder.sidecar(1)?.caption == nil)

        #expect(model.perform(.undo))
        try await Self.written(folder)
        #expect(
            !Self.hasSidecar(bare),
            "a photo that had no .redlamp has none: \(String(describing: folder.sidecar(2)))",
        )
        #expect(try Self.sidecarFiles(of: edited) == sidecar, "one that had one has it as it was")
        if writing {
            #expect(Self.fields(of: bare) == theirs, "its .xmp holds what the other app wrote, and no rating")
            let other = Self.fields(of: edited)
            #expect(other?.keywords == theirs.keywords && other?.caption == theirs.caption)
            #expect(other?.creator == theirs.creator && other?.label == theirs.label)
        } else {
            #expect(try [edited, bare].map { try Data(contentsOf: Self.xmp(of: $0)) } == xmps, "the .xmp untouched")
        }

        #expect(model.perform(.redo))
        try await Self.written(folder)
        #expect(folder.sidecar(2) == PhotoMetadata(rating: 3), "Redo makes the rating alone again")
        #expect(folder.sidecar(1)?.rating == 3 && folder.sidecar(1)?.keywords == nil)
        if writing {
            #expect(Self.fields(of: bare)?.rating == 3 && Self.fields(of: bare)?.keywords == theirs.keywords)
        }

        #expect(model.perform(.undo))
        try await Self.written(folder)
        #expect(!Self.hasSidecar(bare))
        #expect(try Self.sidecarFiles(of: edited) == sidecar)
        if writing {
            #expect(Self.fields(of: bare) == theirs)
        } else {
            #expect(try [edited, bare].map { try Data(contentsOf: Self.xmp(of: $0)) } == xmps)
        }
    }

    @Test func `a photo the library hasn't indexed yet, culled through its own save, is put back as it was too`(
    ) async throws {
        let folder = try await Self.open(writing: false)
        defer { folder.cleanUp() }
        let model = try #require(folder.model)
        // Saved a moment ago, as a stack document is: listed, the index not holding it yet.
        let new = folder.root.appending(path: "IMG_0100.JPG")
        try CullingTests.IndexedFolder.writeJPEG(new, shade: 9)
        try Self.writeOtherApp(beside: [new])
        let xmps = try [folder.photos[2], new].map { try Data(contentsOf: Self.xmp(of: $0)) }
        model.library.insert(LibraryItem(url: new))
        let index = try #require(folder.service.core).index
        #expect(await LibraryService.indexIDs(of: [new], in: index).isEmpty)

        model.click(folder.photos[2])
        model.click(new, toggling: true)
        #expect(model.selectedPhotos.count == 2 && model.perform(.rating3))
        await folder.written()
        #expect(SidecarStore().load(for: new)?.metadata == PhotoMetadata(rating: 3), "through its own save")
        // The library indexes it, then reads it again with the other.
        try await Self.readAgain([], in: folder.root, service: folder.service)
        #expect(await LibraryService.indexIDs(of: [new], in: index).count == 1)
        try await Self.readAgain([folder.photos[2], new], in: folder.root, service: folder.service)
        #expect(SidecarStore().load(for: new)?.metadata == PhotoMetadata(rating: 3))

        #expect(model.perform(.undo))
        try await Self.written(folder)
        try await Self.readAgain([new], in: folder.root, service: folder.service)
        #expect(!Self.hasSidecar(folder.photos[2]) && !Self.hasSidecar(new), "neither has a .redlamp")
        #expect(try [folder.photos[2], new].map { try Data(contentsOf: Self.xmp(of: $0)) } == xmps)
    }

    // MARK: - The panels and Rename

    @Test func `a keyword and a preset from the panels, and their Undo, leave a photo without a .redlamp so`(
    ) async throws {
        let folder = LibraryPanelsTests.Folder()
        defer { folder.close() }
        try Self.writeOtherApp(beside: [folder.root.appending(path: "IMG_0001.JPG")])
        try await folder.open(count: 3)
        try #require(folder.service.core).tracker.stop()
        let photo = folder.photos[1]
        let xmp = try Data(contentsOf: Self.xmp(of: photo))
        func readAgain() async throws {
            try await folder.written()
            try await Self.readAgain([photo], in: folder.root, service: folder.service)
        }
        try await folder.select([1])

        #expect(folder.panels.addKeywords("Trams > 28E"))
        try await readAgain()
        #expect(folder.keywords(1) == ["Lisbon", "Trams", "Trams/28E"], "the keyword with the other app's")
        #expect(folder.metadata(1)?.caption == nil && folder.metadata(1)?.creator == nil)
        #expect(folder.model.perform(.undo))
        try await readAgain()
        #expect(!Self.hasSidecar(photo), "\(String(describing: folder.metadata(1)))")
        #expect(try Data(contentsOf: Self.xmp(of: photo)) == xmp)

        let preset = MetadataPreset(name: "Tram", fields: [
            .caption: MetadataPreset.Entry("(Remodelado)", mode: .append),
            .title: MetadataPreset.Entry("Line 28"),
        ])
        #expect(await folder.panels.save(preset))
        try await folder.eventually { folder.panels.presets.map(\.name) == ["Tram"] }
        #expect(folder.panels.apply(preset))
        try await readAgain()
        #expect(folder.metadata(1)?.title == "Line 28" && folder.metadata(1)?.caption?
            .hasSuffix("(Remodelado)") == true)
        #expect(folder.metadata(1)?.keywords == nil && folder.metadata(1)?.creator == nil)
        #expect(folder.model.perform(.undo))
        try await readAgain()
        #expect(!Self.hasSidecar(photo), "\(String(describing: folder.metadata(1)))")
        #expect(try Data(contentsOf: Self.xmp(of: photo)) == xmp)
    }

    @Test func `a rename, its Undo and its Redo leave the other app's fields in the .xmp that goes with the photo`(
    ) async throws {
        let folder = RenameTests.RenameFolder()
        defer { folder.cleanUp() }
        try Self.writeOtherApp(beside: [folder.url("IMG_0002.JPG")])
        try await folder.open()
        try folder.stopChangeTracking()
        let model = try #require(folder.model)
        let xmp = try Data(contentsOf: folder.url("IMG_0002.xmp"))
        let before = folder.files()
        model.select(folder.url("IMG_0002.JPG"))
        let sheet = try await folder.sheet()
        sheet.setText("Tram-{sequence}")
        #expect(await model.rename(sheet) == nil)
        await model.filesMade()
        let renamed = folder.url("Tram-1.JPG")
        #expect(folder.files().contains("Tram-1.JPG.redlamp") && folder.files().contains("Tram-1.xmp"))
        try await Self.readAgain([renamed], in: folder.root, service: folder.service)
        #expect(SidecarStore().load(for: renamed)?.metadata == PhotoMetadata(originalName: "IMG_0002.JPG"))

        #expect(model.perform(.undo))
        await model.filesMade()
        try await Self.readAgain([folder.url("IMG_0002.JPG")], in: folder.root, service: folder.service)
        #expect(folder.files() == before, "\(folder.files())")
        #expect(try Data(contentsOf: folder.url("IMG_0002.xmp")) == xmp)

        #expect(model.perform(.redo))
        await model.filesMade()
        try await Self.readAgain([renamed], in: folder.root, service: folder.service)
        #expect(SidecarStore().load(for: renamed)?.metadata == PhotoMetadata(originalName: "IMG_0002.JPG"))
        #expect(model.perform(.undo))
        await model.filesMade()
        #expect(folder.files() == before && (try? Data(contentsOf: folder.url("IMG_0002.xmp"))) == xmp)
    }
}
