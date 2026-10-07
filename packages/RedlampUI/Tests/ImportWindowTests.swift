import AppKit
import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampLibrary
@_spi(Harness) @testable import RedlampUI

/// The import window (LIB-27), driven as the window drives it: its sources browsed and counted, the
/// photos chosen, rated, flagged and labelled from the grid's keys, and the templates' example and errors.
@MainActor
@Suite(.serialized)
struct ImportWindowTests {
    @Test func `a folder's photos are listed, those the library has counted apart and left out`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        try await fixture.index(fixture.folder("Shelf", count: 2))
        let card = try fixture.folder("Card", count: 5)
        let model = fixture.model()
        model.start()
        try await model.addFolder(card)
        await model.browsed()
        let source = try #require(model.sources.first)
        #expect(source.photos.count == 5 && source.imported == 2 && source.isBrowsed)
        #expect(model.detail(of: source) == "5 photos, 2 already in the library")
        #expect(model.chosen.photos == 3)
        #expect(model.summary.hasPrefix("3 photos chosen") && model.summary.contains("2 photos already in the library"))
        #expect(model.photos.map(\.primary.name) == (0 ..< 5).reversed().map(ImportWindowFixture.name), "newest first")
        #expect(model.photos.filter(model.isLeftOut).map(\.primary.name).sorted() == ["IMG_0000.JPG", "IMG_0001.JPG"])
        let leftOut = try #require(model.photos.first { model.isLeftOut($0) })
        model.choose([leftOut.id], true)
        #expect(model.chosen.photos == 3, "a photo the library has can't be chosen")

