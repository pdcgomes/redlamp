import AppKit
import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// The left panel's Library section (LIB-23): All Photographs, Previous Import, Marked, Rejected and Library
/// Health's checks (LIB-40), each offered with its count once it holds photos, and each shown in the grid and
/// the filmstrip as a source; counts that change shown in place.
@MainActor
@Suite(.serialized)
struct LibrarySourcesTests {
    @Test func `All Photographs is offered once the library has photos, and Marked and Rejected once they hold some`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG", "Shoot/C.JPG", "Shoot/D.JPG"])
        let model = try await sandbox.open()
        let sources = model.librarySources
        try await sandbox.counts { $0.count(of: .allPhotographs) == 4 }
        #expect(sources.libraryEntries == [.allPhotographs] && sources.count(of: .allPhotographs) == 4)
        #expect(sources.healthEntries.isEmpty && sources.count(of: .marked) == nil)

        model.showFolder(sandbox.folder("Shoot"))
        try await sandbox.eventually { model.items.count == 4 }
        try await sandbox.cull(.toggleMark, [sandbox.photo("Shoot/A.JPG"), sandbox.photo("Shoot/B.JPG")])
        try await sandbox.cull(.flagReject, [sandbox.photo("Shoot/C.JPG")])
        try await sandbox.counts { $0.count(of: .marked) == 2 && $0.count(of: .rejected) == 1 }
        #expect(sources.libraryEntries == [.allPhotographs, .marked, .rejected])
        #expect(sources.count(of: .marked) == 2 && sources.count(of: .rejected) == 1)
        #expect(sources.count(of: .allPhotographs) == 4)

