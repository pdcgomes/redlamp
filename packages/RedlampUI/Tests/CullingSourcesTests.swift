import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// Culling with a source shown rather than a folder (LIB-15, LIB-23): a change made with All Photographs, a
/// collection, Marked or Rejected shown reaches each photo's sidecar, in Library and in Develop, as one made in its
/// folder does, so the photos' folders indexed again keep it.
@MainActor
@Suite(.serialized)
struct CullingSourcesTests {
    /// The photos' culling fields as their sidecars hold them, by name.
    private static func sidecars(_ photos: [URL]) -> [String: CullingValues] {
        photos.reduce(into: [:]) { found, photo in
            found[photo.lastPathComponent] = CullingValues(SidecarStore().load(for: photo)?.metadata ?? PhotoMetadata())
        }
    }

    /// The photos' culling fields in an index built afresh from the sandbox's folders, as a rebuilt or another
    /// Mac's index has them.
    private static func rebuilt(_ photos: [URL], _ sandbox: SourcesSandbox) async throws -> [String: CullingValues] {
        let library = FolderLibrary()
        library.add([sandbox.root])
        let service = LibraryService(
            paths: LibraryPaths(root: sandbox.base.appending(path: "Rebuilt", directoryHint: .isDirectory)),
            sidecars: library.sidecars,
        ) { url, size in StoreThumbnailMaker.imageIO(url, nil, size) }
        defer { service.close() }
        library.attach(service)
        for _ in 0 ..< 2000 where await !service.canShow(sandbox.root, includingSubfolders: true) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await service.canShow(sandbox.root, includingSubfolders: true), "the index built afresh")
        return try await rows(photos, in: #require(service.core))
    }

    /// The photos' culling fields as the index's rows hold them, by name.
    private static func rows(_ photos: [URL], in core: LibraryCore) async throws -> [String: CullingValues] {
        let ids = await LibraryService.indexIDs(of: photos, in: core.index)
        return try await core.index.read { reader in
            try photos.reduce(into: [:]) { found, photo in
                guard let id = ids[photo], let row = try reader.photo(id: id) else { return }
                var metadata = PhotoMetadata(rating: row.rating)
                metadata.flag = row.flag
                metadata.label = row.label
                metadata.customLabel = row.customLabel
                metadata.mark = row.marked
                found[photo.lastPathComponent] = CullingValues(metadata)
            }
        }
    }

    private static func values(
        rating: Int = 0, flag: PhotoFlag? = nil, label: ColorLabel? = nil, mark: Bool = false,
    ) -> CullingValues {
        var metadata = PhotoMetadata(rating: rating)
        metadata.flag = flag
        metadata.label = label
        metadata.mark = mark
        return CullingValues(metadata)
    }

    @Test func `changes made with All Photographs, a collection, Marked and Rejected shown reach the sidecars`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG", "Shoot/C.JPG", "Other/D.JPG", "Other/E.JPG"])
        let model = try await sandbox.open()
        let core = try #require(sandbox.service?.core)
        let sources = model.librarySources
        let (a, b, c) = (sandbox.photo("Shoot/A.JPG"), sandbox.photo("Shoot/B.JPG"), sandbox.photo("Shoot/C.JPG"))
        let (d, e) = (sandbox.photo("Other/D.JPG"), sandbox.photo("Other/E.JPG"))
        let photos = [a, b, c, d, e]
        func show(_ source: LibrarySource, _ shown: Set<URL>) async throws {
            #expect(sources.show(source))
            try await sandbox.eventually { !sources.isListing && Set(model.items.map(\.url)) == shown }
            try #require(Set(model.items.map(\.url)) == shown, "\(source)'s photos shown")
        }

        try await show(.allPhotographs, Set(photos))
        try await sandbox.cull(.rating3, [a, d])
        try await sandbox.cull(.toggleMark, [a, d])
        try await sandbox.cull(.flagReject, [c])
        try await sandbox.cull(.labelRed, [e])

