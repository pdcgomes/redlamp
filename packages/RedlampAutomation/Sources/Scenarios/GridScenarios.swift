#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Carbon.HIToolbox
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    extension RunningApp {
        /// The Library grid on screen and taking the keyboard, with its cells.
        func showGrid() throws -> [String] {
            try openWorking()
            let names = try photoNames()
            try expect(names.count >= 6, "The folder has \(names.count) photos")
            try main { model in model.select(model.items[0].url) }
            try settle()
            try press(.gridView)
            try wait("the grid to take the keyboard") { _ in
                Views.editorWindow?.firstResponder.map { "\(Swift.type(of: $0))" } == "LibraryGridContentView"
            }
            try wait("the grid's cells") { _ in
                Views.editorWindow.flatMap { Views.find("grid.\(names[1])", in: $0) } != nil
            }
            // Laid out for the size and style the scenario before left.
            try settle()
            return names
        }

        /// What a click at `point` (window points) reaches, for a failure's message.
        func hitView(at point: NSPoint) throws -> String {
            try main { _ in
                let view = Views.editorWindow?.contentView?.superview?.hitTest(point)
                return view.map { "\(Swift.type(of: $0)) \($0.accessibilityIdentifier())" } ?? "nothing"
            }
        }

        /// Drags from `start` to `end` (window points) through the view under `start`, as the mouse does
        /// in a window that may not be key.
        func dragView(from start: NSPoint, to end: NSPoint, modifiers: NSEvent.ModifierFlags = []) throws {
            let steps = 6
            for step in 0 ... steps + 1 {
                try main { _ in
                    guard let window = Views.editorWindow,
                          let view = window.contentView?.superview?.hitTest(start) else {
                        throw ScenarioFailure("Nothing to drag at \(start)")
                    }
                    let t = CGFloat(min(step, steps)) / CGFloat(steps)
                    let location = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                    let type: NSEvent.EventType = step == 0 ? .leftMouseDown : step > steps ? .leftMouseUp
                        : .leftMouseDragged
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1,
                    ) else { return }
                    switch type {
                    case .leftMouseDown: view.mouseDown(with: event)
                    case .leftMouseDragged: view.mouseDragged(with: event)
                    default: view.mouseUp(with: event)
                    }
                }
                pause(0.02)
            }
            pause(0.05)
        }

        /// Chooses the item titled `title` (or "`title`    key") in the context menu of the view carrying
        /// `identifier`, at `point` (window points), as a right-click there opens it.
        func chooseInContextMenu(_ title: String, at point: NSPoint, submenu: String? = nil) throws {
            try main { _ in
                guard let window = Views.editorWindow, let view = window.contentView?.superview?.hitTest(point),
                      let event = NSEvent.mouseEvent(
                          with: .rightMouseDown, location: point, modifierFlags: [],
                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1,
                      ),
                      var menu = view.menu(for: event)
                else { throw ScenarioFailure("No context menu at \(point)") }
                if let submenu {
                    guard let inner = menu.items.first(where: { $0.title == submenu })?.submenu else {
                        throw ScenarioFailure("The context menu has no \(submenu)")
                    }
                    menu = inner
                }
                guard let index = menu.items
                    .firstIndex(where: { $0.title == title || $0.title.hasPrefix("\(title)    ") })
                else { throw ScenarioFailure("The context menu has no \(title): \(menu.items.map(\.title))") }
                guard menu.items[index].isEnabled else { throw ScenarioFailure("\(title) is disabled") }
                menu.performActionForItem(at: index)
                view.didCloseMenu(menu, with: nil)
            }
            pause(0.05)
        }
    }

    enum GridScenarios {
        static let all: [Scenario] = [sizes, styles, selection, loupe, sourceViews]

        @MainActor private static func size(_ model: EditorModel) -> Double {
            model.libraryViews.thumbnailSize
        }

        static let sizes = Scenario(
            "library.grid-sizes",
            "= and - in the grid, the View menu, the toolbar's slider and the palette size the thumbnails, "
                + "and the cells follow",
            claims: [.action(.largerThumbnails), .action(.smallerThumbnails), .feature("library.grid")],
        ) { app in
            let names = try app.showGrid()
            try app.main { $0.setThumbnailSize(GridSize.standard) }
            try app.press(.largerThumbnails)
            try app.wait("= to grow the thumbnails") { size($0) > GridSize.standard }
            app.covered(.action(.largerThumbnails), via: .key)
            try app.press(.smallerThumbnails)
            try app.wait("- to shrink them back") { size($0) == GridSize.standard }
            app.covered(.action(.smallerThumbnails), via: .key)
            try app.choose(.largerThumbnails)
            try app.choose(.smallerThumbnails)
            try app.wait("the menu's sizes") { size($0) == GridSize.standard }
            let slider = try app.frame(of: .identifier("library.toolbar.size"))
            try app.dragView(
                from: NSPoint(x: slider.midX, y: slider.midY), to: NSPoint(x: slider.maxX - 2, y: slider.midY),
            )
            try app.wait("the slider to make them as large as they go") { size($0) > 390 }
            try app.wait("the cells to follow") { _ in
                Views.editorWindow.flatMap { Views.find("grid.\(names[0])", in: $0) }.map { $0.width > 390 } == true
            }
            app.covered(.feature("library.grid"), via: .mouse)
            try app.runFromPalette(.smallerThumbnails)
            try app.wait("the palette's size") { size($0) < 390 }
            try app.main { $0.setThumbnailSize(GridSize.standard) }
            try app.backToDevelop()
        }

        static let styles = Scenario(
            "library.grid-styles",
            "J, the View menu's Grid View Style, the toolbar and the palette cycle the cell styles: compact, "
                + "expanded with the photo's name, date and settings, and thumbnails only",
            claims: [.action(.cycleGridStyle), .feature("library.grid")],
        ) { app in
            let names = try app.showGrid()
            try app.main { $0.setCellStyle(.compact) }
            let compact = try app.frame(of: .identifier("grid.\(names[0])"))
            try app.press(.cycleGridStyle)
            try app.wait("J: expanded cells") { $0.libraryViews.cellStyle == .expanded }
            try app.wait("taller cells") { _ in
                (Views.editorWindow.flatMap { Views.find("grid.\(names[0])", in: $0) }?.height ?? 0) > compact.height
            }
            try app.choose(.cycleGridStyle)
            try app.wait("the menu: thumbnails only") { $0.libraryViews.cellStyle == .none }
            try app.clickView("library.toolbar.compact")
            try app.wait("the toolbar: compact cells") { $0.libraryViews.cellStyle == .compact }
            app.covered(.feature("library.grid"), via: .mouse)
            try app.runFromPalette(.cycleGridStyle)
            try app.wait("the palette: expanded cells") { $0.libraryViews.cellStyle == .expanded }
            try app.main { $0.setCellStyle(.compact) }
            try app.backToDevelop()
        }

        static let selection = Scenario(
            "library.grid-selection",
            "A rubber band selects the photos it meets, with ⇧ adding to them; the context menu shows them in "
                + "Finder and opens one in the loupe; ⌘R shows them from the Photo menu",
            claims: [.action(.showInFinder), .feature("library.grid"), .feature("library.filmstrip")],
        ) { app in
            let names = try app.showGrid()
            let first = try app.frame(of: .identifier("grid.\(names[0])"))
            let third = try app.frame(of: .identifier("grid.\(names[2])"))
            let start = NSPoint(x: first.minX - 3, y: first.maxY + 3)
            try app.dragView(from: start, to: NSPoint(x: third.midX, y: third.midY))
            var state = try app.selectionState()
            let reached = try app.hitView(at: start)
            try app.expect(
                state.photos == Array(names[0 ... 2]) && state.active == names[0],
                "The band from \(start) (\(reached), the first cell at \(first)) gave \(state)",
            )
            let fifth = try app.frame(of: .identifier("grid.\(names[4])"))
            try app.dragView(
                from: NSPoint(x: fifth.minX - 3, y: fifth.maxY + 3), to: NSPoint(x: fifth.midX, y: fifth.midY),
                modifiers: .shift,
            )
            state = try app.selectionState()
            try app.expect(state.photos == Array(names[0 ... 2]) + [names[4]], "⇧ with the band gave \(state)")
            app.covered(.feature("library.filmstrip"), via: .mouse)

            try app.main { _ in Revealed.photos = [] }
            try app.main { $0.libraryViews.revealInFinder = { Revealed.photos.append(contentsOf: $0) } }
            defer { try? app.main { $0.libraryViews.revealInFinder = Revealed.finder } }
            try app.chooseInContextMenu("Show in Finder", at: NSPoint(x: third.midX, y: third.midY))
            let shown = try app.main { _ in Revealed.photos.map(\.lastPathComponent) }
            try app.expect(shown == state.photos, "Show in Finder showed \(shown)")
            app.covered(.action(.showInFinder), via: .mouse)
            try app.main { _ in Revealed.photos = [] }
            try app.choose(.showInFinder)
            try app.expect(try app.main { _ in Revealed.photos.count } == state.photos.count, "⌘R's menu item")

            try app.chooseInContextMenu("Open in Loupe", at: NSPoint(x: third.midX, y: third.midY))
            try app.wait("the loupe on \(names[2])") { $0.libraryView == .loupe }
            try app.expect(try app.selectionState().active == names[2], "The loupe shows another photo")
            app.covered(.feature("library.grid"), via: .mouse)
            try app.press(.gridView)
            try app.wait("the grid") { $0.libraryView == .grid }
            try app.chooseInContextMenu(
                "Expanded",
                at: NSPoint(x: first.minX - 3, y: first.maxY + 3),
                submenu: "Grid View Style",
            )
            try app.wait("the background menu's style") { $0.libraryViews.cellStyle == .expanded }
            try app.main { model in
                model.setCellStyle(.compact)
                model.deselectOtherPhotos()
            }
            try app.backToDevelop()
        }

        static let loupe = Scenario(
            "library.loupe-zoom",
            "The loupe zooms to 1:1 and fits again by Z, Space, a click and its toolbar, showing the photo's name",
            claims: [.action(.toggleZoom), .feature("library.loupe")],
        ) { app in
            let names = try app.showGrid()
            try app.press(.loupeView)
            try app.wait("the loupe") { $0.libraryView == .loupe && $0.libraryViews.loupeZoom == .fit }
            try app.wait("the loupe's preview", timeout: 20) { model in
                model.selection.flatMap(model.previews.cached) != nil
            }
            try app.press(.toggleZoom)
            try app.wait("Z: 1:1") { $0.libraryViews.loupeZoom == .actual }
            try app.clickView("library.loupe")
            try app.wait("a click: fit") { $0.libraryViews.loupeZoom == .fit }
            app.covered(.feature("library.loupe"), via: .mouse)
            try app.press(KeyCombo(.space))
            try app.wait("Space: 1:1") { $0.libraryViews.loupeZoom == .actual }
            let fit = try app.frame(of: .identifier("library.toolbar.fit"))
            try app.clickView("library.toolbar.fit")
            let reached = try app.hitView(at: NSPoint(x: fit.midX, y: fit.midY))
            try app
                .wait("the toolbar's Fit at \(fit), reaching \(reached), to fit") { $0.libraryViews.loupeZoom == .fit }
            try app.expect(
                try app.main { _ in
                    Views.editorWindow.flatMap { window in
                        Views.all(NSView.self, in: window.contentView?.superview ?? NSView())
                            .first { $0.accessibilityIdentifier() == "library.loupe" }?.accessibilityLabel()
                    }
                } == names[0], "The loupe doesn't name its photo",
            )
            try app.press(KeyCombo(.escape))
            try app.wait("Esc: the grid") { $0.libraryView == .grid }
            try app.backToDevelop()
        }

        static let sourceViews = Scenario(
            "library.source-views",
            "Each source keeps its thumbnail size, cell style and selection: the folder with and without its "
                + "subfolders",
            claims: [.feature("library.grid"), .feature("library.subfolders")],
        ) { app in
            let names = try app.showGrid()
            try app.main { model in
                model.setThumbnailSize(168)
                model.setCellStyle(.expanded)
                model.click(model.items[1].url, toggling: true)
            }
            let kept = try app.selectionState()
            try app.expect(kept.photos == [names[0], names[1]], "⌘-click gave \(kept)")
            try app.main { $0.setIncludesSubfolders(true) }
            try app.wait("the folder with its subfolders") { $0.library.includesSubfolders && !$0.library.isListing }
            try app.main { model in
                model.setThumbnailSize(96)
                model.setCellStyle(.none)
            }
            try app.main { $0.setIncludesSubfolders(false) }
            try app.wait("the folder alone") { !$0.library.includesSubfolders && !$0.library.isListing }
            try app.wait("its size and style back") { model in
                model.libraryViews.thumbnailSize == 168 && model.libraryViews.cellStyle == .expanded
            }
            let back = try app.selectionState()
            try app.expect(
                back.photos == kept.photos && back.active == kept.active,
                "The selection came back as \(back)",
            )
            app.covered([.feature("library.grid"), .feature("library.subfolders")], via: .model)
            try app.main { model in
                model.setThumbnailSize(GridSize.standard)
                model.setCellStyle(.compact)
                model.deselectOtherPhotos()
            }
            try app.backToDevelop()
        }
    }
#endif
