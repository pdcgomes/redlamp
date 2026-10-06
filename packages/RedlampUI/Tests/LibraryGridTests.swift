import AppKit
import Carbon.HIToolbox
import Foundation
import RedlampDocument
import RedlampLibrary
import Testing
@_spi(Harness) @testable import RedlampUI

/// The Library grid (LIB-13's first, LIB-14's): cells of layers recycled as it scrolls and laid out from
/// their index, its keys, clicks and rubber band on the selection by photo ID the filmstrip shares, its
/// sizes and cell styles, its context menus, and each source's view kept.
@MainActor
struct LibraryGridTests {
    private func showGrid(_ fixture: ModuleFixture, count: Int) async throws -> LibraryGridView {
        try await fixture.open(count: count)
        let modules = fixture.showModules()
        fixture.model.showModule(.library)
        try await fixture.settle()
        let grid = modules.grid
        grid.layoutSubtreeIfNeeded()
        return grid
    }

    private func press(_ grid: LibraryGridView, _ code: Int, shift: Bool = false) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? [.shift, .function] : [.function], timestamp: 0,
            windowNumber: grid.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(code),
        ))
        grid.content.keyDown(with: event)
    }

    /// A mouse event at `point` in the grid's content.
    private func mouse(
        _ type: NSEvent.EventType, _ grid: LibraryGridView, at point: CGPoint,
        modifiers: NSEvent.ModifierFlags = [], clicks: Int = 1,
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: grid.content.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0,
            windowNumber: grid.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks,
            pressure: type == .leftMouseUp ? 0 : 1,
        ))
    }

    private func middle(_ grid: LibraryGridView, _ row: Int) -> CGPoint {
        let frame = grid.gridLayout.frame(forItem: row)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func click(
        _ grid: LibraryGridView, _ row: Int, modifiers: NSEvent.ModifierFlags = [], count: Int = 1,
    ) throws {
        let point = middle(grid, row)
        for clicks in 1 ... count {
            try grid.content.mouseDown(with: mouse(
                .leftMouseDown,
                grid,
                at: point,
                modifiers: modifiers,
                clicks: clicks,
            ))
            try grid.content.mouseUp(with: mouse(.leftMouseUp, grid, at: point, modifiers: modifiers, clicks: clicks))
        }
    }

    /// A rubber band from `start` to `end`, in moves.
    private func band(
        _ grid: LibraryGridView, from start: CGPoint, to end: CGPoint, modifiers: NSEvent.ModifierFlags = [],
    ) throws {
        try grid.content.mouseDown(with: mouse(.leftMouseDown, grid, at: start, modifiers: modifiers))
        for step in 1 ... 4 {
            let t = CGFloat(step) / 4
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            try grid.content.mouseDragged(with: mouse(.leftMouseDragged, grid, at: point, modifiers: modifiers))
        }
        try grid.content.mouseUp(with: mouse(.leftMouseUp, grid, at: end, modifiers: modifiers))
    }

    /// Just above and left of cell `row`, between the cells.
    private func beside(_ grid: LibraryGridView, _ row: Int) -> CGPoint {
        let frame = grid.gridLayout.frame(forItem: row)
        let gap = max(grid.gridLayout.spacing / 2, 2)
        return CGPoint(x: frame.minX - gap, y: frame.minY - gap)
    }

    private func names(_ model: EditorModel) -> [String] {
        model.selectedPhotos.map(\.lastPathComponent)
    }

    @Test func `a thousand photos make a screenful of cells of layers, each where its index puts it, reused as it scrolls`(
    )
        async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let grid = try await showGrid(fixture, count: 1000)
        #expect(grid.shownCount == 1000)
        let cells = grid.cells.count
        #expect(cells > 0 && cells < 150, "\(cells) cells for a screenful")
        #expect(grid.content.subviews.isEmpty, "a cell is layers, not a view")
        let layout = grid.gridLayout
        #expect(layout.columns > 1)
        let first = layout.frame(forItem: 0)
        let below = layout.frame(forItem: layout.columns)
        #expect(below.minX == first.minX && below.minY > first.maxY, "the next row starts under the first")
        #expect(layout.items(in: CGRect(x: 0, y: below.midY, width: 10, height: 1)) == layout.columns ..< layout
            .columns * 2)
        #expect(layout.item(at: middle(grid, 3)) == 3 && layout.item(at: beside(grid, 3)) == nil)
        try await fixture.eventually { grid.cells[0]?.image != nil }
        #expect(grid.cells[0]?.image != nil, "visible cells get their thumbnails")

        let layers = grid.content.layer?.sublayers?.count ?? 0
        for fraction in stride(from: 0.1, through: 1.0, by: 0.1) {
            LibraryGridViews.scroll(grid, to: fraction)
        }
        try await fixture.settle()
        let rows = grid.cells.keys.sorted()
        #expect(rows.last == 999, "the last cells are on screen at the end")
        #expect((grid.content.layer?.sublayers?.count ?? 0) <= layers + 2 * layout.columns, "cells are reused")
    }

    @Test func `arrow keys, Home, End and Page Down move the active photo, ⇧ extends from where it started, and Z opens the loupe at 1:1`(
    )
        async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let grid = try await showGrid(fixture, count: 200)
        let model = fixture.model
        let columns = grid.gridLayout.columns
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
        #expect(model.photoSelection.count == 200 && model.selection == fixture.photos[199])
        try press(grid, kVK_Home)
        try press(grid, kVK_PageDown)
        let page = try #require(model.selection.flatMap(model.library.index(of:)))
        #expect(page > 0 && page.isMultiple(of: columns), "Page Down moves whole rows")
        try press(grid, kVK_End)
        try press(grid, kVK_DownArrow)
        #expect(model.selection == fixture.photos[199], "down from the last row stays")
        #expect(model.module == .library && model.info?.url != fixture.photos[199], "Library opens nothing")
        try press(grid, kVK_ANSI_Z)
        #expect(model.libraryView == .loupe && model.libraryViews.loupeZoom == .actual, "Z: the loupe at 1:1")
    }

    @Test func `clicks in the grid select by photo ID as clicks in the filmstrip do`() async throws {
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
            try click(grid, row, modifiers: modifiers)
            let filmstripCell = try #require(
                (strip.collectionView.item(at: IndexPath(item: row, section: 0)) as? FilmstripItem)?.cell,
            )
            try filmstripCell.mouseDown(with: mouse(.leftMouseDown, grid, at: .zero, modifiers: modifiers))
            #expect(
                names(gridFixture.model) == names(stripFixture.model),
                "after \(modifiers.rawValue)-click on \(row)",
            )
            #expect(
                gridFixture.model.selection?.lastPathComponent == stripFixture.model.selection?.lastPathComponent,
            )
        }
        try await gridFixture.settle()
        let model = gridFixture.model
        let selected = Set(model.selectedPhotos)
        for row in 0 ..< 12 {
            let cell = try #require(grid.cells[row])
            let id = model.library.photoIDs[row]
            #expect(model.photoSelection.contains(id) == selected.contains(gridFixture.photos[row]))
            #expect(cell.isActive == (model.selection == gridFixture.photos[row]))
            #expect(cell.isInSelection == (selected.contains(gridFixture.photos[row]) && !cell.isActive))
        }
    }

    @Test func `a rubber band selects the photos it meets, alone or added with ⇧, and the filmstrip shows them`()
        async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let grid = try await showGrid(fixture, count: 40)
        let model = fixture.model
        let columns = grid.gridLayout.columns
        let rows = { (indexes: [Int]) in indexes.map { fixture.photos[$0].lastPathComponent } }
        try band(grid, from: beside(grid, 0), to: middle(grid, columns + 1))
        #expect(names(model) == rows([0, 1, columns, columns + 1]))
        #expect(model.selection == fixture.photos[0], "the active photo stays while the band covers it")

        try band(grid, from: beside(grid, 2 * columns + 2), to: middle(grid, 2 * columns + 3))
        #expect(names(model) == rows([2 * columns + 2, 2 * columns + 3]), "a new band replaces the selection")
        #expect(model.selection == fixture.photos[2 * columns + 2], "the first photo it covers is active")

        try band(grid, from: beside(grid, 0), to: middle(grid, 1), modifiers: .shift)
        #expect(names(model) == rows([0, 1, 2 * columns + 2, 2 * columns + 3]), "⇧ adds to the selection")
        #expect(model.selection == fixture.photos[2 * columns + 2])

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1400, height: FilmstripStripView.height), styleMask: [.titled],
            backing: .buffered, defer: false,
        )
        let strip = FilmstripStripView(model: model)
        window.contentView = strip
        defer { window.contentView = nil }
        strip.layoutSubtreeIfNeeded()
        strip.collectionView.layoutSubtreeIfNeeded()
        try await fixture.settle()
        for row in [0, 1] {
            let cell = try #require((strip.collectionView.item(at: IndexPath(item: row, section: 0)) as? FilmstripItem)?
                .cell)
            #expect(cell.isInSelection, "the filmstrip shows the band's photo \(row) selected")
        }

        let empty = CGPoint(x: middle(grid, 39).x + 4, y: grid.gridLayout.contentHeight - 3)
        try band(grid, from: empty, to: CGPoint(x: empty.x + 30, y: empty.y - 2))
        #expect(names(model) == rows([2 * columns + 2]), "a band that meets no photo leaves the active one alone")
    }

    @Test func `= and - and the toolbar's slider size the thumbnails, decoded at the size the cells need`()
        async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let grid = try await showGrid(fixture, count: 30)
        let model = fixture.model
        let state = model.libraryViews
        #expect(ShortcutAction.resolve(.char("="), in: .library)?.action == .largerThumbnails)
        #expect(ShortcutAction.resolve(.char("-"), in: .library)?.action == .smallerThumbnails)
        #expect(ShortcutAction.resolve(.char("="))?.action == .increaseSetting, "Develop keeps = and -")
        #expect(state.thumbnailSize == GridSize.standard)
        #expect(model.perform(.largerThumbnails))
        try await fixture.settle()
        #expect(state.thumbnailSize == 144 && grid.gridLayout.cellSize.width == 144)
        #expect(grid.cells[0].map(\.root.frame.width) == 144, "the cells follow")
        #expect(model.perform(.smallerThumbnails) && model.perform(.smallerThumbnails))
        #expect(state.thumbnailSize == 112)

        let toolbar = try #require(grid.superview?.subviews.compactMap { $0 as? LibraryToolbarView }.first)
        toolbar.layoutSubtreeIfNeeded()
        let slider = try #require(toolbar.subviews.compactMap { $0 as? ToolbarSlider }.first)
        let end = slider.convert(CGPoint(x: slider.bounds.maxX - 1, y: slider.bounds.midY), to: nil)
        try slider.mouseDown(with: #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: end, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1,
        )))
        #expect(state.thumbnailSize > 390, "the slider's far end is the largest size")
        try await fixture.settle()
        let scale = grid.window?.backingScaleFactor ?? 2
        let edge = GridThumbnails.edge(forPixels: grid.gridLayout.geometry.image.width * scale)
        #expect(edge > PhotoStore.Tier.grid.pixelSize || scale < 2, "large cells take more than the grid tier")
        try await fixture.eventually { grid.cells[0]?.edge == edge }
        #expect(grid.cells[0]?.image?.width == edge, "the thumbnail is decoded at the cell's size")
        #expect(!model.perform(.largerThumbnails) && model.perform(.smallerThumbnails))

        model.showModule(.develop)
        #expect(!model.canPerform(.largerThumbnails) && !model.perform(.smallerThumbnails), "Develop's = and -")
    }

    @Test func `J cycles the cell styles: compact, expanded with the photo's name, then thumbnails alone`(
    ) async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let grid = try await showGrid(fixture, count: 10)
        let model = fixture.model
        #expect(ShortcutAction.resolve(.char("j"), in: .library)?.action == .cycleGridStyle)
        #expect(ShortcutAction.resolve(.char("j"))?.action == .clipping, "Develop's J shows clipping")
        model.library.update(fixture.photos[0]) { $0.metadata = PhotoMetadata(rating: 3, flag: .pick, label: .red) }
        try await fixture.settle()
        #expect(model.libraryViews.cellStyle == .compact)
        #expect((grid.cells[0]?.badgesShown ?? 0) == 3, "a compact cell shows its rating, flag and label")
        let compact = grid.gridLayout.cellSize

        #expect(model.perform(.cycleGridStyle))
        try await fixture.settle()
        #expect(model.libraryViews.cellStyle == .expanded)
        #expect(grid.gridLayout.cellSize.height > compact.height && grid.gridLayout.cellSize.width == compact.width)
        try await fixture.eventually { grid.cells[0]?.textImage != nil }
        #expect(grid.cells[0]?.textImage != nil, "an expanded cell shows the photo's name")
        #expect((grid.cells[0]?.badgesShown ?? 0) == 3)

        #expect(model.perform(.cycleGridStyle))
        try await fixture.settle()
        #expect(model.libraryViews.cellStyle == .none && grid.gridLayout.cellSize == compact)
        #expect(grid.cells[0]?.badgesShown == 0 && grid.cells[0]?.textImage == nil, "thumbnails alone")

        #expect(model.perform(.cycleGridStyle))
        #expect(model.libraryViews.cellStyle == .compact)
    }

    @Test func `context menus open photos in the loupe and Develop, show them in Finder, and set the view`(
    ) async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let grid = try await showGrid(fixture, count: 12)
        let model = fixture.model
        var revealed: [URL] = []
        model.libraryViews.revealInFinder = { revealed = $0 }
        func menu(at point: CGPoint) throws -> NSMenu {
            try #require(grid.content.menu(for: mouse(.rightMouseDown, grid, at: point)))
        }
        func choose(_ title: String, in menu: NSMenu) throws {
            let index = try #require(menu.items.firstIndex { $0.title == title || $0.title.hasPrefix("\(title)    ") })
            #expect(menu.items[index].isEnabled, "\(title) is enabled")
            menu.performActionForItem(at: index)
        }

        let photo = try menu(at: middle(grid, 3))
        let titles = photo.items.map(\.title)
        #expect(titles.contains("Open in Loupe    E") && titles.contains("Open in Develop    D"))
        let finder = try #require(photo.items.first { $0.title == "Show in Finder" })
        #expect(finder.keyEquivalent == "r" && finder.keyEquivalentModifierMask == .command, "⌘R")
        #expect(titles.contains("Increase Thumbnail Size    =") && titles.contains("Decrease Thumbnail Size    -"))
        let styles = try #require(photo.items.first { $0.title == "Grid View Style" }?.submenu)
        #expect(styles.items.map(\.title).prefix(3) == ["Compact", "Expanded", "Thumbnails Only"])
        #expect(styles.items.last?.title == "Cycle Grid View Style    J")
        try choose("Show in Finder", in: photo)
        #expect(revealed == [fixture.photos[3]], "a photo not selected is shown alone")

        try click(grid, 4)
        try click(grid, 5, modifiers: .command)
        try choose("Show in Finder", in: menu(at: middle(grid, 4)))
        #expect(revealed == [fixture.photos[4], fixture.photos[5]], "a selected photo shows the selection")
        try choose("Open in Loupe", in: menu(at: middle(grid, 4)))
        #expect(model.libraryView == .loupe && model.selection == fixture.photos[4])
        #expect(model.selectedPhotos == [fixture.photos[4], fixture.photos[5]], "the selection stays")
        model.showLibrary(.grid)
        try await fixture.settle()
        try choose("Expanded", in: #require(menu(at: middle(grid, 0)).items.first { $0.title == "Grid View Style" }?
                .submenu))
        #expect(model.libraryViews.cellStyle == .expanded)
        try await fixture.settle()

        let background = try menu(at: beside(grid, 1))
        try choose(ShortcutAction.selectAllPhotos.title, in: background)
        #expect(model.photoSelection.count == 12)
        try choose("Open in Develop", in: menu(at: middle(grid, 6)))
        #expect(model.module == .develop && model.selection == fixture.photos[6])
    }

    @Test func `each source keeps its size, cell style, place and selection`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let grid = try await showGrid(fixture, count: 300)
        let model = fixture.model
        let other = fixture.folder.deletingLastPathComponent().appending(path: "modules-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        for index in 0 ..< 20 {
            FileManager.default.createFile(
                atPath: other.appending(path: String(format: "OTHER_%03d.ARW", index)).path, contents: Data([1]),
            )
        }
        model.setThumbnailSize(196)
        model.setCellStyle(.expanded)
        try await fixture.settle()
        LibraryGridViews.scroll(grid, to: 0.5)
        try await fixture.settle()
        let top = try #require(model.libraryViews.topPhoto)
        let topRow = try #require(model.library.index(of: top))
        try click(grid, topRow)
        try click(grid, topRow + 2, modifiers: .command)
        let kept = model.selectedPhotos
        #expect(kept.count == 2)

        model.showFolder(other)
        try await fixture.eventually { model.folder == other && model.library.count == 20 && model.selection != nil }
        model.setThumbnailSize(96)
        model.setCellStyle(.none)
        try await fixture.settle()

        model.showFolder(fixture.folder)
        try await fixture.eventually { model.folder == fixture.folder && model.library.count == 300 }
        try await fixture.settle()
        #expect(model.libraryViews.thumbnailSize == 196 && model.libraryViews.cellStyle == .expanded)
        #expect(model.selectedPhotos == kept && model.selection == kept.last, "the selection comes back")
        try await fixture.eventually { grid.cells[topRow] != nil }
        let visible = grid.scrollView.contentView.bounds
        #expect(grid.gridLayout.frame(forItem: topRow).intersects(visible), "the grid goes back to its place")
        model.showFolder(other)
        try await fixture.eventually { model.folder == other && model.library.count == 20 }
        #expect(model.libraryViews.thumbnailSize == 96 && model.libraryViews.cellStyle == GridCellStyle.none)
    }

    @Test func `a double-click, Return and Space open the loupe, and D opens the photo in Develop`() async throws {
        let fixture = ModuleFixture()
        defer { fixture.cleanUp() }
        let grid = try await showGrid(fixture, count: 10)
        let model = fixture.model
        try click(grid, 4, count: 2)
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
        #expect(grid.shownCount == 5, "the hidden grid waits")
        model.showModule(.library)
        try await fixture.settle()
        #expect(grid.reloads == reloads + 1 && grid.shownCount == 6)
        add("IMG_00002c.ARW")
        #expect(grid.shownCount == 7, "the shown grid follows at once")
        #expect(grid.reloads == reloads + 1)
        #expect(grid.cells[3]?.item?.name == "IMG_00002b.ARW" && grid.cells[4]?.item?.name == "IMG_00002c.ARW")
    }
}