        try await sandbox.cull(.flagReject, [sandbox.photo("Shoot/C.JPG")])
        try await sandbox.counts { $0.count(of: .rejected) == nil }
        #expect(sources.libraryEntries == [.allPhotographs, .marked], "Rejected goes once it holds none")
    }

    @Test func `an entry chosen shows its photos in the grid and the filmstrip until a folder is opened`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG", "Other/C.JPG"])
        let model = try await sandbox.open()
        let library = model.library
        let sources = model.librarySources
        model.showFolder(sandbox.folder("Shoot"))
        try await sandbox.eventually { model.items.count == 2 }
        try await sandbox.cull(.toggleMark, [sandbox.photo("Shoot/A.JPG")])
        model.showFolder(sandbox.folder("Other"))
        try await sandbox.eventually { model.items.count == 1 }
        try await sandbox.cull(.toggleMark, [sandbox.photo("Other/C.JPG")])
        try await sandbox.counts { $0.count(of: .marked) == 2 }

        model.showModule(.develop)
        #expect(model.perform(.showMarked))
        try await sandbox.eventually { !sources.isListing && model.items.count == 2 }
        #expect(sources.shown == .marked && model.module == .library && model.folder == nil)
        #expect(Set(model.items.map(\.url)) == [sandbox.photo("Shoot/A.JPG"), sandbox.photo("Other/C.JPG")])
        let marks = model.items.map(\.metadata.mark)
        #expect(!marks.contains(false), "each with its badges")
        #expect(model.selection == model.items.first?.url)
        for item in model.items {
            let (thumbnails, key) = try #require(library.storeThumbnail(for: item))
            #expect(thumbnails.store.contains(key, tier: .grid), "\(item.name)'s thumbnail is in the store")
        }

        // Unmarked, a photo leaves Marked, the other staying selected.
        let c = sandbox.photo("Other/C.JPG")
        model.select(c)
        #expect(model.perform(.toggleMark))
        try await sandbox.eventually { model.items.map(\.url) == [sandbox.photo("Shoot/A.JPG")] }
        #expect(model.items.map(\.url) == [sandbox.photo("Shoot/A.JPG")])

        #expect(sources.show(.allPhotographs))
        try await sandbox.eventually { !sources.isListing && model.items.count == 3 }
        #expect(sources.shown == .allPhotographs && model.items.count == 3)

        model.showFolder(sandbox.folder("Shoot"))
        try await sandbox.eventually { model.folder != nil && model.items.count == 2 }
        #expect(sources.shown == nil && model.items.count == 2, "a folder opened ends the source")
    }

    @Test func `an entry's photos and a folder's shown from the library have the index's IDs, and photos listed from the disk IDs above them`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG", "Other/C.JPG"])
        let model = try await sandbox.open()
        let library = model.library
        let sources = model.librarySources
        let core = try #require(sandbox.service?.core)
        #expect(sources.show(.allPhotographs))
        try await sandbox.eventually { !sources.isListing && model.items.count == 3 }
        let urls = model.items.map(\.url)
        let indexed = await LibraryService.indexIDs(of: urls, in: core.index)
        #expect(indexed.count == 3)
        #expect(Array(library.photoIDs) == urls.compactMap { indexed[$0] })
        for (place, url) in urls.enumerated() {
            #expect(library.index(of: url) == place && library.photoID(of: url) == indexed[url])
            #expect(library.url(ofPhoto: library.photoIDs[place]) == url)
            #expect(library.contentKey(of: url) != nil, "\(url.lastPathComponent)'s content key, by its ID")
        }
        #expect(library.index(of: sandbox.photo("Shoot/Z.JPG")) == nil)

        model.showFolder(sandbox.folder("Shoot"))
        try await sandbox.eventually { model.folder != nil && library.isShownFromLibrary && model.items.count == 2 }
        #expect(library.showsIndexIDs, "a folder shown from the library has the index's IDs too")
        #expect(Array(library.photoIDs) == model.items.map(\.url).compactMap { indexed[$0] })
        #expect(library.photoID(of: sandbox.photo("Shoot/A.JPG")) == library.photoIDs.first)

        let elsewhere = sandbox.base.appending(path: "Elsewhere", directoryHint: .isDirectory)
        try sandbox.photos(["D.JPG"], under: elsewhere, from: 9)
        model.showFolder(elsewhere)
        try await sandbox.eventually { model.folder == elsewhere && !library.isListing && model.items.count == 1 }
        let highest = try #require(indexed.values.max())
        #expect(!library.showsIndexIDs, "a folder the library doesn't have is listed from the disk")
        #expect(library.photoIDs.allSatisfy { $0 >= highest + FolderLibrary.ownIDMargin }, "\(library.photoIDs)")
    }

    @Test func `a folder shown from the library keeps the index's IDs through a filter and for photos that come`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/Alpha.JPG", "Shoot/Bravo.JPG", "Shoot/Charlie.JPG"])
        let model = try await sandbox.open()
        let library = model.library
        let core = try #require(sandbox.service?.core)
        /// The index's IDs of the photos shown, in their order.
        func indexed() async -> [Int64] {
            let urls = model.items.map(\.url)
            let found = await LibraryService.indexIDs(of: urls, in: core.index)
            return urls.compactMap { found[$0] }
        }
        model.showFolder(sandbox.folder("Shoot"))
        try await sandbox.eventually { library.isShownFromLibrary && !library.isListing && model.items.count == 3 }
        #expect(library.showsIndexIDs)
        #expect(await Array(library.photoIDs) == indexed())

        let filters = try #require(model.libraryFilters)
        filters.setFilter(LibraryFilter(text: "", sections: [.text]))
        filters.setText("name:Bravo")
        try await sandbox.eventually { library.isFiltered && model.items.count == 1 }
        #expect(model.items.map(\.name) == ["Bravo.JPG"])
        #expect(await Array(library.photoIDs) == indexed(), "the filtered list's photo has its index ID")
        filters.setText("")
        try await sandbox.eventually { !library.isFiltered && model.items.count == 3 }
        #expect(await Array(library.photoIDs) == indexed())

        try sandbox.photos(["Shoot/Delta.JPG"], from: 7)
        try await sandbox.eventually(seconds: 30) { model.items.count == 4 }
        #expect(library.showsIndexIDs && model.items.count == 4)
        #expect(await Array(library.photoIDs) == indexed(), "a photo that came has its index ID")
    }

    @Test func `Library Health's checks are offered while they find something, each shown with its photos`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: sandbox.photo("Bad/Locked.JPG").path,
            )
            sandbox.remove()
        }
        try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG", "Bad/Misnamed.png", "Bad/Locked.JPG"])
        try FileManager.default.createDirectory(at: sandbox.folder("Copies"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sandbox.photo("Shoot/A.JPG"), to: sandbox.photo("Copies/A copy.JPG"))
        try Data().write(to: sandbox.photo("Bad/Empty.JPG"))
        // A file written in the last minute may still be being written, and isn't listed as damaged yet.
        let earlier = Date().addingTimeInterval(-600)
        for name in ["Misnamed.png", "Locked.JPG", "Empty.JPG"] {
            try FileManager.default.setAttributes(
                [.modificationDate: earlier],
                ofItemAtPath: sandbox.photo("Bad/" + name).path,
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: sandbox.photo("Bad/Locked.JPG").path,
        )
        let model = try await sandbox.open()
        let sources = model.librarySources
        let core = try #require(sandbox.service?.core)
        try await LibraryHealth(operations: core.files, engine: core.engine).confirmDuplicates()

        try await sandbox.counts { sources in
            sources.count(of: .health(.duplicates)) == 2 && sources.count(of: .health(.extensions)) == 1
                && sources.count(of: .unreadable) == 1
        }
        #expect(sources.healthEntries == [.health(.duplicates), .health(.damaged), .health(.extensions), .unreadable])
        #expect(sources.count(of: .health(.duplicates)) == 2)
        #expect(sources.count(of: .health(.damaged)) == 2, "the empty file, and the one that can't be read")
        #expect(sources.count(of: .health(.extensions)) == 1 && sources.count(of: .unreadable) == 1)
        #expect(sources.count(of: .health(.pairs)) == nil, "with pairs kept both, the check finds none")
        #expect(sources.count(of: .allPhotographs) == 5, "every photo but the one that can't be read")

        #expect(sources.show(.health(.extensions)))
        try await sandbox.eventually { !sources.isListing && model.items.count == 1 }
        #expect(model.items.map(\.url) == [sandbox.photo("Bad/Misnamed.png")])
        #expect(sources.show(.unreadable))
        try await sandbox.eventually { !sources.isListing && model.items.map(\.name) == ["Locked.JPG"] }
        #expect(model.items.map(\.name) == ["Locked.JPG"])
        #expect(sources.show(.health(.duplicates)))
        try await sandbox.eventually { !sources.isListing && model.items.count == 2 }
        #expect(Set(model.items.map(\.name)) == ["A.JPG", "A copy.JPG"])
    }

    @Test func `Previous Import shows the photos the last import copied, at their destination`() async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG"])
        let card = sandbox.base.appending(path: "Card", directoryHint: .isDirectory)
        try sandbox.photos(["IMG_0001.JPG", "IMG_0002.JPG"], under: card, from: 10)
        let model = try await sandbox.open()
        let sources = model.librarySources
        try await sandbox.counts { $0.count(of: .allPhotographs) == 1 }
        #expect(sources.count(of: .previousImport) == nil)

        let core = try #require(sandbox.service?.core)
        let library = ImportLibrary(
            paths: core.paths, index: core.index, store: core.store, indexer: core.indexer, live: core.live,
        )
        let session = try ImportSession(sources: [ImportSource.at(card)], library: library, makesPreviews: false)
        let destination = sandbox.folder("Imported")
        let plan = try await session.plan(ImportSettings(
            destination: destination,
            folders: NamingTemplate(parsing: ""),
        ))
        let outcome = try await session.importer().run(plan)
        #expect(outcome.state == .finished && outcome.verified == 2)

        try await sandbox.counts { $0.count(of: .previousImport) == 2 }
        #expect(sources.libraryEntries == [.allPhotographs, .previousImport])
        #expect(sources.count(of: .previousImport) == 2 && sources.count(of: .allPhotographs) == 3)
        #expect(model.perform(.showPreviousImport))
        try await sandbox.eventually { !sources.isListing && model.items.count == 2 }
        #expect(Set(model.items.map(\.url)) == [
            destination.appending(path: "IMG_0001.JPG", directoryHint: .notDirectory),
            destination.appending(path: "IMG_0002.JPG", directoryHint: .notDirectory),
        ])
    }

    @Test func `the Library panel's counts change in its rows in place, and its rows change as entries come and go`(
    ) async throws {
        let sandbox = SourcesSandbox()
        defer { sandbox.remove() }
        try sandbox.photos(["Shoot/A.JPG", "Shoot/B.JPG", "Shoot/C.JPG"])
        let model = try await sandbox.open()
        let sources = model.librarySources
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 260, height: 500), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        let list = LibraryOutlineView(model: model)
        window.contentView = list
        defer { window.contentView = nil }
        @MainActor func rows() -> [SourceRow] {
            (0 ..< list.numberOfRows).compactMap { index in
                guard case let .source(row) = (list.item(atRow: index) as? SidebarNode)?.kind else { return nil }
                return row
            }
        }
        try await sandbox.eventually { rows().map(\.source) == [.allPhotographs] }
        #expect(rows().first?.count == 3)

        model.showFolder(sandbox.folder("Shoot"))
        try await sandbox.eventually { model.items.count == 3 }
        try await sandbox.cull(.toggleMark, [sandbox.photo("Shoot/A.JPG")])
        try await sandbox.eventually(seconds: 20) { rows().map(\.source) == [.allPhotographs, .marked] }
        #expect(rows().map(\.count) == [3, 1], "Marked offered once it holds a photo")

        let made = sources.rows
        try await sandbox.cull(.toggleMark, [sandbox.photo("Shoot/A.JPG"), sandbox.photo("Shoot/B.JPG")])
        try await sandbox.eventually(seconds: 20) { rows().map(\.count) == [3, 2] }
        #expect(rows().map(\.count) == [3, 2] && sources.rows == made, "the count changed in place")
        let cell = list.view(atColumn: 0, row: 1, makeIfNecessary: false) as? SidebarCellView
        #expect(cell?.accessibilityLabel() == "Marked, 2 photos, target collection", "Marked the target, as none is")

        #expect(sources.show(.marked))
        try await sandbox.eventually { rows().last?.isShown == true }
        #expect(rows().map(\.isShown) == [false, true], "the source shown is the row highlighted")

        // A press on a row shows its source, as the list takes it.
        let first = try #require(list.view(atColumn: 0, row: 0, makeIfNecessary: false))
        let frame = first.convert(first.bounds, to: nil)
        let press = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: frame.midX, y: frame.midY), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1,
        ))
        list.mouseDown(with: press)
        try await sandbox.eventually { rows().map(\.isShown) == [true, false] }
        #expect(sources.shown == .allPhotographs && rows().map(\.isShown) == [true, false])
    }
}
