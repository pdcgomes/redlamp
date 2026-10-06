import AppKit
import Carbon.HIToolbox
import Foundation
import RedlampDocument
import Testing
@testable import RedlampUI

/// The Library module's first grid (LIB-13): reused cells laid out from their index, its keys, and clicks
/// that select as the filmstrip's do, on the one selection both share.
@MainActor
struct LibraryGridTests {
    private func showGrid(_ fixture: ModuleFixture, count: Int) async throws -> LibraryGridView {
        try await fixture.open(count: count)
        let modules = fixture.showModules()
        fixture.model.showModule(.library)
        try await fixture.settle()
        let grid = modules.grid
        grid.layoutSubtreeIfNeeded()
        grid.collectionView.layoutSubtreeIfNeeded()
        return grid
    }

    private func cell(_ grid: LibraryGridView, _ row: Int) -> LibraryGridCellView? {
        (grid.collectionView.item(at: IndexPath(item: row, section: 0)) as? LibraryGridItem)?.cell
    }

    private func press(_ grid: LibraryGridView, _ code: Int, shift: Bool = false) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? [.shift, .function] : [.function], timestamp: 0,
            windowNumber: grid.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(code),
        ))
        grid.collectionView.keyDown(with: event)
    }

    private func click(_ view: NSView, modifiers: NSEvent.ModifierFlags = [], count: Int = 1) throws {
        for clicks in 1 ... count {
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks,
                pressure: 1,
            ))
            view.mouseDown(with: event)
        }
    }

    private func names(_ model: EditorModel) -> [String] {
        model.selectedPhotos.map(\.lastPathComponent)
    }

    @Test func `a thousand photos make only a screenful of cells, each where its index puts it`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let grid = try await showGrid(fixture, count: 1000)
        #expect(grid.collectionView.numberOfItems(inSection: 0) == 1000)
        let cells = grid.collectionView.subviews.count { $0 is LibraryGridCellView }
        #expect(cells > 0 && cells < 150, "\(cells) cells for a screenful")
        let columns = grid.layout.columns
        #expect(columns > 1)
        let first = grid.layout.frame(forItem: 0)
        let below = grid.layout.frame(forItem: columns)
        #expect(below.minX == first.minX && below.minY > first.maxY, "the next row starts under the first")
        #expect(grid.layout.items(in: CGRect(x: 0, y: below.midY, width: 10, height: 1)) == columns ..< columns * 2)
        try await fixture.eventually { cell(grid, 0)?.image != nil }
        #expect(cell(grid, 0)?.image != nil, "visible cells get their thumbnails")
    }

    @Test func `arrow keys, Home, End and Page Down move the active photo, and ⇧ extends from where it started`()
        async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let grid = try await showGrid(fixture, count: 200)
        let model = fixture.model
        let columns = grid.layout.columns
        let name = { (index: Int) in fixture.photos[index].lastPathComponent }
        #expect(model.selection == fixture.photos[0])
        try press(grid, kVK_RightArrow)
        #expect(names(model) == [name(1)])
        try press(grid, kVK_DownArrow)
        #expect(model.selection == fixture.photos[1 + columns] && names(model) == [name(1 + columns)])
        try press(grid, kVK_RightArrow, shift: true)
        try press(grid, kVK_RightArrow, shift: true)
        #expect(names(model) == [name(1 + columns), name(2 + columns), name(3 + columns)])
        #expect(model.selection == fixture.photos[3 + columns], "the active photo moves; the selection extends")
        try press(grid, kVK_UpArrow, shift: true)
        #expect(names(model) == (3 ... 1 + columns).map(name), "⇧↑ extends from where the selection started")
        try press(grid, kVK_Home)
        #expect(names(model) == [name(0)])
        try press(grid, kVK_End, shift: true)
        #expect(model.selectedPhotos.count == 200 && model.selection == fixture.photos[199])
        try press(grid, kVK_Home)
        try press(grid, kVK_PageDown)
        let page = try #require(model.selection.flatMap(model.library.index(of:)))
        #expect(page > 0 && page.isMultiple(of: columns), "Page Down moves whole rows")
        try press(grid, kVK_End)
        try press(grid, kVK_DownArrow)
        #expect(model.selection == fixture.photos[199], "down from the last row stays")
        #expect(model.module == .library && model.info?.url != fixture.photos[199], "Library opens nothing")
    }

    @Test func `clicks in the grid select as clicks in the filmstrip do`() async throws {
        let gridFixture = ModuleFixture()
        let stripFixture = ModuleFixture()
        defer {
            gridFixture.cleanUp()
            stripFixture.cleanUp()
        }
        let grid = try await showGrid(gridFixture, count: 12)
        try await stripFixture.open(count: 12)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1400, height: FilmstripStripView.height), styleMask: [.titled],
            backing: .buffered, defer: false,
        )
        let strip = FilmstripStripView(model: stripFixture.model)
        window.contentView = strip
        defer { window.contentView = nil }
        strip.layoutSubtreeIfNeeded()
        strip.collectionView.layoutSubtreeIfNeeded()
        let clicks: [(Int, NSEvent.ModifierFlags)] = [
            (3, []), (5, .command), (8, .shift), (6, .command), (1, .shift), (10, []), (7, .shift), (9, .command),
        ]
        for (row, modifiers) in clicks {
            try click(#require(cell(grid, row)), modifiers: modifiers)
            let filmstripCell = try #require(
                (strip.collectionView.item(at: IndexPath(item: row, section: 0)) as? FilmstripItem)?.cell,
            )
            try click(filmstripCell, modifiers: modifiers)
            #expect(
                names(gridFixture.model) == names(stripFixture.model),
                "after \(modifiers.rawValue)-click on \(row)",
            )
            #expect(
                gridFixture.model.selection?.lastPathComponent == stripFixture.model.selection?.lastPathComponent,
            )
        }
        try await gridFixture.settle()
        let selected = Set(gridFixture.model.selectedPhotos)
        for row in 0 ..< 12 {
            let shown = try #require(cell(grid, row))
            #expect(shown.isSelected == (gridFixture.model.selection == gridFixture.photos[row]))
            #expect(shown.isInSelection == (selected.contains(gridFixture.photos[row]) && !shown.isSelected))
        }
    }

    @Test func `a double-click, Return and Space open the loupe, and D opens the photo in Develop`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let grid = try await showGrid(fixture, count: 10)
        let model = fixture.model
        try click(#require(cell(grid, 4)), count: 2)
        #expect(model.selection == fixture.photos[4] && model.libraryView == .loupe)
        model.showLibrary(.grid)
        try press(grid, kVK_Return)
        #expect(model.libraryView == .loupe)
        model.showLibrary(.grid)
        try press(grid, kVK_Space)
        #expect(model.libraryView == .loupe)
        #expect(model.perform(.editTool) && model.module == .develop)
        try await fixture.eventually { model.info?.url == fixture.photos[4] }
        #expect(model.info?.url == fixture.photos[4])
    }

    @Test func `photos that change while the grid is hidden appear once it's shown`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let grid = try await showGrid(fixture, count: 5)
        let model = fixture.model
        model.showModule(.develop)
        try await fixture.settle()
        let reloads = grid.reloads
        /// On disk too, so the folder's watcher agrees with what's inserted.
        func add(_ name: String) {
            let url = fixture.folder.appending(path: name)
            FileManager.default.createFile(atPath: url.path, contents: Data([1]))
            model.library.insert(LibraryItem(url: url))
        }
        add("IMG_00002b.ARW")
        #expect(grid.collectionView.numberOfItems(inSection: 0) == 5, "the hidden grid waits")
        model.showModule(.library)
        try await fixture.settle()
        #expect(grid.reloads == reloads + 1 && grid.collectionView.numberOfItems(inSection: 0) == 6)
        add("IMG_00002c.ARW")
        #expect(grid.collectionView.numberOfItems(inSection: 0) == 7, "the shown grid follows at once")
        #expect(grid.reloads == reloads + 1)
    }
}
