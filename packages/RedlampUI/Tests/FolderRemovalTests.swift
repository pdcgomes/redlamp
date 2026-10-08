import Foundation
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// A folder removed from Folders (LIB-10): its photos leave All Photographs, the collections, Library Health, the
/// counts and searches, as Lightroom Classic's Remove takes them out of its catalog; nothing on disk changes, and
/// adding the folder again brings back what its sidecars hold. A root that can't be found stays, with its photos.
@MainActor
struct FolderRemovalTests {
    static let lisbon = CollectionPath("Trips/Lisbon")!

    /// Trip, beside the sandbox's own root: two photos and an empty file, the first with four stars, Lisbon's
    /// keyword and Lisbon's collection in its sidecar.
    static func trip(in sandbox: SourcesSandbox) throws -> URL {
        let trip = sandbox.base.appending(path: "Trip", directoryHint: .isDirectory)
        try sandbox.photos(["B.jpg", "Day 2/C.jpg"], under: trip, from: 10)
        let metadata = PhotoMetadata(rating: 4, keywords: ["Places/Lisbon"], collections: ["Trips/Lisbon"])
        try SidecarStore().save(Sidecar(recipe: EditRecipe(), metadata: metadata), for: trip.appending(path: "B.jpg"))
        let empty = trip.appending(path: "Empty.jpg")
        try Data().write(to: empty)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: empty.path,
        )
        return trip
    }

    /// Adds `folder` to Folders and returns once the library has indexed it.
    static func add(_ folder: URL, to library: FolderLibrary, service: LibraryService) async throws {
        library.add([folder])
        for _ in 0 ..< 2000 where await !service.canShow(folder, includingSubfolders: true) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await service.canShow(folder, includingSubfolders: true), "the library indexed \(folder.path)")
    }

    /// The photos `query` finds in the library.
    static func ids(_ query: String, _ service: LibraryService) async throws -> [Int64] {
        let engine = try #require(service.engine)
        return try await Array(engine.list(.query(LibraryQuery(parsing: query))).ids)
    }

    @Test func `a folder removed from Folders leaves every library view and count, and comes back from its sidecars`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["A.jpg"])
        let trip = try Self.trip(in: sandbox)
        let model = try await sandbox.open()
        let service = try #require(sandbox.service)
        try await Self.add(trip, to: model.library, service: service)
        let sources = model.librarySources
        try await sandbox.counts { counts in
            counts.count(of: .allPhotographs) == 4 && counts.count(of: .collection(Self.lisbon)) == 1
                && counts.count(of: .health(.damaged)) == 1
        }
        try #require(sources.count(of: .allPhotographs) == 4)
        #expect(sources.show(.allPhotographs))
        try await sandbox.eventually { !sources.isListing && model.items.count == 4 }

        let root = try #require(model.library.root(containing: trip))
        FolderActions.remove(root, model: model)
        #expect(model.library.roots.map(\.url) == [sandbox.root])
        try await sandbox.eventually { model.items.map(\.name) == ["A.jpg"] }
        #expect(model.items.map(\.name) == ["A.jpg"], "All Photographs, shown, leaves Trip's photos out")
        try await sandbox.counts { counts in
            counts.count(of: .allPhotographs) == 1 && counts.count(of: .collection(Self.lisbon)) ?? 0 == 0
                && counts.count(of: .health(.damaged)) == nil
        }
        #expect(sources.count(of: .allPhotographs) == 1)
        #expect(sources.count(of: .collection(Self.lisbon)) ?? 0 == 0)
        #expect(sources.count(of: .health(.damaged)) == nil, "Library Health has nothing of it")
        #expect(try await Self.ids("kw:Lisbon", service).isEmpty)
        #expect(try await Self.ids("rating>=4", service).isEmpty)
        let keywords = try #require(await service.panelKeywords())
        #expect(try keywords.list.keywords[#require(KeywordPath("Places/Lisbon"))]?.photos ?? 0 == 0)
        #expect(FileManager.default.fileExists(atPath: trip.appending(path: "B.jpg.redlamp").path), "nothing on disk")
        #expect(!model.canPerform(.undo), "Folders' changes aren't on Undo")

        // Added again: what its sidecars hold comes back.
        try await Self.add(trip, to: model.library, service: service)
        try await sandbox.counts { counts in
            counts.count(of: .allPhotographs) == 4 && counts.count(of: .collection(Self.lisbon)) == 1
        }
        #expect(sources.count(of: .collection(Self.lisbon)) == 1)
        #expect(try await Self.ids("rating>=4", service).count == 1)
        #expect(try await Self.ids("kw:Lisbon", service).count == 1)
        try await sandbox.eventually { model.items.count == 4 }
        #expect(model.items.count == 4, "All Photographs, shown, has them again")
    }

    @Test func `a folder removed before the library opens is taken out as it opens`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["A.jpg"])
        let trip = try Self.trip(in: sandbox)
        let first = try await sandbox.open()
        try await Self.add(trip, to: first.library, service: #require(sandbox.service))
        try await sandbox.counts { $0.count(of: .allPhotographs) == 4 }
        sandbox.service?.close()

        // The next launch: Folders loses Trip while the library is still opening.
        let library = FolderLibrary()
        library.add([sandbox.root, trip])
        let paths = LibraryPaths(root: sandbox.base.appending(path: "Library", directoryHint: .isDirectory))
        let service = LibraryService(paths: paths, sidecars: library.sidecars) { url, size in
            StoreThumbnailMaker.imageIO(url, nil, size)
        }
        library.attach(service)
        defer { service.close() }
        try #require(service.state == .opening)
        try library.remove(#require(library.root(containing: trip)))
        for _ in 0 ..< 2000 where !service.isReady {
            try await Task.sleep(for: .milliseconds(10))
        }
        let core = try #require(service.core)
        let kept = [LibraryService.path(sandbox.root)]
        var roots: [String] = []
        for _ in 0 ..< 1000 {
            roots = try await core.index.read { try $0.roots().map(\.path) }
            if roots == kept {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(roots == kept, "Trip's rows are swept")
        #expect(try await Self.ids("", service).count == 1, "only the sandbox's own photo")
    }

    @Test func `a root that can't be found stays in Folders and in the library`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["A.jpg"])
        let trip = try Self.trip(in: sandbox)
        let model = try await sandbox.open()
        let service = try #require(sandbox.service)
        try await Self.add(trip, to: model.library, service: service)
        let root = try #require(model.library.root(containing: trip))

        try FileManager.default.removeItem(at: trip)
        model.library.volumesChanged()
        try await sandbox.eventually { model.library.missing.contains(root.id) }
        #expect(model.library.missing.contains(root.id))
        #expect(model.library.roots.contains { $0.id == root.id })
        let core = try #require(service.core)
        await core.roots.swept()
        #expect(try await core.index.read { try $0.removedRoots() }.isEmpty)
        #expect(try await core.index.read { try $0.root(path: LibraryService.path(trip)) } != nil)
    }
}
