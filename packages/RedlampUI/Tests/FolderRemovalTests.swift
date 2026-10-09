import AppKit
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
        try await SourcesSandbox.eventually { await service.canShow(folder, includingSubfolders: true) }
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

    /// The sandbox's photo and Trip in the library, Folders in a window, and Remove from Folders in Trip's row's menu,
    /// as a click on it finds it.
    static func removeFromFolders(in sandbox: SourcesSandbox) async throws -> (EditorModel, NSWindow, NSMenuItem) {
        try sandbox.photos(["A.jpg"])
        let trip = try Self.trip(in: sandbox)
        let model = try await sandbox.open()
        try await Self.add(trip, to: model.library, service: #require(sandbox.service))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 280, height: 900), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentView = SidebarListViews.make(model: model)
        let identifier = "folders." + trip.standardizedFileURL.path
        var row: NSView?
        try await sandbox.eventually {
            window.contentView?.layoutSubtreeIfNeeded()
            row = Self.view(identifier, in: window.contentView)
            return row != nil
        }
        let cell = try #require(row as? SidebarCellView, "Trip's row on screen")
        let item = try #require(cell.contextMenu()?.items.first { $0.title == "Remove from Folders" })
        return (model, window, item)
    }

    @Test func `Remove from Folders, chosen in a root's menu as a click does, takes the folder out`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let (model, window, item) = try await Self.removeFromFolders(in: sandbox)
        defer { window.contentView = nil }
        try NSApplication.shared.sendAction(#require(item.action), to: item.target, from: item)
        #expect(model.library.roots.map(\.url) == [sandbox.root])
        try await sandbox.counts { $0.count(of: .allPhotographs) == 1 }
        #expect(model.librarySources.count(of: .allPhotographs) == 1)
    }

    @Test(.measuresSpeed)
    func `Remove from Folders, chosen in a root's menu as a click does, holds the main thread for no time`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        let (_, window, item) = try await Self.removeFromFolders(in: sandbox)
        defer { window.contentView = nil }
        let started = ContinuousClock.now
        try NSApplication.shared.sendAction(#require(item.action), to: item.target, from: item)
        let took = ContinuousClock.now - started
        #expect(took < .milliseconds(100), "the action took \(took)")
    }

    /// The photos the Keyword List counts for Lisbon's keyword; nil until it's read.
    static func lisbonKeyword(_ model: EditorModel) -> Int? {
        model.libraryPanels.keywords.map { $0.list.keywords[KeywordPath("Places/Lisbon")!]?.photos ?? 0 }
    }

    @Test func `a folder taken out of Folders other than from its menu leaves the panels' counts too`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["A.jpg"])
        let trip = try Self.trip(in: sandbox)
        try SidecarStore().save(
            Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(customLabel: "Hero")),
            for: trip.appending(path: "Day 2/C.jpg"),
        )
        let model = try await sandbox.open()
        let service = try #require(sandbox.service)
        try await Self.add(trip, to: model.library, service: service)
        let sources = model.librarySources
        try await sandbox.counts { $0.count(of: .collection(Self.lisbon)) == 1 }
        model.libraryPanels.refreshKeywords()
        model.refreshCustomLabels()
        try await sandbox.eventually { Self.lisbonKeyword(model) == 1 && !model.customLabelCounts.isEmpty }
        try #require(Self.lisbonKeyword(model) == 1 && model.customLabelCounts.map(\.name) == ["Hero"])

        // Taken out through the library itself, as Locate… and the scenarios take a root out.
        try model.library.remove(#require(model.library.root(containing: trip)))
        try await sandbox.eventually {
            sources.count(of: .collection(Self.lisbon)) ?? 0 == 0 && Self.lisbonKeyword(model) == 0
                && model.customLabelCounts.isEmpty
        }
        #expect(sources.count(of: .collection(Self.lisbon)) ?? 0 == 0, "the Library panel counted again")
        #expect(sources.count(of: .allPhotographs) == 1)
        #expect(Self.lisbonKeyword(model) == 0, "the Keyword List was read again")
        #expect(model.customLabelCounts.isEmpty, "and the custom labels")
    }

    @Test func `the folders the library takes out as it opens leave the panels' counts`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["A.jpg"])
        let trip = try Self.trip(in: sandbox)
        let first = try await sandbox.open()
        try await Self.add(trip, to: first.library, service: #require(sandbox.service))
        sandbox.service?.close()

        // Folders kept without Trip, as the library was off when it lost it.
        let suite = "folder-removal-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        FolderLibrary(defaults: defaults).add([sandbox.root])
        let library = FolderLibrary(defaults: defaults)
        let model = EditorModel(engine: StubEngine(), library: library)
        let paths = LibraryPaths(root: sandbox.base.appending(path: "Library", directoryHint: .isDirectory))
        let service = LibraryService(paths: paths, sidecars: library.sidecars) { url, size in
            StoreThumbnailMaker.imageIO(url, nil, size)
        }
        library.attach(service)
        defer { service.close() }
        try await sandbox.eventually {
            model.librarySources.isCounted && model.libraryPanels.keywords != nil
        }
        #expect(model.librarySources.count(of: .allPhotographs) == 1, "the Library panel counted without Trip")
        #expect(model.librarySources.count(of: .collection(Self.lisbon)) ?? 0 == 0)
        #expect(Self.lisbonKeyword(model) == 0, "so did the Keyword List")
    }

    /// The view carrying `identifier` in `view`'s tree.
    static func view(_ identifier: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap { Self.view(identifier, in: $0) }.first
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
        try await sandbox.eventually { service.isReady }
        let core = try #require(service.core)
        let kept = [LibraryService.path(sandbox.root)]
        var roots: [String] = []
        try await SourcesSandbox.eventually {
            roots = try await core.index.read { try $0.roots().map(\.path) }
            return roots == kept
        }
        #expect(roots == kept, "Trip's rows are swept")
        #expect(try await Self.ids("", service).count == 1, "only the sandbox's own photo")
    }

    @Test func `a folder Folders lost while the library was off leaves it as it opens, unless Folders is new`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["A.jpg"])
        let trip = try Self.trip(in: sandbox)
        let first = try await sandbox.open()
        try await Self.add(trip, to: first.library, service: #require(sandbox.service))
        sandbox.service?.close()
        let suite = "folder-removal-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let paths = LibraryPaths(root: sandbox.base.appending(path: "Library", directoryHint: .isDirectory))
        func launch(_ library: FolderLibrary) async throws -> LibraryService {
            let service = LibraryService(paths: paths, sidecars: library.sidecars) { url, size in
                StoreThumbnailMaker.imageIO(url, nil, size)
            }
            library.attach(service)
            try await sandbox.eventually { service.isReady }
            try #require(service.isReady)
            return service
        }
        let kept = Set([sandbox.root, trip].map(LibraryService.path))

        // A working set no launch kept, holding Folders' own root alone: nothing leaves.
        let fresh = FolderLibrary()
        fresh.add([sandbox.root])
        let unsaved = try await launch(fresh)
        try await Task.sleep(for: .milliseconds(500))
        let core = try #require(unsaved.core)
        await core.roots.swept()
        #expect(try await Set(core.index.read { try $0.roots().map(\.path) }) == kept)
        unsaved.close()

        // Folders kept without Trip, as the library was off when it lost it: Trip leaves as the library opens.
        FolderLibrary(defaults: defaults).add([sandbox.root])
        let saved = FolderLibrary(defaults: defaults)
        #expect(saved.roots.map(\.url) == [sandbox.root])
        let service = try await launch(saved)
        defer { service.close() }
        let opened = try #require(service.core)
        var roots: Set<String> = []
        try await SourcesSandbox.eventually {
            roots = try await Set(opened.index.read { try $0.roots().map(\.path) })
            return roots == [LibraryService.path(sandbox.root)]
        }
        #expect(roots == [LibraryService.path(sandbox.root)])
        #expect(try await Self.ids("", service).count == 1)
    }

    @Test func `a removal a quit cut short shows none of the folder at the next launch, which finishes it`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["A.jpg"])
        let trip = try Self.trip(in: sandbox)
        let first = try await sandbox.open()
        try await Self.add(trip, to: first.library, service: #require(sandbox.service))
        sandbox.service?.close()

        // Marked, and one photo swept, when the app quit.
        let paths = LibraryPaths(root: sandbox.base.appending(path: "Library", directoryHint: .isDirectory))
        let quitting = try await LibraryIndex.open(at: paths.index)
        let path = LibraryService.path(trip)
        _ = try await quitting.write { try $0.markRemoved(path, keeping: []) }
        _ = try await quitting.write { try $0.sweepRemoved(limit: 1) }
        await quitting.close()

        let library = FolderLibrary()
        library.add([sandbox.root])
        let service = LibraryService(paths: paths, sidecars: library.sidecars) { url, size in
            StoreThumbnailMaker.imageIO(url, nil, size)
        }
        library.attach(service)
        defer { service.close() }
        try await sandbox.eventually { service.isReady }
        #expect(try await Self.ids("", service).count == 1, "none of Trip's photos as the library opens")
        let core = try #require(service.core)
        var swept = false
        try await SourcesSandbox.eventually {
            swept = try await core.index.read { try $0.removedRoots().isEmpty }
            return swept
        }
        #expect(swept, "the sweep finished")
        #expect(try await core.index.read { try $0.root(path: path) } == nil)
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