        // Several at once: each counted, and left out of the import with its box.
        try await model.addFolder(fixture.folder("Other", count: 2, from: 10))
        await model.browsed()
        #expect(model.sources.count == 2 && model.chosen.photos == 5)
        #expect(model.shown == model.sources[1].id && model.photos.count == 2)
        model.setIncluded(model.sources[1].id, false)
        #expect(model.chosen.photos == 3)
    }

    @Test func `Library's keys rate, flag, label and choose the photos selected in the grid`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.addFolder(fixture.folder("Card", count: 3))
        await model.browsed()
        let grid = ImportGridViewController(model: model, thumbnails: ImportThumbnails(store: fixture.store))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentView = grid.view
        model.onChange = { grid.modelChanged($0) }
        grid.modelChanged(.photos(ids: nil))
        grid.collectionView.layoutSubtreeIfNeeded()
        #expect(grid.collectionView.allowsMultipleSelection && grid.collectionView.isSelectable)
        grid.collectionView.selectionIndexPaths = [IndexPath(item: 0, section: 0), IndexPath(item: 2, section: 0)]
        let (first, second, third) = try (
            #require(model.photo(at: 0)?.id), #require(model.photo(at: 1)?.id), #require(model.photo(at: 2)?.id),
        )
        func press(_ key: String, _ flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0,
            )
            if let event {
                grid.collectionView.keyDown(with: event)
            }
        }
        func choices(_ id: String) -> ImportChoices? {
            model.photo(id: id)?.choices
        }
        press("3")
        #expect(choices(first)?.rating == 3 && choices(third)?.rating == 3 && choices(second)?.rating == 0)
        press("p")
        #expect(choices(first)?.flag == .pick && choices(third)?.flag == .pick)
        press("x")
        #expect(choices(first)?.flag == .reject)
        press("u")
        #expect(choices(first)?.flag == nil && choices(first)?.given.contains(.flag) == true)
        press("6")
        #expect(choices(first)?.label == .red && choices(third)?.label == .red)
        press("6")
        #expect(choices(first)?.label == nil, "the same label key again takes it off")
        press("9")
        #expect(choices(third)?.label == .blue)
        press(" ")
        #expect(choices(first)?.isChosen == false && choices(third)?.isChosen == false && choices(second)?
            .isChosen == true)
        #expect(model.chosen.photos == 1)
        press(" ")
        #expect(choices(first)?.isChosen == true)
        press("0")
        #expect(choices(first)?.rating == 0 && choices(first)?.given.contains(.rating) == true)
        window.makeFirstResponder(grid.collectionView)
        let selectAll = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0,
        ))
        #expect(grid.collectionView.performKeyEquivalent(with: selectAll))
        #expect(grid.selectedIDs == [first, second, third])
        // The grid's cell says what was given.
        let item = try #require(grid.collectionView.item(at: IndexPath(item: 2, section: 0)))
        #expect(item.view.accessibilityLabel() == model.photo(at: 2)?.primary.name)
        #expect(try ImportGridCell.badges(#require(model.photo(at: 2)), leftOut: false, copied: false) == "Blue")
    }

    @Test func `the templates' live example follows what's typed, and an error in them is said in words`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.addFolder(fixture.folder("Card", count: 2))
        await model.browsed()
        fixture.settle(model)
        func example() async -> String? {
            await model.exampled()
            return model.example
        }
        #expect(await example() == "2026/2026-10-05/IMG_0001.JPG", "the first photo chosen, newest first")
        model.setNames("Lisbon-{seq:3}")
        #expect(await example() == "2026/2026-10-05/Lisbon-001.JPG")
        model.setNames("{date:yyyyMMdd-HHmmss}-{name|lower}")
        #expect(await example() == "2026/2026-10-05/20261005-090001-img_0001.JPG")
        model.setNames("{camra}")
        #expect(model.namesError?.contains("camra isn't a token") == true)
        #expect(await example() == nil)
        model.setNames("{name")
        #expect(model.namesError == nil, "a token still being typed isn't an error")
        model.setNames("{name}")
        model.setFolders("{date:yyyy}/{oops}")
        #expect(model.folderError?.contains("oops isn't a token") == true)
        model.setFolders("")
        #expect(model.folderError == nil)
        #expect(await example() == "IMG_0001.JPG")
        model.setText("shoot", "Wedding")
        model.setFolders("{date:yyyy}/{date:yyyy-MM-dd}{text:shoot|before:\" \"}")
        #expect(model.textNames == ["shoot"])
        #expect(await example() == "2026/2026-10-05 Wedding/IMG_0001.JPG")
        let first = try #require(model.photo(at: 0))
        model.choose([first.id], false)
        #expect(await example() == "2026/2026-10-05 Wedding/IMG_0000.JPG", "the first photo chosen")
    }

    @Test func `the destination, backup, templates, raw only and keywords are kept from one import to the next`(
    ) async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let model = fixture.model()
        model.setDestination(fixture.destination)
        model.setBackup(fixture.backup)
        model.setFolders("{date:yyyy}")
        model.setNames("{date:yyyyMMdd}-{seq:3}")
        model.setRawOnly(true)
        model.setKeywords(["Family", "Places/Portugal/Lisbon"])
        model.setText("shoot", "Wedding")
        let kept = ImportPreferences(defaults: fixture.defaults).settings
        #expect(kept == model.settings)
        #expect(kept.destination.path == fixture.destination.path && kept.backup?.path == fixture.backup.path)
        #expect(kept.folders.description == "{date:yyyy}" && kept.names.description == "{date:yyyyMMdd}-{sequence:3}")
        #expect(kept.rawOnly && kept.metadata.keywords == ["Family", "Places/Portugal/Lisbon"])
        #expect(kept.texts == ["shoot": "Wedding"])
        let window = fixture.model()
        #expect(window.folderText == "{date:yyyy}" && window.namesText == "{date:yyyyMMdd}-{sequence:3}")
    }

    @Test func `keywords typed are completed from the library's`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let shelf = try fixture.folder("Shelf", count: 1)
        try SidecarStore(locator: .besidePhotos).save(
            Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(keywords: ["Places/Portugal/Lisbon"])),
            for: shelf.appending(path: ImportWindowFixture.name(0)),
        )
        try await fixture.index(shelf)
        let model = fixture.model()
        model.start()
        try await waitUntil("the library's keywords") { model.keywordCompletion != nil }
        #expect(model.keywords(completing: "lis").contains("Places/Portugal/Lisbon"))
    }
}
