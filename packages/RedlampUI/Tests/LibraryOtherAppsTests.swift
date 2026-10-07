import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// Other apps' metadata in the app (LIB-24): writing `.xmp` off by default and turned on from Settings
/// only once that's confirmed; with it on, culling, its Undo and its Redo reaching the photos' `.xmp`
/// after their batches; and another app's later change to an `.xmp`, as change tracking passes it on,
/// merged into the `.redlamp`, keeping what each side holds.
@MainActor
struct LibraryOtherAppsTests {
    private typealias Folder = CullingTests.IndexedFolder

    private static func xmp(of photo: URL) -> URL {
        photo.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// What the photo's `.xmp` holds, as other apps read it; nil without one.
    private static func fields(of photo: URL) -> XMPFields? {
        (try? Data(contentsOf: xmp(of: photo))).flatMap { XMPSource(xmp: $0) }?.fields
    }

    /// Until the culling asked for, and the XMP syncs after it, are done.
    private static func synced(_ folder: Folder) async {
        await folder.written()
        await folder.service.xmpSynced()
    }

    @Test func `writing .xmp is off by default, and Settings turns it on and off only once that's confirmed`(
    ) async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        try await folder.open(count: 3)
        let service = try #require(folder.service)
        let core = try #require(service.core)
        #expect(service.xmpSettings == XMPSettings(writes: false))

        let settings = LibrarySettingsModel(library: service)
        await settings.countPhotos()
        #expect(settings.status == "3 photos")
        settings.ask(writes: true)
        #expect(settings.confirming == .turningOn)
        #expect(settings.message(.turningOn).contains("The 3 photos already in the library are left as they are"))
        #expect(try await core.xmp.settings().writes == false, "nothing changes until it's confirmed")
        settings.cancel()
        #expect(settings.confirming == nil && service.xmpSettings?.writes == false)

        settings.ask(writes: true)
        await settings.confirm()?.value
        #expect(try await core.xmp.settings().writes && service.xmpSettings?.writes == true)
        await service.xmpSynced()
        #expect(folder.photos.allSatisfy { Self.fields(of: $0) == nil }, "the photos already there are left alone")

        await settings.set(labels: .bridge).value
        await settings.set(urgency: true).value
        #expect(try await core.xmp.settings() == XMPSettings(
            writes: true, conventions: XMPConventions(labels: .bridge, urgency: true),
        ))
        settings.ask(writes: false)
        #expect(settings.confirming == .turningOff && settings.message(.turningOff).contains("stay beside your photos"))
        await settings.confirm()?.value
        #expect(try await core.xmp.settings().writes == false && !core.xmpSettings.writes)
    }

    @Test func `with writing on, a rating culled reaches its photos' .xmp, Undo takes it back and Redo makes it again`(
    ) async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        try await folder.open(count: 4)
        let service = try #require(folder.service)
        #expect(await service.setXMPSettings(XMPSettings(writes: true)))
        let model = try #require(folder.model)
        // The second photo's .redlamp holds two stars and an edit; the third has none.
        model.click(folder.photos[1])
        model.click(folder.photos[2], extending: true)
        #expect(model.selectedPhotos.count == 2)

        #expect(model.perform(.rating4))
        await Self.synced(folder)
        #expect(Self.fields(of: folder.photos[1])?.rating == 4 && Self.fields(of: folder.photos[2])?.rating == 4)
        #expect(Self.fields(of: folder.photos[0]) == nil && Self.fields(of: folder.photos[3]) == nil)

        #expect(model.perform(.undo))
        await Self.synced(folder)
        #expect(folder.sidecar(1)?.rating == 2 && !folder.hasSidecar(2))
        #expect(Self.fields(of: folder.photos[1])?.rating == 2, "the .xmp gets back the rating its .redlamp has")
        #expect(Self.fields(of: folder.photos[2])?.rating == nil, "and loses the one a .redlamp Undo removed gave it")

        #expect(model.perform(.redo))
        await Self.synced(folder)
        #expect(Self.fields(of: folder.photos[1])?.rating == 4 && Self.fields(of: folder.photos[2])?.rating == 4)

        // Turned off, a change reaches the .redlamp and leaves the .xmp as it is.
        #expect(await service.setXMPSettings(XMPSettings(writes: false)))
        #expect(model.perform(.rating1))
        await Self.synced(folder)
        #expect(folder.sidecar(1)?.rating == 1 && Self.fields(of: folder.photos[1])?.rating == 4)
    }

    @Test func `another app's later change to an .xmp, as change tracking passes it on, is merged into the .redlamp`(
    ) async throws {
        let folder = Folder()
        defer { folder.cleanUp() }
        try await folder.open(count: 3)
        let service = try #require(folder.service)
        let core = try #require(service.core)
        #expect(await service.setXMPSettings(XMPSettings(writes: true)))
        let model = try #require(folder.model)
        let photo = folder.photos[1]
        model.click(photo)
        #expect(model.perform(.flagPick))
        await Self.synced(folder)
        #expect(Self.fields(of: photo)?.rating == 2 && Self.fields(of: photo)?.flag == .pick)

        // Another app writes the .xmp afresh a moment later, as Lightroom Classic does: five stars, still
        // picked, and a keyword.
        let lightroom = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmp:Rating="5"
           xmpDM:good="True">
           <dc:subject><rdf:Bag><rdf:li>Birds</rdf:li></rdf:Bag></dc:subject>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>

        """
        try Data(lightroom.utf8).write(to: Self.xmp(of: photo))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: Self.xmp(of: photo).path,
        )
        for await event in core.indexer.update([FolderChange(folder.root)]) {
            await LibraryService.followed(.indexer(event), core: core) { _ in }
        }
        await service.xmpSynced()

        let sidecar = try #require(SidecarStore().load(for: photo))
        #expect(sidecar.metadata?.rating == 5 && sidecar.metadata?.keywords == ["Birds"], "the other app's changes")
        #expect(sidecar.metadata?.flag == .pick, "what only the .redlamp changed stays")
        #expect(sidecar.recipe[.exposure] == 0.5, "and so does its edit")
        #expect(Self.fields(of: photo)?.rating == 5 && Self.fields(of: photo)?.flag == .pick)
        try await folder.eventually { folder.shown(1).rating == 5 }
        #expect(folder.shown(1).rating == 5 && folder.shown(1).flag == .pick)
    }
}
