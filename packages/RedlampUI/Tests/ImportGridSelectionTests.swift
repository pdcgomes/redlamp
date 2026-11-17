import AppKit
import Foundation
import Testing
@testable import RedlampLibrary
@_spi(Harness) @testable import RedlampUI

/// The import window's grid selects as Library's does (#547): a click a photo, Shift-click every photo from the
/// one last clicked through another, across groups, Command-click one more or one fewer, a header's click its
/// group's photos, and the arrow keys move the selection, Shift extending it; what Shift extends from stays as the
/// grid is reloaded. The presses go to the view under them, as the window sends the mouse's.
@MainActor
@Suite(.serialized)
struct ImportGridSelectionTests {
    /// A grid on a card of photos 7202 to 7200 and 3 to 0, in two moments, three cells a row.
    private func makeGrid(_ fixture: ImportWindowFixture) async throws -> (ImportGridViewController, NSWindow) {
        let model = fixture.model()
        let root = try fixture.card("EOS_DIGITAL", count: 4)
        _ = try fixture.card("EOS_DIGITAL", count: 3, from: 7200)
        try model.add(fixture.cardSource(root))
        await model.browsed()
        await model.regrouped()
        let grid = ImportGridViewController(model: model, thumbnails: ImportThumbnails(store: fixture.store))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered,
            defer: false,
        )
        window.contentView = grid.view
        model.onChange = { grid.modelChanged($0) }
        grid.modelChanged(.photos(ids: nil))
        grid.view.layoutSubtreeIfNeeded()
        #expect(grid.collectionView.numberOfSections == 2 && grid.columns == 3)
        return (grid, window)
    }

    /// A click at `point` in the collection view, to the view the window finds under it.
    private func press(
        _ grid: ImportGridViewController, at point: NSPoint, _ flags: NSEvent.ModifierFlags = [],
    ) throws {
        let collection = grid.collectionView
        let window = try #require(collection.window)
        let location = collection.convert(point, to: nil)
        let view = try #require(window.contentView?.superview?.hitTest(location))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0,
            ))
            if type == .leftMouseDown {
                view.mouseDown(with: event)
            } else {
                view.mouseUp(with: event)
            }
        }
    }

    private func press(_ grid: ImportGridViewController, photo place: Int, _ flags: NSEvent.ModifierFlags = []) throws {
        let collection = grid.collectionView
        collection.layoutSubtreeIfNeeded()
        let path = try #require(grid.path(of: place))
        let frame = try #require(collection.layoutAttributesForItem(at: path)?.frame)
        try press(grid, at: NSPoint(x: frame.midX, y: frame.midY), flags)
    }

    private func press(_ grid: ImportGridViewController, group: Int, _ flags: NSEvent.ModifierFlags = []) throws {
        let collection = grid.collectionView
        collection.layoutSubtreeIfNeeded()
        let header = try #require(collection.supplementaryView(
            forElementKind: NSCollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: group),
        ))
        try press(grid, at: NSPoint(x: header.frame.minX + 20, y: header.frame.midY), flags)
    }

    private enum Arrow: UInt16 {
        case left = 123, right = 124, down = 125, up = 126

        var character: Int {
            switch self {
            case .left: NSLeftArrowFunctionKey
            case .right: NSRightArrowFunctionKey
            case .down: NSDownArrowFunctionKey
            case .up: NSUpArrowFunctionKey
            }
        }
    }

    private func press(_ grid: ImportGridViewController, _ arrow: Arrow, shift: Bool = false, times: Int = 1) throws {
        let characters = try String(#require(UnicodeScalar(arrow.character)))
        let flags: NSEvent.ModifierFlags = shift ? [.shift, .numericPad, .function] : [.numericPad, .function]
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: grid.collectionView.window?.windowNumber ?? 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: arrow.rawValue,
        ))
        for _ in 0 ..< times {
            grid.collectionView.keyDown(with: event)
        }
    }

    @Test func `a click selects a photo, Shift-click every photo from it through another across moments, and Command-click one more or one fewer`(
    ) async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let (grid, window) = try await makeGrid(fixture)
        try press(grid, photo: 1)
        #expect(grid.selectedPlaces == [1])
        #expect(window.firstResponder === grid.collectionView, "the grid has the keys")
        try press(grid, photo: 5, .shift)
        #expect(grid.selectedPlaces == Set(1 ... 5), "across the moments' headers")
        try press(grid, photo: 0, .shift)
        #expect(grid.selectedPlaces == [0, 1], "from the photo last clicked without Shift")
        try press(grid, photo: 4, .command)
        #expect(grid.selectedPlaces == [0, 1, 4])
        try press(grid, photo: 1, .command)
        #expect(grid.selectedPlaces == [0, 4])
        try press(grid, photo: 6, .shift)
        #expect(grid.selectedPlaces == Set(4 ... 6), "from the photo Command-click added")
        try press(grid, photo: 2, [.shift, .command])
        #expect(grid.selectedPlaces == Set(2 ... 6), "Shift-Command-click adds the range")
        try press(grid, photo: 3)
        #expect(grid.selectedPlaces == [3])

        // Outside the cells, the press is the collection view's, for its rubber band.
        let collection = grid.collectionView
        let below = NSPoint(x: collection.bounds.midX, y: collection.bounds.maxY - 2)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: collection.convert(below, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
        ))
        #expect(!grid.pressed(event))
    }

    @Test func `a header's click selects its moment's photos, and Shift-click or Command-click adds them`(
    ) async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let (grid, _) = try await makeGrid(fixture)
        try press(grid, group: 1)
        #expect(grid.selectedPlaces == [3, 4, 5, 6])
        try press(grid, group: 0, .shift)
        #expect(grid.selectedPlaces == Set(0 ... 6))
        try press(grid, group: 0, .command)
        #expect(grid.selectedPlaces == [3, 4, 5, 6], "Command-click takes a moment wholly selected out")
        try press(grid, group: 0, .command)
        #expect(grid.selectedPlaces == Set(0 ... 6))
        try press(grid, photo: 2)
        try press(grid, group: 1, .shift)
        #expect(grid.selectedPlaces == [2, 3, 4, 5, 6])
        // Shift extends from the first photo of the moment last clicked.
        try press(grid, group: 1)
        try press(grid, photo: 1, .shift)
        #expect(grid.selectedPlaces == [1, 2, 3])
    }

    @Test func `the arrow keys move the selection across moments, and Shift extends it from the photo last clicked`(
    ) async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let (grid, _) = try await makeGrid(fixture)
        try press(grid, .right)
        #expect(grid.selectedPlaces == [0], "from no photo selected, the first")
        try press(grid, photo: 1)
        try press(grid, .right, shift: true)
        #expect(grid.selectedPlaces == [1, 2])
        try press(grid, .right, shift: true)
        #expect(grid.selectedPlaces == [1, 2, 3], "across the header")
        try press(grid, .left, shift: true, times: 3)
        #expect(grid.selectedPlaces == [0, 1])
        try press(grid, .left)
        #expect(grid.selectedPlaces == [0], "the first photo stays")
        // The first moment is one row, the second two: 3, 4 and 5, then 6.
        try press(grid, .down)
        #expect(grid.selectedPlaces == [3], "into the next moment's first row")
        try press(grid, .down)
        #expect(grid.selectedPlaces == [6])
        try press(grid, .up)
        #expect(grid.selectedPlaces == [3])
        try press(grid, .up)
        #expect(grid.selectedPlaces == [0], "into the moment before's last row")
        try press(grid, photo: 2)
        try press(grid, .down)
        #expect(grid.selectedPlaces == [5])
        try press(grid, .down)
        #expect(grid.selectedPlaces == [6], "down reaches the last row, even where it's short")
        try press(grid, .up, shift: true)
        #expect(grid.selectedPlaces == [3, 4, 5, 6])
        try press(grid, .up, shift: true)
        #expect(grid.selectedPlaces == [0, 1, 2, 3, 4, 5, 6])
    }

    @Test func `the selection and the photo Shift extends from stay when the grid is reloaded`() async throws {
        let fixture = try await ImportWindowFixture.make()
        defer { fixture.remove() }
        let (grid, _) = try await makeGrid(fixture)
        try press(grid, photo: 2)
        try press(grid, photo: 1, .shift)
        #expect(grid.selectedPlaces == [1, 2])
        grid.groupBy.selectItem(withTitle: "None")
        grid.groupBy.sendAction(grid.groupBy.action, to: grid.groupBy.target)
        grid.view.layoutSubtreeIfNeeded()
        #expect(grid.collectionView.numberOfSections == 1)
        #expect(grid.selectedPlaces == [1, 2])
        try press(grid, photo: 5, .shift)
        #expect(grid.selectedPlaces == Set(2 ... 5), "from the photo clicked before the reload")
        try press(grid, .right, shift: true)
        #expect(grid.selectedPlaces == Set(2 ... 6))
    }
}
