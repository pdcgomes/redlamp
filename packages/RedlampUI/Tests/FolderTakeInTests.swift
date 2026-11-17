import Foundation
import RedlampDocument
import RedlampEngineAPI
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// A folder added to Folders takes in the folders of Folders inside it (#555), as an import showing its photos adds
/// the folder holding them: they leave Folders, the library keeps their photos as the new folder's, with their
/// ratings, keywords and collections, and the folder open stays open. A working set kept with folders inside another
/// takes them in as it's found at launch.
@MainActor
struct FolderTakeInTests {
    /// Shoots, beside the sandbox's own root: Trip, its first photo with four stars, Lisbon's keyword and Lisbon's
    /// collection in its sidecar, and Other, which no folder of Folders has.
    static func shoots(in sandbox: SourcesSandbox) throws -> (shoots: URL, trip: URL) {
        let shoots = sandbox.base.appending(path: "Shoots", directoryHint: .isDirectory)
        let trip = shoots.appending(path: "Trip", directoryHint: .isDirectory)
        try sandbox.photos(["B.jpg", "Day 2/C.jpg"], under: trip, from: 10)
        try sandbox.photos(["D.jpg"], under: shoots.appending(path: "Other", directoryHint: .isDirectory), from: 20)
        let metadata = PhotoMetadata(rating: 4, keywords: ["Places/Lisbon"], collections: ["Trips/Lisbon"])
        try SidecarStore().save(Sidecar(recipe: EditRecipe(), metadata: metadata), for: trip.appending(path: "B.jpg"))
        return (shoots, trip)
    }

    /// The paths of the roots the index has.
    static func indexRoots(_ service: LibraryService) async throws -> Set<String> {
        let core = try #require(service.core)
        return try await Set(core.index.read { try $0.roots().map(\.path) })
    }

