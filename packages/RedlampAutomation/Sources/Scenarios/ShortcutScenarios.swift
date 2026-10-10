#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Carbon.HIToolbox
    import RedlampDocument
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    extension RunningApp {
        /// A key press with ⌃ as well, which the driver's own key presses don't carry, through the app's event
        /// handling as the keyboard's go.
        func pressWithControl(_ character: Character) throws {
            let code: UInt16 = try main { _ in
                guard let code = try? Keyboard.event(.char(character)).keyCode else {
                    throw ScenarioFailure("The keyboard layout has no key for \(character)")
                }
                return code
            }
            let event = try main { _ -> NSEvent in
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.control],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: EditorWindowController.frontWindow?.windowNumber ?? 0, context: nil,
                    characters: String(character), charactersIgnoringModifiers: String(character), isARepeat: false,
                    keyCode: code,
                ) else { throw ScenarioFailure("Couldn't make ⌃\(character)") }
                return event
            }
            post { _ in NSApp.sendEvent(event) }
            pause(0.1)
        }

        /// ⌘↵ in the palette's field, which reaches it as a key equivalent through the editor's window.
        func pressCommandReturnInPalette() throws {
            let taken = try main { _ -> Bool in
                guard let window = Views.editorWindow, let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.command],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: UInt16(kVK_Return),
                ) else { return false }
                return window.performKeyEquivalent(with: event)
            }
            try expect(taken, "⌘↵ didn't reach the palette's field")
            pause(0.15)
        }

        /// Records `combo` for `action` in Settings › Shortcuts: its row's recording started as a click on its key
        /// starts it (a click on a SwiftUI button in a list doesn't reach it from the driver), and the key pressed
        /// through the Settings window, as the keyboard's go.
        func recordKey(_ combo: KeyCombo, for action: ShortcutAction) throws {
            try main { _ in
                guard let editor = ShortcutEditor.shown
                else { throw ScenarioFailure("Settings › Shortcuts isn't shown") }
                editor.record(action)
            }
            try wait("\(action.title)'s key to be recorded") { _ in
                Self.settingsWindow?.firstResponder.map { "\(Swift.type(of: $0))" } == "KeyRecorderView"
            }
            try main { _ in
                guard let window = Self.settingsWindow else { throw ScenarioFailure("Settings isn't open") }
                var event = try Keyboard.event(combo)
                if event.windowNumber != window.windowNumber {
                    event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                        windowNumber: window.windowNumber, context: nil, characters: event.characters ?? "",
                        charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: false,
                        keyCode: event.keyCode,
                    ) ?? event
                }
                if combo.command {
                    _ = window.performKeyEquivalent(with: event)
                } else {
                    window.sendEvent(event)
                }
            }
            pause(0.3)
        }

        /// Chooses `preset` in Settings › Shortcuts' Keys From menu, as choosing it from the menu does.
        func choosePreset(_ preset: KeymapPreset) throws {
            try main { _ in
                guard let content = Self.settingsWindow?.contentView,
                      let popUp = Views.all(NSPopUpButton.self, in: content)
                      .first(where: { $0.itemTitles.contains(KeymapPreset.bridge.title) })
                else { throw ScenarioFailure("Settings › Shortcuts has no Keys From menu") }
                let index = popUp.indexOfItem(withTitle: preset.title)
                guard index >= 0, let menu = popUp.menu else {
                    throw ScenarioFailure("The Keys From menu has no \(preset.title): \(popUp.itemTitles)")
                }
                // As choosing the item in the open menu does: the item's action selects it and sends the menu's.
                menu.performActionForItem(at: index)
                if popUp.indexOfSelectedItem != index {
                    popUp.selectItem(at: index)
                    popUp.sendAction(popUp.action, to: popUp.target)
                }
            }
            pause(0.3)
        }
    }

    /// The keys as customised in Settings › Shortcuts (LIB-36), the menu bar's keys each reaching their own item, and
    /// the palette's commands run last, its actions on the selection and what else a row does on ⌘↵ (LIB-19).
    enum ShortcutScenarios {
        static let all: [Scenario] = [oneKeyEach, editor, paletteActions]

        /// The menu bar, in Library and in Develop, with each preset's keys: no two items have one key, no item with
        /// a key and ⇧ comes ahead of an action's item with the key (the driver's presses would reach it first, as ⌘R
        /// once ran Reset All Settings; a keyboard's reach the exact item, and the driver presses only the actions'
        /// keys), and every action the menus give a ⌘ key has an item that carries it.
        static let oneKeyEach = Scenario(
            "menus.one-key-each",
            "Every key in the menu bar reaches its own item, in Library and Develop, with each preset's keys",
            tiers: [.smoke, .full], claims: [.feature("workspace.shortcuts")],
        ) { app in
            try app.open(app.workingPhoto())
            defer {
                try? app.main { model in
                    ShortcutKeymap.shared.keymap = .standard
                    model.showModule(.develop)
                }
            }
            var failures: [String] = []
            for preset in KeymapPreset.allCases {
                try app.main { _ in ShortcutKeymap.shared.keymap = Keymap(preset: preset) }
                for module in AppModule.allCases {
                    try app.main { $0.showModule(module) }
                    app.pause(0.4)
                    let found = try app.main { _ -> [String] in
                        guard let bar = NSApp.mainMenu else { return ["no menu bar"] }
                        let items = MenuBarCollisions.items(in: bar) { menu in
                            Menus.open(menu)
                            Menus.close(menu)
                        }
                        let shown = Set(Menus.allTitles(in: bar).map { $0.components(separatedBy: " › ").last ?? $0 })
                        var titles: [String: ShortcutAction] = [:]
                        for action in ShortcutAction.allCases {
                            let title = Menus.title(of: action)
                            if shown.contains(title) || shown.contains(where: { $0.hasPrefix(title + "    ") }) {
                                titles[title] = action
                            }
                        }
                        let keymap = ShortcutKeymap.shared.keymap
                        let missing = MenuBarCollisions.keysNotCarried(
                            by: items, titles: titles, keymap: keymap, module: module,
                        )
                        let collisions = MenuBarCollisions.collisions(in: items).filter { collision in
                            collision.first.modifiers == collision.later
                                .modifiers || titles[collision.later.title] != nil
                        }
                        return collisions.map(\.description) + missing.map { action in
                            "\(action.title)'s item doesn't carry \(keymap.combos(for: action).first?.display ?? "")"
                        }
                    }
                    failures += found.map { "\(preset.title), \(module.title): \($0)" }
                }
            }
            try app.expect(failures.isEmpty, failures.joined(separator: "; "))
            app.covered([.feature("workspace.shortcuts")], via: .menu)
        }

        /// Settings › Shortcuts: a key no action has saved as it's pressed; a key Loupe has shown with it until it's
        /// taken; the key then runs Grid from the keyboard and the View menu shows it; Photo Mechanic's keys, asked
        /// about since keys were changed, rate with ⌃3.
        static let editor = Scenario(
            "shortcuts.editor",
            "Settings › Shortcuts records a key by pressing it, shows a key another action has before taking it, and "
                + "gives Photo Mechanic's keys, the keyboard and the menus following",
            claims: [.feature("workspace.shortcuts"), .feature("workspace.settings")],
        ) { app in
            let names = try app.showGrid()
            defer {
                try? app.main { _ in ShortcutKeymap.shared.keymap = .standard }
                try? app.closeSettings()
            }
            try app.main { _ in ShortcutKeymap.shared.keymap = .standard }
            try app.openSettings(tab: "Shortcuts")

            try app.recordKey(.char("g", shift: true), for: .gridView)
            try app.wait("⇧G saved as Grid's key") { _ in
                ShortcutKeymap.shared.keymap.combos(for: .gridView) == [.char("g", shift: true)]
            }

            try app.recordKey(.char("e"), for: .gridView)
            try app.wait("E, Loupe's key, shown with Loupe before anything is saved") { _ in
                ShortcutEditor.shown?.pending?.conflicts == [.taken(by: .loupeView)]
            }
            try app.expect(
                ShortcutKeymap.shared.keymap.combos(for: .loupeView) == [.char("e")],
                "E was taken before it was confirmed",
            )
            try app.main { _ in ShortcutEditor.shown?.confirm() }
            try app.wait("E taken from Loupe for Grid") { _ in
                let keymap = ShortcutKeymap.shared.keymap
                return keymap.combos(for: .gridView) == [.char("e")] && keymap.combos(for: .loupeView).isEmpty
            }
            try app.closeSettings()

            try app.main { $0.showLibrary(.loupe) }
            try app.press(.char("e"))
            try app.wait("E to show the grid") { $0.libraryView == .grid }
            let titles = try app.main { _ -> [String] in
                ["Grid", "Loupe"].map { title in
                    Menus.find(title).map { menu, index in menu.items[index].title } ?? "no item"
                }
            }
            try app.expect(titles == ["Grid    E", "Loupe"], "The View menu shows \(titles)")

            try app.openSettings(tab: "Shortcuts")
            try app.choosePreset(.photoMechanic)
            do {
                try app.wait("Photo Mechanic's keys to ask about the keys changed") { _ in
                    RunningApp.settingsWindow?.attachedSheet != nil
                }
            } catch {
                let shown = try app.main { _ -> String in
                    let windows = NSApp.windows.filter(\.isVisible).map { "\(Swift.type(of: $0)) “\($0.title)”" }
                    let keymap = ShortcutKeymap.shared.keymap
                    return "windows \(windows), keymap \(keymap.preset.title) with \(keymap.changes.count) changed"
                }
                throw ScenarioFailure("Choosing Photo Mechanic's keys over changed ones didn't ask: \(shown)")
            }
            try app.confirmInSettings("Photo Mechanic's keys, over the keys changed")
            try app.wait("Photo Mechanic's keys") { _ in
                ShortcutKeymap.shared.keymap == Keymap(preset: .photoMechanic)
            }
            try app.closeSettings()
            let photo = names[0]
            try app.main { model in
                if let url = model.items.first(where: { $0.url.lastPathComponent == photo })?.url {
                    model.select(url)
                }
            }
            try app.pressWithControl("3")
            try app.wait("⌃3 to give \(photo) three stars", timeout: 10) { model in
                model.items.first { $0.url.lastPathComponent == photo }?.metadata.rating == 3
            }
            try app.pressWithControl("0")
            try app.wait("⌃0 to clear them", timeout: 10) { model in
                model.items.first { $0.url.lastPathComponent == photo }?.metadata.rating == 0
            }
            app.covered([.feature("workspace.shortcuts"), .feature("workspace.settings")], via: .key)
        }

        /// The palette in Library: what can be done to the photos selected listed first and run on all of them, the
        /// command run listed first next time, and ⌘↵ on a folder revealing it and on a photo opening it in Develop.
        static let paletteActions = Scenario(
            "library.palette-actions",
            "⌘K lists what can be done to the photos selected and runs it on all of them, lists it first next time, "
                + "and ⌘↵ on a folder or a photo offers what else it can do",
            claims: [.feature("workspace.palette")],
        ) { app in
            let scratch = try SourcesScratch(app, photos: ["Tram.jpg", "Ferry.jpg", "Portrait.jpg"])
            defer { app.removeScratch(scratch) }
            try scratch.index(app)
            try app.main { $0.libraryViews.revealInFinder = { Revealed.photos.append(contentsOf: $0) } }
            defer {
                try? app.main { model in
                    model.libraryViews.revealInFinder = Revealed.finder
                    model.showModule(.develop)
                }
            }
            try app.main { $0.selectAllPhotos() }
            try app.wait("the three photos selected") { $0.selectedCount == 3 }

            try app.press(.commandPalette)
            try app.wait("the palette") { $0.commandPalette != nil }
            let selection = try app.main { $0.commandPalette?.sections.first }
            try app.expect(
                selection?.title == "Selection · 3 photos",
                "The first section is \(selection?.title ?? "none")",
            )
            guard let twoStars = selection?.items.first(where: { $0.kind == .action(.rating2) }) else {
                throw ScenarioFailure("2 Stars isn't among the selection's actions")
            }
            try app.choosePaletteRow(twoStars)
            try app.wait("two stars on the three photos", timeout: 10) { model in
                model.items.count == 3 && model.items.allSatisfy { $0.metadata.rating == 2 }
            }

            try app.press(.commandPalette)
            try app.wait("the palette") { $0.commandPalette != nil }
            let recent = try app.main { $0.commandPalette?.sections.first }
            try app.expect(
                recent?.title == "Recent" && recent?.items.first?.kind == .action(.rating2),
                "The first section is \(recent?.title ?? "none"): \(recent?.items.map(\.title) ?? [])",
            )

            let name = scratch.folder.lastPathComponent
            guard let folder = try app.searchPalette(name).first(where: {
                if case let .libraryName(.folder, path) = $0.kind {
                    return path.hasSuffix("/" + name)
                }
                return false
            }) else { throw ScenarioFailure("The folder isn't found by its name, \(name)") }
            let index = try app.main { $0.commandPalette?.rows.firstIndex(of: folder) ?? -1 }
            for _ in 0 ..< index {
                try app.paletteKey(.down)
            }
            try app.pressCommandReturnInPalette()
            let actions = try app.main { $0.commandPalette?.rows.map(\.kind) ?? [] }
            try app.expect(
                actions == [.rowAction(.primary), .rowAction(.revealInFinder)], "⌘↵ on the folder lists \(actions)",
            )
            try app.paletteKey(.down)
            try app.paletteKey(.submit)
            try app.wait("the folder revealed in Finder") { _ in Revealed.photos.last?.lastPathComponent == name }

            try app.press(.commandPalette)
            try app.wait("the palette") { $0.commandPalette != nil }
            guard let portrait = try app.searchPalette("portrait").first(where: { $0.title == "Portrait.jpg" }) else {
                throw ScenarioFailure("Portrait.jpg isn't found by its name")
            }
            let row = try app.main { $0.commandPalette?.rows.firstIndex(of: portrait) ?? -1 }
            for _ in 0 ..< row {
                try app.paletteKey(.down)
            }
            try app.pressCommandReturnInPalette()
            guard let develop = try app
                .main({ $0.commandPalette?.rows.first { $0.kind == .rowAction(.openInDevelop) } })
            else { throw ScenarioFailure("⌘↵ on Portrait.jpg doesn't offer Open in Develop") }
            try app.choosePaletteRow(develop)
            try app.wait("Portrait.jpg open in Develop") { model in
                model.module == .develop && model.selection?.lastPathComponent == "Portrait.jpg"
            }
            app.covered([.feature("workspace.palette")], via: .key)
        }
    }
#endif
