import AppKit
import Foundation
import RedlampDocument
import RedlampEngineAPI
import Synchronization
import Testing
@testable import RedlampLibrary
@_spi(Harness) @testable import RedlampUI

/// The import window (LIB-27), driven as the window drives it: its sources browsed and counted, and the
/// photos chosen, rated, flagged and labelled from the grid's keys.
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
}