    @Test func `a folder added takes in the folders inside it, their photos kept as the library holds them`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["A.jpg"])
        let (shoots, trip) = try Self.shoots(in: sandbox)
        let model = try await sandbox.open()
        let service = try #require(sandbox.service)
        try await FolderRemovalTests.add(trip, to: model.library, service: service)
        model.showFolder(trip)
        let open = trip.standardizedFileURL.path
        try await sandbox.eventually { model.folder?.path == open && model.items.count == 2 }
        try await sandbox.counts { counts in
            counts.count(of: .allPhotographs) == 3 && counts.count(of: .collection(FolderRemovalTests.lisbon)) == 1
        }
        let rated = try await FolderRemovalTests.ids("rating>=4", service)
        try #require(rated.count == 1)

        model.library.add([shoots])
        #expect(model.library.roots.map(\.url) == [sandbox.root, shoots])
        #expect(model.folder?.path == open && model.items.count == 2, "Trip stays open")

        // The library indexes Shoots, Other with it, and keeps Trip's photos as Shoots'.
        let kept = Set([sandbox.root, shoots].map(LibraryService.path))
        var roots: Set<String> = []
        try await SourcesSandbox.eventually {
            roots = try await Self.indexRoots(service)
            let shown = await service.canShow(shoots, includingSubfolders: true)
            return roots == kept && shown
        }
        #expect(roots == kept, "Trip is a folder of Shoots in the index, not a root of its own")
        try await sandbox.counts { $0.count(of: .allPhotographs) == 4 }
        #expect(model.librarySources.count(of: .allPhotographs) == 4, "every photo once, Other's with them")
        #expect(model.librarySources.count(of: .collection(FolderRemovalTests.lisbon)) == 1)
        #expect(try await FolderRemovalTests.ids("rating>=4", service) == rated, "the same photo, with its stars")
        #expect(try await FolderRemovalTests.ids("kw:Lisbon", service) == rated)
        #expect(model.folder?.path == open && model.items.count == 2)
        #expect(FileManager.default.fileExists(atPath: trip.appending(path: "B.jpg.redlamp").path), "nothing on disk")
    }

    @Test func `a working set a launch kept with a folder inside another has the library take it in`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["A.jpg"])
        let (shoots, trip) = try Self.shoots(in: sandbox)
        // As before #555: Folders follows Trip and then Shoots, and the index has both as roots.
        let first = try await sandbox.open()
        let service = try #require(sandbox.service)
        try await FolderRemovalTests.add(trip, to: first.library, service: service)
        service.follow([sandbox.root, trip, shoots])
        try await SourcesSandbox.eventually { await service.canShow(shoots, includingSubfolders: true) }
        try #require(try await Self.indexRoots(service) == Set([sandbox.root, trip, shoots].map(LibraryService.path)))
        // What the index changed reaches the query engine a moment after.
        var rated: [Int64] = []
        try await SourcesSandbox.eventually {
            await service.settled()
            rated = try await FolderRemovalTests.ids("rating>=4", service)
            return rated.count == 1
        }
        try #require(rated.count == 1, "the rated photo found once: \(rated)")
        service.close()

        let suite = "folder-take-in-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let saved = [sandbox.root, trip, shoots].map { WorkingFolder.make(for: $0) }
        try defaults.set(JSONEncoder().encode(saved), forKey: "folders.roots")
        defaults.set(trip.standardizedFileURL.path, forKey: "folders.open")

        // The next launch.
        let library = FolderLibrary(defaults: defaults)
        let paths = LibraryPaths(root: sandbox.base.appending(path: "Library", directoryHint: .isDirectory))
        let relaunched = LibraryService(paths: paths, sidecars: library.sidecars) { url, size in
            StoreThumbnailMaker.imageIO(url, nil, size)
        }
        library.attach(relaunched)
        sandbox.closes(relaunched)
        let model = EditorModel(engine: StubEngine(), library: library)
        model.restoreLibrary()
        try await SourcesSandbox.eventually { library.roots.count == 2 && model.folder != nil }
        #expect(library.roots.map(\.id) == [saved[0].id, saved[2].id])
        #expect(model.folder?.path == trip.standardizedFileURL.path, "Trip reopens, in Shoots")
        #expect(FolderLibrary(defaults: defaults).roots.map(\.id) == [saved[0].id, saved[2].id])

        let kept = Set([sandbox.root, shoots].map(LibraryService.path))
        var roots: Set<String> = []
        try await SourcesSandbox.eventually {
            guard relaunched.isReady else { return false }
            roots = try await Self.indexRoots(relaunched)
            return roots == kept
        }
        #expect(roots == kept, "the index takes Trip in")
        await relaunched.settled()
        #expect(try await FolderRemovalTests.ids("", relaunched).count == 4)
        #expect(try await FolderRemovalTests.ids("rating>=4", relaunched) == rated)
        #expect(try await FolderRemovalTests.ids("kw:Lisbon", relaunched) == rated)
    }

    @Test func `a folder a quit kept the library from taking in is taken in at the next launch`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["A.jpg"])
        let (shoots, trip) = try Self.shoots(in: sandbox)
        let first = try await sandbox.open()
        let service = try #require(sandbox.service)
        try await FolderRemovalTests.add(trip, to: first.library, service: service)
        service.follow([sandbox.root, trip, shoots])
        try await SourcesSandbox.eventually { await service.canShow(shoots, includingSubfolders: true) }
        service.close()
        let suite = "folder-take-in-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let paths = LibraryPaths(root: sandbox.base.appending(path: "Library", directoryHint: .isDirectory))
        func libraryService(for library: FolderLibrary) -> LibraryService {
            LibraryService(paths: paths, sidecars: library.sidecars, defaults: defaults) { url, size in
                StoreThumbnailMaker.imageIO(url, nil, size)
            }
        }

        // Folders took Trip into Shoots, and the app quit before the library took it in.
        let quitting = FolderLibrary()
        libraryService(for: quitting).takeIn([trip])
        #expect(defaults.stringArray(forKey: LibraryService.takingInKey) == [LibraryService.path(trip)])

        let library = FolderLibrary()
        library.add([sandbox.root, shoots])
        let relaunched = libraryService(for: library)
        library.attach(relaunched)
        sandbox.closes(relaunched)
        let kept = Set([sandbox.root, shoots].map(LibraryService.path))
        var roots: Set<String> = []
        try await SourcesSandbox.eventually {
            guard relaunched.isReady else { return false }
            roots = try await Self.indexRoots(relaunched)
            return roots == kept
        }
        #expect(roots == kept, "the index takes Trip in")
        try await SourcesSandbox.eventually { defaults.stringArray(forKey: LibraryService.takingInKey) == nil }
        #expect(defaults.stringArray(forKey: LibraryService.takingInKey) == nil, "and forgets it")
        #expect(try await FolderRemovalTests.ids("", relaunched).count == 4)
    }
}
