#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Carbon.HIToolbox
    import RedlampEngineAPI
    @_spi(Harness) import RedlampUI

    extension ActionCheck {
        @MainActor static func moduleState(_ model: EditorModel) -> String {
            "\(model.module) \(model.libraryView)"
        }

        /// Shows a module or a Library view from the other module (⌥⌘↑ from Develop, after Library);
        /// Develop afterwards, on the grid.
        static func module(_ action: ShortcutAction) -> ActionCheck {
            ActionCheck(action: action, setUp: { app in
                try app.main { model in
                    model.showModule(.library)
                    if action != .developModule {
                        model.showModule(.develop)
                    }
                }
            }, observe: moduleState, restore: { app in
                try app.backToDevelop()
            })
        }
    }

    extension RunningApp {
        /// Develop again, on the grid when Library is next shown, with the photo rendered.
        func backToDevelop() throws {
            try main { model in
                model.showLibrary(.grid)
                model.showModule(.develop)
            }
            try settle()
        }

        /// Checks that `action`'s menu item carries its arrow key and exactly its modifiers.
        func expectArrowKeyBinding(_ action: ShortcutAction) throws {
            guard let combo = action.combos.first else { throw ScenarioFailure("\(action.title) has no key") }
            let arrows: [KeyCombo.Key: Int] = [
                .left: NSLeftArrowFunctionKey, .right: NSRightArrowFunctionKey,
                .up: NSUpArrowFunctionKey, .down: NSDownArrowFunctionKey,
            ]
            guard let arrow = arrows[combo.key].flatMap(UnicodeScalar.init).map(String.init) else {
                throw ScenarioFailure("\(action.title)'s key isn't an arrow")
            }
            let item = try main { _ -> (key: String, mask: NSEvent.ModifierFlags)? in
                guard let (menu, index) = Menus.find(Menus.title(of: action)) else { return nil }
                return (menu.items[index].keyEquivalent, menu.items[index].keyEquivalentModifierMask)
            }
            guard let (key, mask) = item else { throw ScenarioFailure("\(action.title) has no menu item") }
            var expected: NSEvent.ModifierFlags = [.command]
            if combo.shift {
                expected.insert(.shift)
            }
            if combo.option {
                expected.insert(.option)
            }
            let modifiers = mask.intersection([.command, .shift, .option, .control])
            try expect(modifiers == expected, "\(action.title)'s item has modifiers \(modifiers.rawValue)")
            try expect(key == arrow, "\(action.title)'s item has the key '\(key)', not \(combo.display)")
            covered(.action(action), via: .binding)
        }

        /// A key the grid handles itself (it isn't a shortcut), sent to the window's first responder as the
        /// keyboard's would be once the key monitor let it through.
        func pressGridKey(_ code: Int, characters: String, shift: Bool = false) throws {
            try main { _ in
                guard let window = Views.editorWindow, let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: shift ? [.shift, .function] : [.function],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                    keyCode: UInt16(code),
                ) else { throw ScenarioFailure("Couldn't make the grid's key \(code)") }
                window.sendEvent(event)
            }
            pause(0.05)
        }

        /// Clicks the view carrying `identifier` with `modifiers` held, as a click reaches a view in a window
        /// that may not be key: the press and release go to the view under the pointer.
        func clickView(_ identifier: String, modifiers: NSEvent.ModifierFlags = [], count: Int = 1) throws {
            let frame = try frame(of: .identifier(identifier))
            let location = NSPoint(x: frame.midX, y: frame.midY)
            for clicks in 1 ... count {
                try main { _ in
                    guard let window = Views.editorWindow,
                          let view = window.contentView?.superview?.hitTest(location) else {
                        throw ScenarioFailure("Nothing to click at \(identifier)")
                    }
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        guard let event = NSEvent.mouseEvent(
                            with: type, location: location, modifierFlags: modifiers,
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1,
                        ) else { continue }
                        if type == .leftMouseDown {
                            view.mouseDown(with: event)
                        } else {
                            view.mouseUp(with: event)
                        }
                    }
                }
                pause(0.05)
            }
        }

        /// The names of the selected photos, the active one, and the module, for checks.
        func selectionState() throws -> (photos: [String], active: String?) {
            try main { model in
                (model.selectedPhotos.map(\.lastPathComponent), model.selection?.lastPathComponent)
            }
        }
    }

    enum ModuleScenarios {
        static let all: [Scenario] = [switching, picker, grid, palette]

        static let switching = Scenario(
            "modules.switching",
            "G, E, C, N, D, ⌥⌘1, ⌥⌘2 and ⌥⌘↑ switch between Library and Develop, carrying the source, the "
                + "selection and the open photo",
            tiers: [.smoke, .full],
            claims: [
                .action(.gridView), .action(.loupeView), .action(.compareView), .action(.surveyView),
                .action(.libraryModule), .action(.developModule), .action(.previousModule), .action(.editTool),
            ],
        ) { app in
            try app.openWorking()
            try app.main { model in model.click(model.items[0].url, extending: true) }
            try app.settle()
            let state: @MainActor @Sendable (EditorModel) -> String = carried
            let before = try app.main(state)
            let open = try app.main { $0.info?.url }
            try app.press(.gridView)
            try app.wait("the Library grid") { $0.module == .library && $0.libraryView == .grid }
            try app.expect(try app.exists(.identifier("library.grid")), "The grid isn't on screen")
            try app.expect(try app.main(state) == before, "Library shows another source or selection")
            try app.expect(try app.main { $0.info?.url } == open, "Develop let go of its photo in Library")
            for action in [ShortcutAction.loupeView, .compareView, .surveyView] {
                try app.press(action)
                try app.wait("\(action.title): the loupe") { $0.module == .library && $0.libraryView == .loupe }
                try app.press(KeyCombo(.escape))
                try app.wait("Esc: the grid again") { $0.libraryView == .grid }
            }
            let compare = try app.menuItem(Menus.title(of: .compareView))
            try app.expect(compare.found && compare.enabled, "Compare's menu item isn't there")
            try app.expectKeyBinding(.developModule)
            try app.choose(.developModule)
            try app.wait("Develop") { $0.module == .develop }
            try app.expect(try app.main { $0.info?.url == open && $0.hasFrame }, "Develop didn't keep its photo open")
            try app.expect(try app.main(state) == before, "Develop shows another source or selection")
            try app.expectArrowKeyBinding(.previousModule)
            try app.choose(.previousModule)
            try app.wait("⌥⌘↑: Library again") { $0.module == .library }
            try app.press(.editTool)
            try app.wait("D: Develop, on the Edit tool") { $0.module == .develop && $0.activeTool == .edit }
            try app.expectKeyBinding(.libraryModule)
            try app.choose(.libraryModule)
            try app.wait("⌥⌘1: Library") { $0.module == .library }
            try app.choose(.developModule)
            try app.wait("Develop") { $0.module == .develop }
            try app.main { $0.deselectOtherPhotos() }
            try app.settle()
        }

        static let picker = Scenario(
            "modules.picker", "The toolbar's module picker switches between Library and Develop",
            claims: [.action(.libraryModule), .action(.developModule), .feature("workspace.toolbar")],
        ) { app in
            try app.openWorking()
            let mark = try app.mark()
            try app.clickView("module.library")
            try app.wait("the picker's Library") { $0.module == .library }
            try app.expectPerformed(.libraryModule, since: mark)
            app.covered(.action(.libraryModule), via: .mouse)
            try app.clickView("module.develop")
            try app.wait("the picker's Develop") { $0.module == .develop }
            try app.expectPerformed(.developModule, since: mark)
            app.covered([.action(.developModule), .feature("workspace.toolbar")], via: .mouse)
            try app.settle()
        }

        static let grid = Scenario(
            "modules.grid",
            "The Library grid: arrow keys, Home and End move, ⇧ extends; click, ⌘-click and ⇧-click select as "
                + "in the filmstrip; double-click and Return open the loupe; D opens the photo in Develop",
            claims: [.feature("library.filmstrip"), .feature("library.thumbnails")],
        ) { app in
            try app.openWorking()
            let names = try app.photoNames()
            try app.expect(names.count >= 6, "The folder has \(names.count) photos")
            try app.main { model in model.select(model.items[0].url) }
            try app.settle()
            try app.press(.gridView)
            try app.wait("the grid to take the keyboard") { _ in
                Views.editorWindow?.firstResponder.map { "\(type(of: $0))" } == "LibraryCollectionView"
            }
            try app.wait("the grid's cells") { _ in
                Views.editorWindow.flatMap { Views.find("grid.\(names[1])", in: $0) } != nil
            }

            try app.press(.nextPhoto)
            try app.expect(try app.selectionState().active == names[1], "→ didn't move to \(names[1])")
            try app.pressGridKey(kVK_RightArrow, characters: arrow(NSRightArrowFunctionKey), shift: true)
            var state = try app.selectionState()
            try app.expect(state.photos == [names[1], names[2]] && state.active == names[2], "⇧→ gave \(state)")
            try app.pressGridKey(kVK_Home, characters: arrow(NSHomeFunctionKey), shift: true)
            state = try app.selectionState()
            try app.expect(state.photos == [names[0], names[1]] && state.active == names[0], "⇧Home gave \(state)")
            try app.pressGridKey(kVK_End, characters: arrow(NSEndFunctionKey))
            state = try app.selectionState()
            try app.expect(state.photos == [names.last] && state.active == names.last, "End gave \(state)")
            try app.pressGridKey(kVK_UpArrow, characters: arrow(NSUpArrowFunctionKey))
            try app.pressGridKey(kVK_DownArrow, characters: arrow(NSDownArrowFunctionKey))
            state = try app.selectionState()
            try app.expect(state.active == names.last, "↑ then ↓ from the last photo gave \(state)")
            app.covered(.feature("library.filmstrip"), via: .key)

            try app.clickView("grid.\(names[1])")
            try app.expect(try app.selectionState().photos == [names[1]], "A click didn't select \(names[1]) alone")
            try app.clickView("grid.\(names[3])", modifiers: .command)
            state = try app.selectionState()
            try app.expect(state.photos == [names[1], names[3]] && state.active == names[3], "⌘-click gave \(state)")
            try app.clickView("grid.\(names[4])", modifiers: .shift)
            state = try app.selectionState()
            try app.expect(state.photos == Array(names[3 ... 4]) && state.active == names[4], "⇧-click gave \(state)")
            app.covered(.feature("library.filmstrip"), via: .mouse)

            try app.clickView("grid.\(names[2])", count: 2)
            try app.wait("double-click: the loupe") { $0.libraryView == .loupe }
            try app.expect(try app.selectionState().active == names[2], "The loupe shows another photo")
            try app.expect(try app.exists(.identifier("library.loupe")), "The loupe isn't on screen")
            try app.wait("the loupe's preview", timeout: 20) { model in
                model.selection.flatMap(model.previews.cached) != nil
            }
            try app.press(.gridView)
            try app.wait("G: the grid") { $0.libraryView == .grid }
            try app.wait("the grid to take the keyboard again") { _ in
                Views.editorWindow?.firstResponder.map { "\(type(of: $0))" } == "LibraryCollectionView"
            }
            try app.pressGridKey(kVK_Return, characters: "\r")
            try app.wait("Return: the loupe") { $0.libraryView == .loupe }
            try app.press(KeyCombo(.escape))
            try app.wait("Esc: the grid") { $0.libraryView == .grid }
            app.covered(.feature("library.thumbnails"), via: .mouse)

            try app.press(.editTool)
            let shown = try app.main { $0.module == .develop && ($0.hasFrame || $0.selectionThumbnail != nil) }
            try app.expect(shown, "Develop showed nothing while \(names[2]) opened")
            try app.wait("\(names[2]) open in Develop", timeout: 30) { model in
                model.info?.url.lastPathComponent == names[2] && model.hasFrame
            }
            try app.main { model in model.select(model.items[0].url) }
            try app.settle()
        }

        static let palette = Scenario(
            "modules.palette", "Library and Develop from the command palette",
            claims: [.action(.libraryModule), .action(.developModule), .feature("workspace.palette")],
        ) { app in
            try app.openWorking()
            try app.runFromPalette(.libraryModule)
            try app.wait("Library from the palette") { $0.module == .library }
            try app.runFromPalette(.developModule)
            try app.wait("Develop from the palette") { $0.module == .develop }
            app.covered(.feature("workspace.palette"), via: .palette)
            try app.settle()
        }

        private static func arrow(_ key: Int) -> String {
            UnicodeScalar(key).map(String.init) ?? ""
        }

        /// What carries across modules: the source, its photos in order, the selection and the active photo.
        @MainActor private static func carried(_ model: EditorModel) -> String {
            [
                model.folder?.path ?? "", "\(model.library.includesSubfolders)",
                model.items.map(\.url.lastPathComponent).joined(separator: ","),
                model.selectedPhotos.map(\.lastPathComponent).joined(separator: ","),
                model.selection?.lastPathComponent ?? "",
            ].joined(separator: " | ")
        }
    }
#endif
