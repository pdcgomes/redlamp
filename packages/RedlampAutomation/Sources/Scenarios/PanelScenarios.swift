#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDocument
    import RedlampEngineAPI
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    extension RunningApp {
        /// Runs `body` on the working folder's grid, shown from the library, with the right column and its
        /// panels open; then takes back what's left of its changes and goes back to Develop, also when it fails.
        func withPanels(_ body: ([String]) throws -> Void) throws {
            let names = try showGrid()
            try wait("the folder shown from the library", timeout: 90) { $0.library.isShownFromLibrary }
            let depth = try main { model in
                if !model.rightPanelVisible {
                    model.rightPanelVisible = true
                }
                for panel in LibraryPanels.Panel.allCases where !model.libraryPanels.isExpanded(panel) {
                    model.libraryPanels.toggle(panel)
                }
                return model.libraryPanels.undoCount
            }
            try wait("the keyword list", timeout: 30) { $0.libraryPanels.keywordList != nil }
            // The column slides in.
            pause(0.6)
            do {
                try body(names)
            } catch {
                try? takeBackPanels(to: depth)
                throw error
            }
            try takeBackPanels(to: depth)
        }

        /// The panels' changes taken back until `depth` are left, and Develop again.
        func takeBackPanels(to depth: Int) throws {
            try waitForPanels()
            try main { model in
                model.showModule(.library)
                while model.libraryPanels.undoCount > depth, model.libraryPanels.undoInLibrary() == true {}
            }
            try waitForPanels()
            try main { $0.libraryFilters?.setFilter(LibraryFilter()) }
            try backToDevelop()
        }

        /// Until every change the panels asked for is made and shown.
        func waitForPanels(timeout: Double = 60) throws {
            try run("the panels' changes to be made", timeout: timeout) { model in
                await model.libraryPanels.written()
                await model.library.service?.settled()
                await model.libraryPanels.refreshed()
                await model.libraryPanels.keywordsRead()
            }
        }

        /// The keywords `name`'s sidecar holds, sorted.
        func sidecarKeywords(_ name: String) throws -> [String] {
            let url = try main { model in model.items.first { $0.url.lastPathComponent == name }?.url }
            guard let url else { throw ScenarioFailure("\(name) isn't shown") }
            return try main { model in
                (model.library.sidecars.store(for: url).load(for: url)?.metadata?.keywords ?? []).sorted()
            }
        }

        func sidecarMetadata(_ name: String) throws -> PhotoMetadata? {
            let url = try main { model in model.items.first { $0.url.lastPathComponent == name }?.url }
            guard let url else { throw ScenarioFailure("\(name) isn't shown") }
            return try main { model in model.library.sidecars.store(for: url).load(for: url)?.metadata }
        }

        /// The `metadata` object of `name`'s sidecar as its file holds it, key for key; nil when it holds none.
        func writtenMetadata(_ name: String) throws -> [String: JSONValue]? {
            let url = try main { model in model.items.first { $0.url.lastPathComponent == name }?.url }
            guard let url else { throw ScenarioFailure("\(name) isn't shown") }
            let edit = try main { model in model.library.sidecars.store(for: url).editURL(for: url) }
            guard let data = try? Data(contentsOf: edit) else { return nil }
            guard case let .object(sidecar) = try JSONDecoder().decode(JSONValue.self, from: data),
                  case let .object(metadata)? = sidecar["metadata"]
            else { return nil }
            return metadata
        }

        /// Clicks the AppKit control carrying `identifier` (a button, a checkbox, a text field) in the editor window,
        /// or in the sheet in front of it, as the mouse does: the release waits in the queue, where a control that
        /// tracks the press takes it from, and in a window that isn't key the press goes to the control under the
        /// pointer, as the click after activation would.
        func clickControl(_ identifier: String, inSheet: Bool = false, across: CGFloat = 0.5) throws {
            @MainActor func window() -> NSWindow? {
                inSheet ? NSApp.modalWindow ?? Views.editorWindow?.attachedSheet : Views.editorWindow
            }
            let location = try main { _ -> NSPoint in
                guard let window = window(), let root = window.contentView?.superview ?? window.contentView,
                      let view = Views.all(NSView.self, in: root).first(where: {
                          $0.accessibilityIdentifier() == identifier && !$0.isHiddenOrHasHiddenAncestor
                              && $0.alphaValue > 0
                      })
                else { throw ScenarioFailure("\(identifier) isn't on screen") }
                view.scrollToVisible(view.bounds)
                window.contentView?.layoutSubtreeIfNeeded()
                let frame = view.convert(view.bounds, to: nil)
                return NSPoint(x: frame.minX + frame.width * across, y: frame.midY)
            }
            post { _ in
                guard let window = window() else { return }
                let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap { type in
                    NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1,
                    )
                }
                guard events.count == 2 else { return }
                NSApp.postEvent(events[1], atStart: false)
                let hit = window.contentView?.superview?.hitTest(location) ?? window.contentView?.hitTest(location)
                if window.isKeyWindow || hit?.acceptsFirstMouse(for: events[0]) == true {
                    window.sendEvent(events[0])
                } else {
                    hit?.mouseDown(with: events[0])
                }
            }
            pause(0.2)
        }

        /// The text of the field `identifier` in the sheet in front replaced by `text`, as typing does: a click past
        /// its text (`across` its width), the keys that delete what's there, then the keys of `text`.
        func replaceInSheet(_ identifier: String, with text: String, across: CGFloat = 0.8) throws {
            try clickControl(identifier, inSheet: true, across: across)
            let length = try main { _ -> Int in
                let sheet = NSApp.modalWindow ?? Views.editorWindow?.attachedSheet
                return ((sheet?.firstResponder as? NSTextView)?.string as NSString?)?.length ?? 0
            }
            for _ in 0 ..< length {
                let event = try main { _ in try Keyboard.event(KeyCombo(.delete)) }
                post { _ in (NSApp.modalWindow ?? Views.editorWindow?.attachedSheet)?.sendEvent(event) }
                pause(0.02)
            }
            try typeInSheet(text)
            let typed = try main { _ -> String? in
                let sheet = NSApp.modalWindow ?? Views.editorWindow?.attachedSheet
                return (sheet?.firstResponder as? NSTextView)?.string
            }
            try expect(typed == text, "\(identifier) holds \(typed ?? "nothing"), not \(text)")
        }

        /// Presses the button or checkbox `identifier` in the sheet in front, as a click on it does (its cell's own
        /// press): a sheet of an app in the background isn't key, and its buttons take no press then.
        func pressInSheet(_ identifier: String) throws {
            try main { _ in
                guard let sheet = NSApp.modalWindow ?? Views.editorWindow?.attachedSheet,
                      let content = sheet.contentView,
                      let button = Views.all(NSButton.self, in: content).first(where: {
                          $0.accessibilityIdentifier() == identifier
                      })
                else { throw ScenarioFailure("\(identifier) isn't in the sheet") }
                button.performClick(nil)
            }
            pause(0.1)
        }

        /// Chooses `title` in the sheet's pop-up button `identifier`, as a click in its menu does.
        func chooseInSheet(_ title: String, inPopUp identifier: String) throws {
            try main { _ in
                guard let sheet = NSApp.modalWindow ?? Views.editorWindow?.attachedSheet,
                      let content = sheet.contentView,
                      let button = Views.all(NSPopUpButton.self, in: content)
                      .first(where: { $0.accessibilityIdentifier() == identifier })
                else { throw ScenarioFailure("\(identifier) isn't in the sheet") }
                guard let index = button.menu?.items.firstIndex(where: { $0.title == title }) else {
                    throw ScenarioFailure("\(identifier) has no \(title)")
                }
                button.menu?.performActionForItem(at: index)
                button.selectItem(at: index)
            }
            pause(0.1)
        }

        /// The sheet's default button, pressed.
        func confirmSheet(_ title: String) throws {
            step("confirming \(title)")
            try pressInSheet("panelSheet.ok")
            try waitForNoSheet(title)
        }

        /// Makes the keyword list's row of `path` the one chosen, as a click on it does.
        func chooseKeywordRow(_ path: String) throws {
            @MainActor func found() -> (NSOutlineView, Int)? {
                guard let window = Views.editorWindow, let root = window.contentView?.superview,
                      let outline = Views.all(NSOutlineView.self, in: root)
                      .first(where: { $0.accessibilityIdentifier() == "keywordList.outline" }),
                      let row = Views.all(NSView.self, in: outline)
                      .first(where: { $0.accessibilityIdentifier() == "keywordList.row.\(path)" })
                      .map(outline.row(for:)), row >= 0
                else { return nil }
                return (outline, row)
            }
            // The outline makes a row's view as it's laid out, a moment after its keyword arrives.
            try wait("\(path) in the keyword list") { _ in found() != nil }
            try main { _ in
                guard let (outline, row) = found() else { throw ScenarioFailure("\(path) isn't in the keyword list") }
                outline.selectRowIndexes([row], byExtendingSelection: false)
            }
        }

        /// Notes where a scenario has got to, for the run's events.
        func step(_ what: String) {
            recorder.write("note", ["step": what])
        }

        /// The panels' last problem and the activity log's last errors, for a failure's message.
        func panelErrors() -> String {
            (try? main { model in
                let errors = model.activity.events.filter { $0.kind == .error }.suffix(3).map(\.text)
                return ([model.libraryPanels.problem].compactMap(\.self) + errors).joined(separator: "; ")
            }) ?? ""
        }

        /// Clicks the text field `identifier` and types `text` into it, then Return.
        func typeInField(_ identifier: String, _ text: String, returning: Bool = true) throws {
            @MainActor func editing() -> Bool {
                (Views.editorWindow?.firstResponder as? NSTextView)?.delegate.map { delegate in
                    (delegate as? NSView)?.accessibilityIdentifier() == identifier
                } ?? false
            }
            try clickControl(identifier)
            // A click while the column still lays out can miss the field: once more.
            if (try? wait("\(identifier) to take the keyboard", timeout: 4) { _ in editing() }) == nil {
                try clickControl(identifier)
                try wait("\(identifier) to take the keyboard") { _ in editing() }
            }
            try typeQuery(text)
            if returning {
                try pressInWindow(KeyCombo(.character("\r")))
            }
        }

        /// Types `text` into the sheet in front, where its first responder takes it.
        func typeInSheet(_ text: String) throws {
            for character in text {
                let event = try main { _ -> NSEvent in
                    try Keyboard.hasKey(for: character) ? Keyboard.event(KeyCombo(.character(character)))
                        : Keyboard.shifted(character)
                }
                post { _ in
                    (NSApp.modalWindow ?? Views.editorWindow?.attachedSheet)?.sendEvent(event)
                }
                pause(0.03)
            }
        }

        /// Chooses `title` in the pop-up or pull-down button `identifier`, as a click in its menu does.
        func choose(_ title: String, inMenuOf identifier: String) throws {
            try main { _ in
                guard let window = Views.editorWindow, let root = window.contentView?.superview,
                      let button = Views.all(NSPopUpButton.self, in: root)
                      .first(where: { $0.accessibilityIdentifier() == identifier })
                else { throw ScenarioFailure("\(identifier) isn't on screen") }
                guard let index = button.menu?.items.firstIndex(where: { $0.title == title }) else {
                    throw ScenarioFailure("\(identifier) has no \(title): \(button.itemTitles)")
                }
                button.menu?.performActionForItem(at: index)
            }
            pause(0.1)
        }
    }

    enum PanelScenarios {
        static let all: [Scenario] = [column, keywording, keywordList, metadata, captureTime]

        static let column = Scenario(
            "library.panel-column",
            "Library's right column shows and hides from F8 and View ▸ Show / Hide Right Panel (⌥⌘→); its Keywording, "
                + "Keyword List and Metadata panels open and close from their headers",
            tiers: [.smoke, .full],
            claims: [.action(.toggleRightPanel), .feature("library.keywords"), .feature("library.metadata")],
        ) { app in
            try app.withPanels { _ in
                try app.expect(try app.exists(.identifier("library.keywording.header")), "the Keywording panel")
                try app.press(.toggleRightPanel)
                try app.wait("F8 to hide the right column") { !$0.rightPanelVisible }
                // The column slides out; its split view writes what it ends as back to the model.
                app.pause(1)
                let binding = try app.main { _ -> (String, NSEvent.ModifierFlags)? in
                    guard let (menu, index) = Menus.find(ShortcutAction.toggleRightPanel.title) else { return nil }
                    let item = menu.items[index]
                    return (item.keyEquivalent, item.keyEquivalentModifierMask)
                }
                try app.expect(binding?.0 == String(UnicodeScalar(NSRightArrowFunctionKey)!), "⌥⌘→ on its menu item")
                try app.expect(
                    binding?.1.intersection([.command, .option, .shift, .control]) == [.command, .option],
                    "⌥⌘→'s modifiers",
                )
                try app.choose(.toggleRightPanel)
                try app.wait("the menu item to show it again") { $0.rightPanelVisible }
                // The column slides in.
                app.pause(0.8)
                app.covered(.action(.toggleRightPanel), via: .binding)
                for panel in [LibraryPanels.Panel.keywordList, .metadata] {
                    try app.click(.identifier("library.\(panel.rawValue).header"))
                    try app.wait("\(panel.title) closed") { !$0.libraryPanels.isExpanded(panel) }
                    try app.click(.identifier("library.\(panel.rawValue).header"))
                    try app.wait("\(panel.title) open") { $0.libraryPanels.isExpanded(panel) }
                }
                app.covered([.feature("library.keywords"), .feature("library.metadata")], via: .mouse)
            }
        }

        static let keywording = Scenario(
            "library.keywording",
            "Keywords typed in the Keywording panel, completed from the library's, reach every photo selected as one "
                + "change kept in their sidecars; ⊖ takes one off; ⌘Z and ⇧⌘Z take it back and make it again; the "
                + "keyword set chosen in the Photo menu, ⌥1 to ⌥9 toggle its keywords",
            tiers: [.smoke, .full],
            claims: [.feature("library.keywords"), .action(.undo), .action(.redo)]
                + ShortcutAction.allCases.filter { $0.keywordSetNumber != nil }.map(Claim.action),
        ) { app in
            try app.withPanels { _ in
                // The grid's first three cells, a raw and its JPEG's photos together, and the cell after them.
                let cells = try app.selectFromKeyboard(3)
                let three = Array(cells.prefix(3).joined())
                try app.wait("the panel on the three cells' photos") { model in
                    model.libraryPanels.selection.ids.count == three.count
                }
                try app.typeInField("keywording.entry", "E2E Lisbon, E2E Trips > 2007")
                try app.wait("the keywords on the three, shown") { model in
                    model.libraryPanels.selection.hasEverywhere(KeywordPath("E2E Trips/2007")!) == true
                }
                try app.waitForPanels()
                for name in three {
                    try app.expect(
                        try app.sidecarKeywords(name).contains("E2E Trips/2007"), "\(name)'s sidecar has the keyword",
                    )
                }
                try app.expect(
                    try !app.sidecarKeywords(cells[3][0]).contains("E2E Lisbon"), "the fourth cell's photo has none",
                )
                // Completion from the library's keywords, by a word of the name.
                try app.typeInField("keywording.entry", "lisb", returning: false)
                try app.wait("Lisbon offered") { model in
                    model.libraryPanels.completions("lisb").contains { $0.path.text == "E2E Lisbon" }
                }
                try app.clickControl("keywording.completion.0")
                try app.waitForPanels()
                try app.clickControl("keywording.remove.E2E Trips/2007")
                try app.wait("⊖ to take it off") { model in
                    model.libraryPanels.selection.hasEverywhere(KeywordPath("E2E Trips/2007")!) == false
                }
                try app.waitForPanels()
                try app.expect(try !app.sidecarKeywords(three[0]).contains("E2E Trips/2007"), "taken off the sidecar")
                try app.press(.undo)
                try app.waitForPanels()
                try app.expect(try app.sidecarKeywords(cells[1][0]).contains("E2E Trips/2007"), "⌘Z put it back")
                try app.expectKeyBinding(.redo)
                try app.choose(.redo)
                try app.waitForPanels()
                try app.expect(
                    try !app.sidecarKeywords(cells[1][0]).contains("E2E Trips/2007"), "⇧⌘Z took it off again",
                )
                app.covered([.action(.undo), .action(.redo)], via: .key)

                try app.choose("Wedding Photography")
                try app.wait("the wedding set chosen") { $0.libraryPanels.activeSet?.name == "Wedding Photography" }
                for action in ShortcutAction.allCases where action.keywordSetNumber != nil {
                    let keyword = try app.main { model in
                        model.libraryPanels.activeSet?.keyword(forShortcut: action.keywordSetNumber ?? 0)
                    }
                    guard let keyword else { throw ScenarioFailure("\(action.title) has no keyword") }
                    try app.press(action)
                    try app.wait("\(action.combos[0].display) to put \(keyword.name) on the three") { model in
                        model.libraryPanels.selection.hasEverywhere(keyword) == true
                    }
                    try app.press(action)
                    try app.wait("\(action.combos[0].display) again to take it off") { model in
                        model.libraryPanels.selection.hasEverywhere(keyword) == false
                    }
                }
                try app.waitForPanels()
                try app.clickControl("keywording.set.1")
                try app.wait("the set's first button to put Bride on") { model in
                    model.libraryPanels.selection.hasEverywhere(KeywordPath("Bride")!) == true
                }
                try app.waitForPanels()
                try app.expect(try app.sidecarKeywords(cells[2][0]).contains("Bride"), "the button's keyword saved")
                try app.choose(KeywordSet.recentName)
                try app.wait("Recent Keywords again") { $0.libraryPanels.activeSet?.name == KeywordSet.recentName }
                app.covered(.feature("library.keywords"), via: .key)
            }
        }

        static let keywordList = Scenario(
            "library.keyword-list",
            "The Keyword List counts keywords by hierarchy and filters them by name; a row's checkbox puts its keyword "
                + "on the photos selected; its arrow shows its photos through the filter bar; the row chosen is "
                + "edited, merged into another and deleted from the panel's menu; File ▸ Import Keywords… and Export "
                + "Keywords… read and write Lightroom Classic's keyword-list file",
            claims: [.feature("library.keywords"), .action(.importKeywords), .action(.exportKeywords)],
        ) { app in
            let file = app.runDirectory.appending(path: "keywords-in.txt")
            let exported = app.runDirectory.appending(path: "keywords-out.txt")
            try "E2E Animals\n\tE2E Birds\n\t\t{E2E Aves}\n\tE2E Cats\n".write(
                to: file,
                atomically: true,
                encoding: .utf8,
            )
            try app.main { _ in KeywordFiles.choosing = { $0 ? exported : file } }
            defer { try? app.main { _ in KeywordFiles.choosing = nil } }
            try app.withPanels { names in
                app.step("importing")
                try app.choose(.importKeywords)
                try app.wait("the file's keywords in the list", timeout: 20) { model in
                    model.libraryPanels.keywordList?[KeywordPath("E2E Animals/E2E Birds")!]?.options.synonyms
                        == ["E2E Aves"]
                }
                app.step("filtering")
                try app.typeInField("keywordList.filter", "E2E", returning: false)
                try app.wait("the filter to keep the birds") { _ in
                    Views.editorWindow.flatMap { Views.find("keywordList.row.E2E Animals/E2E Birds", in: $0) } != nil
                }
                try app.selectFromKeyboard(2)
                try app.wait("the panel on the two") { $0.libraryPanels.selection.ids.count == 2 }
                app.step("checking")
                try app.clickControl("keywordList.check.E2E Animals/E2E Birds")
                try app.wait("the checkbox to put it on the two") { model in
                    model.libraryPanels.selection.hasEverywhere(KeywordPath("E2E Animals/E2E Birds")!) == true
                }
                try app.waitForPanels()
                try app.expect(
                    try app.sidecarKeywords(names[1]) == ["E2E Animals/E2E Birds"]
                        || app.sidecarKeywords(names[1]).contains("E2E Animals/E2E Birds"),
                    "kept in the sidecar",
                )
                try app.wait("its count") { model in
                    model.libraryPanels.keywordList?[KeywordPath("E2E Animals")!]?.count == 2
                }
                app.step("showing")
                try app.clickControl("keywordList.show.E2E Animals/E2E Birds")
                try app.wait("the arrow to show its two photos through the filter", timeout: 20) { model in
                    model.libraryFilters?.filter.text.contains("E2E Birds") == true && model.items.count == 2
                }
                try app.main { $0.libraryFilters?.setFilter(LibraryFilter()) }
                try app.wait("every photo again", timeout: 20) { $0.items.count == names.count }

                app.step("editing")
                try app.chooseKeywordRow("E2E Animals/E2E Birds")
                try app.choose("Edit Keyword…", inMenuOf: "keywordList.more")
                app.step("the menu chosen")
                try app.waitForSheet("Edit Keyword")
                app.step("the sheet up")
                try app.replaceInSheet("editKeyword.name", with: "E2E Sparrows")
                try app.pressInSheet("editKeyword.export")
                try app.confirmSheet("Edit Keyword")
                try app.waitForPanels()
                try app.expect(
                    try app.sidecarKeywords(names[0]).contains("E2E Animals/E2E Sparrows"), "renamed in the sidecars",
                )
                try app.expect(try app.main { model in
                    model.libraryPanels.keywordList?[KeywordPath("E2E Animals/E2E Sparrows")!]?.options.includeOnExport
                } == false, "Include on Export off")

                app.step("merging")
                try app.chooseKeywordRow("E2E Animals/E2E Sparrows")
                try app.choose("Merge Into…", inMenuOf: "keywordList.more")
                try app.waitForSheet("Merge Keyword")
                try app.replaceInSheet("mergeKeyword.target", with: "E2E Animals/E2E Cats")
                try app.confirmSheet("Merge Keyword")
                try app.waitForPanels()
                try app.expect(
                    try app.sidecarKeywords(names[1]).contains("E2E Animals/E2E Cats"), "merged into Cats",
                )

                app.step("exporting")
                try app.choose(.exportKeywords)
                try app.wait("the list exported", timeout: 20) { _ in
                    (try? String(contentsOf: exported, encoding: .utf8))?.contains("E2E Animals\n\tE2E Cats\n") == true
                }
                try app.chooseKeywordRow("E2E Animals")
                try app.choose("Delete Keyword", inMenuOf: "keywordList.more")
                try app.waitForPanels()
                try app.expect(
                    try !app.sidecarKeywords(names[1]).contains("E2E Animals/E2E Cats"),
                    "deleted everywhere",
                )
                try app.expect(
                    try app.main { $0.libraryPanels.keywordList?[KeywordPath("E2E Animals")!] } == nil,
                    "out of the list",
                )
                app.covered([.action(.importKeywords), .action(.exportKeywords)], via: .menu)
                app.covered(.feature("library.keywords"), via: .mouse)

                // The scenarios after this one find the list unfiltered: E2E deleted, the caret past it.
                try app.clickControl("keywordList.filter")
                for _ in 0 ..< 3 {
                    try app.pressInWindow(KeyCombo(.delete))
                }
                try app.wait("the filter emptied") { _ in
                    guard let root = Views.editorWindow?.contentView?.superview else { return false }
                    return Views.all(NSTextField.self, in: root)
                        .first { $0.accessibilityIdentifier() == "keywordList.filter" }?.stringValue.isEmpty == true
                }
            }
        }

        static let metadata = Scenario(
            "library.metadata",
            "The Metadata panel shows the photos selected's IPTC Core fields, mixed where they differ; a field typed "
                + "reaches every photo as one change kept in their sidecars, with Undo; a preset made in Metadata "
                + "Presets… gives its ticked fields, appending or replacing; a code typed in Code Replacements… "
                + "expands in a field; the panels follow the selection in a collection as in a folder",
            claims: [.feature("library.metadata"), .feature("library.collections")],
        ) { app in
            try app.withPanels { names in
                try app.selectFromKeyboard(1)
                try app.typeInField("metadata.caption", "E2E first")
                try app
                    .wait("the caption on the photo") {
                        $0.libraryPanels.selection.fields[.caption] == .same("E2E first")
                    }
                try app.waitForPanels()
                try app.selectFromKeyboard(2)
                try app.wait("two photos' captions, mixed") { $0.libraryPanels.selection.fields[.caption] == .mixed }
                try app.typeInField("metadata.title", "E2E Lisbon in June")
                try app.wait("the title on both") { model in
                    model.libraryPanels.selection.fields[.title] == .same("E2E Lisbon in June")
                }
                try app.waitForPanels()
                try app.expect(try app.sidecarMetadata(names[1])?.title == "E2E Lisbon in June", "kept in the sidecar")
                try app.press(.undo)
                try app.waitForPanels()
                try app.expect(try app.sidecarMetadata(names[1])?.title == nil, "⌘Z took it back")

                try app.choose("Edit Presets…", inMenuOf: "metadata.presets")
                try app.waitForSheet("Metadata Presets")
                try app.replaceInSheet("presets.name", with: "E2E Chapel")
                try app.pressInSheet("presets.caption.tick")
                try app.replaceInSheet("presets.caption", with: "at the chapel")
                try app.main { _ in
                    guard let sheet = Views.editorWindow?.attachedSheet, let content = sheet.contentView else { return }
                    let mode = Views.all(NSPopUpButton.self, in: content)
                        .first { $0.accessibilityIdentifier() == "presets.caption.mode" }
                    mode?.selectItem(withTitle: "Append")
                }
                try app.confirmSheet("Metadata Presets")
                try app.wait("the preset kept") { $0.libraryPanels.presets.contains { $0.name == "E2E Chapel" } }
                try app.choose("E2E Chapel", inMenuOf: "metadata.presets")
                try app.waitForPanels()
                try app.expect(
                    try app.sidecarMetadata(names[0])?.caption == "E2E first at the chapel", "the caption appended to",
                )
                try app.expect(
                    try app.sidecarMetadata(names[1])?.caption == "at the chapel",
                    "and given where none was",
                )
                try app.press(.undo)
                try app.waitForPanels()
                try app.expect(try app.sidecarMetadata(names[0])?.caption == "E2E first", "⌘Z took the preset back")
                try app.run("the preset removed") { _ = await $0.libraryPanels.deletePreset(named: "E2E Chapel") }

                let codes = try app.main { $0.libraryPanels.codeReplacementsText }
                try app.choose("Edit Code Replacements…", inMenuOf: "metadata.presets")
                try app.waitForSheet("Code Replacements")
                try app.replaceInSheet("codes.text", with: "e2ecity\tE2E Sintra", across: 0.5)
                try app.confirmSheet("Code Replacements")
                try app.wait("the code kept") { $0.libraryPanels.codes.codes["e2ecity"] == ["E2E Sintra"] }
                let place = try app.sidecarMetadata(names[0])?.location
                try app.typeInField("metadata.city", #"\e2ecity\"#)
                try app.wait("the code expanded in the city") { model in
                    model.libraryPanels.selection.fields[.city] == .same("E2E Sintra")
                }
                try app.waitForPanels()
                try app.expect(
                    try app.sidecarMetadata(names[0])?.location?.city == "E2E Sintra",
                    "the city kept, its code expanded",
                )
                try app.press(.undo)
                try app.waitForPanels()
                try app.expect(try app.sidecarMetadata(names[0])?.location == place, "⌘Z took the city back")
                try app.run("the code replacements as they were") {
                    _ = await $0.libraryPanels.saveCodeReplacements(codes)
                }
                app.covered(.feature("library.metadata"), via: .key)
            }

            // A collection's photos selected from the keyboard: a title typed reaches both, and ⌘Z takes it back.
            try app.withCollection(of: ["A.jpg", "B.jpg", "C.jpg"]) { _, _ in
                try app.main { model in
                    model.rightPanelVisible = true
                    if !model.libraryPanels.isExpanded(.metadata) {
                        model.libraryPanels.toggle(.metadata)
                    }
                }
                // The column slides in.
                app.pause(0.6)
                try app.selectFromKeyboard(2)
                try app.wait("the panels on the collection's two photos") { model in
                    model.libraryPanels.selection.isAvailable && model.libraryPanels.selection.ids.count == 2
                }
                let selected = try app.main { $0.selectedPhotos.map(\.lastPathComponent) }
                try app.typeInField("metadata.title", "E2E Collection")
                try app.wait("the title on both") { model in
                    model.libraryPanels.selection.fields[.title] == .same("E2E Collection")
                }
                try app.waitForPanels()
                for name in selected {
                    try app.expect(try app.sidecarMetadata(name)?.title == "E2E Collection", "\(name) kept the title")
                }
                try app.press(.undo)
                try app.waitForPanels()
                for name in selected {
                    try app.expect(try app.sidecarMetadata(name)?.title == nil, "⌘Z took \(name)'s title back")
                }
                app.covered([.feature("library.metadata"), .feature("library.collections")], via: .key)
            }
        }

        static let captureTime = Scenario(
            "library.capture-time",
            "Photo ▸ Edit Capture Time… shifts the capture times of the photos selected and gives their camera a time "
                + "zone, kept in their sidecars and shown in the Metadata panel, each with Undo",
            claims: [.action(.editCaptureTime), .feature("library.metadata")],
        ) { app in
            try app.withPanels { names in
                let dated = try app.main { model in
                    model.items.firstIndex { ["arw", "raf", "cr3", "nef"].contains($0.url.pathExtension.lowercased()) }
                } ?? 0
                try app.click(.identifier("grid.\(names[dated])"))
                try app.wait("\(names[dated]) alone, with its capture time") { model in
                    model.libraryPanels.selection.ids.count == 1 && model.libraryPanels.selection.fields.captured != nil
                }
                try app.wait("\(names[dated]) open in Develop") { model in
                    model.info != nil && model.selection?.lastPathComponent == names[dated]
                }
                let before = try app.main { $0.libraryPanels.selection.fields.captured?.lowerBound }
                let written = try app.writtenMetadata(names[dated])
                try app.choose(.editCaptureTime)
                try app.waitForSheet("Edit Capture Time")
                try app.replaceInSheet("captureTime.hours", with: "2", across: 0.97)
                try app.confirmSheet("Edit Capture Time")
                try app.waitForPanels()
                try app.expect(try app.sidecarMetadata(names[dated])?.captureShift == 7200, "shifted by two hours")
                let after = try app.main { $0.libraryPanels.selection.fields.captured?.lowerBound }
                try app.expect(
                    after.flatMap { after in before.map { after.timeIntervalSince($0) } } == 7200, "the panel follows",
                )
                try app.press(.undo)
                try app.waitForPanels()
                // Develop saves the photo it has open as it is now, over the sidecar the Undo wrote.
                try app.main { _ = $0.saveBeforeQuitting(within: .seconds(10)) }
                let undone = try app.writtenMetadata(names[dated])
                let left = try app.main { $0.libraryPanels.undoCount }
                try app.expect(
                    undone == written,
                    "⌘Z left \(names[dated])'s sidecar as it was: \(String(describing: written)) became "
                        + "\(String(describing: undone)), \(left) left to undo; " + app.panelErrors(),
                )

                try app.choose(.editCaptureTime)
                try app.waitForSheet("Edit Capture Time")
                try app.pressInSheet("captureTime.zone")
                try app.chooseInSheet("UTC+05:45", inPopUp: "captureTime.zones")
                try app.confirmSheet("Edit Capture Time")
                try app.waitForPanels()
                let zoned = try app.writtenMetadata(names[dated])
                try app.expect(
                    zoned?["captureOffset"] == .number(20700), "the camera's zone given: \(String(describing: zoned))",
                )
                try app.press(.undo)
                try app.waitForPanels()
                try app.main { _ = $0.saveBeforeQuitting(within: .seconds(10)) }
                try app.expect(try app.writtenMetadata(names[dated]) == written, "⌘Z took the zone back")
                app.covered([.action(.editCaptureTime), .feature("library.metadata")], via: .menu)
            }
        }
    }
#endif