        try await sandbox.counts { $0.isCounted }
        #expect(sources.create(.collection, named: "Selects"))
        let selects = try #require(CollectionPath("Selects"))
        try await sandbox.counts { $0.collections[selects] != nil }
        model.select(b)
        model.click(e, toggling: true)
        #expect(sources.add(to: selects))
        await model.libraryPanels.written()
        try await sandbox.counts { $0.count(of: .collection(selects)) == 2 && $0.count(of: .rejected) == 1 }
        try await show(.collection(selects), [b, e])
        try await sandbox.cull(.flagPick, [b, e])

        try await show(.marked, [a, d])
        try await sandbox.cull(.toggleMark, [d])
        try await sandbox.eventually { model.items.map(\.url) == [a] }

        try await show(.rejected, [c])
        try await sandbox.cull(.rating2, [c])

        let expected = [
            "A.JPG": Self.values(rating: 3, mark: true), "B.JPG": Self.values(flag: .pick),
            "C.JPG": Self.values(rating: 2, flag: .reject), "D.JPG": Self.values(rating: 3),
            "E.JPG": Self.values(flag: .pick, label: .red),
        ]
        #expect(Self.sidecars(photos) == expected)
        #expect(try await Self.rows(photos, in: core) == expected)
        #expect(try await Self.rebuilt(photos, sandbox) == expected, "an index built afresh has each change")
    }

    @Test func `with no photo listed for it to reach, a culling key isn't performed and changes nothing`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["A.JPG", "B.JPG"])
        let model = try await sandbox.open()
        let b = sandbox.photo("B.JPG")
        model.select(b)
        try #require(model.module == .library && model.items.isEmpty && model.selection == b)
        #expect(!model.canPerform(.rating3), "the menus and the palette don't offer it")
        #expect(!model.perform(.rating3), "the key goes on to the rest of the app")
        #expect(model.cullingUndoCount == 0 && !model.isWritingCulling)

        model.showFolder(sandbox.folder(""))
        try await sandbox.eventually { model.items.count == 2 }
        model.select(b)
        #expect(model.canPerform(.rating3) && model.perform(.rating3), "listed, it's culled")
        try await sandbox.eventually { !model.isWritingCulling }
        await sandbox.service?.settled()
        #expect(SidecarStore().load(for: b)?.metadata?.rating == 3)
    }

    @Test func `a change made in Develop with a collection shown reaches the photo's sidecar`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG", "Other/C.JPG"])
        let model = try await sandbox.open()
        let sources = model.librarySources
        let (a, c) = (sandbox.photo("Shoot/A.JPG"), sandbox.photo("Other/C.JPG"))
        try await sandbox.counts { $0.isCounted }
        #expect(sources.create(.collection, named: "Picks"))
        let picks = try #require(CollectionPath("Picks"))
        try await sandbox.counts { $0.collections[picks] != nil }
        #expect(sources.show(.allPhotographs))
        try await sandbox.eventually { !sources.isListing && model.items.count == 3 }
        model.select(a)
        model.click(c, toggling: true)
        #expect(sources.add(to: picks))
        await model.libraryPanels.written()
        try await sandbox.counts { $0.count(of: .collection(picks)) == 2 }
        #expect(sources.show(.collection(picks)))
        try await sandbox.eventually { !sources.isListing && Set(model.items.map(\.url)) == [a, c] }

        model.select(c)
        model.showModule(.develop)
        try await sandbox.eventually { model.info?.url == c && model.opening == nil }
        try #require(model.info?.url == c, "C open in Develop")
        #expect(model.perform(.rating4))
        #expect(model.perform(.flagPick))
        await model.saves.flush()
        #expect(Self.sidecars([c])["C.JPG"] == Self.values(rating: 4, flag: .pick))
        #expect(try await Self.rebuilt([c], sandbox)["C.JPG"] == Self.values(rating: 4, flag: .pick))
    }
}
