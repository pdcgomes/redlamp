#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampEngineAPI
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    extension ActionCheck {
        /// Shows the Library grid; afterwards the bar hidden, the filter on and unlocked, and the folder's
        /// own order back.
        static func filter(_ action: ShortcutAction) -> ActionCheck {
            ActionCheck(action: action, setUp: { app in
                try app.main { model in
                    model.showLibrary(.grid)
                    model.libraryFilters?.setSort(LibrarySort(action == .sortByFolder ? .captured : .folder))
                }
                try app.settle()
            }, observe: filterState, restore: { app in
                try app.main { model in
                    guard let filters = model.libraryFilters else { return }
                    filters.setBarShown(false)
                    filters.setEnabled(true)
                    filters.setLocked(false)
                    filters.setSort(LibrarySort())
                }
                try app.backToDevelop()
            })
        }

        @MainActor static func filterState(_ model: EditorModel) -> String {
            guard let filters = model.libraryFilters else { return "no library" }
            return "\(filters.isBarShown) \(filters.filter.isEnabled) \(filters.isLocked) \(filters.sort.field) "
                + "\(filters.sort.ascending)"
        }
    }

    extension RunningApp {
        /// Runs `body` on the working folder's grid with the filter bar's text taking the keyboard, then
        /// clears the filter, also when `body` fails, so the scenarios after it find every photo.
        func withFilterBar(_ body: ([String]) throws -> Void) throws {
            let names = try showFilterBar()
            do {
                try body(names)
            } catch {
                try? resetFilter()
                throw error
            }
            try resetFilter()
        }

        /// The working folder's grid, shown from the library, with the filter bar's text taking the keyboard.
        func showFilterBar() throws -> [String] {
            // A launch that crashed keeps the folder's filter, which can leave it no photos to show.
            try main { $0.libraryFilters?.setFilter(LibraryFilter()) }
            let names = try showGrid()
            try wait("the folder shown from the library", timeout: 90) { $0.library.isShownFromLibrary }
            try main { $0.libraryFilters?.setFilter(LibraryFilter()) }
            if try !main({ $0.libraryFilters?.isBarShown ?? false }) {
                try press(.toggleFilterBar)
            }
            try wait("the filter bar's text to take the keyboard") { _ in
                (Views.editorWindow?.firstResponder as? NSTextView)?.delegate is NSTextField
            }
            return names
        }

        /// Types `text` as keys, with Shift for the characters this keyboard layout types with it
        /// (`:`, `>` and `=` on most), which `type` has no key for.
        func typeQuery(_ text: String) throws {
            for character in text {
                if try main({ _ in Keyboard.hasKey(for: character) }) {
                    try pressInWindow(KeyCombo(.character(character)))
                    continue
                }
                let event = try main { _ in try Keyboard.shifted(character) }
                post { _ in Views.editorWindow?.sendEvent(event) }
                pause(0.03)
            }
        }

        /// The filter cleared, the bar hidden, the folder's own order, and Develop again.
        func resetFilter() throws {
            try main { model in
                guard let filters = model.libraryFilters else { return }
                filters.setFilter(LibraryFilter())
                filters.setLocked(false)
                filters.setSort(LibrarySort())
                filters.setBarShown(false)
            }
            try wait("every photo back") { model in
                model.libraryFilters?.lastListed.map { $0.query == nil && $0.sort == nil && !$0.reversed } ?? true
            }
            try backToDevelop()
        }

        func filterText() throws -> String {
            try main { $0.libraryFilters?.filter.text ?? "" }
        }
    }

    extension Keyboard {
        /// The key event typing `character` with Shift held, in the current keyboard layout.
        static func shifted(_ character: Character) throws -> NSEvent {
            let typed = String(character)
            for code in UInt16(0) ..< 128 {
                guard let probe = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code,
                ), probe.characters(byApplyingModifiers: .shift) == typed
                else { continue }
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .shift,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: EditorWindowController.frontWindow?.windowNumber ?? 0, context: nil,
                    characters: typed, charactersIgnoringModifiers: typed, isARepeat: false, keyCode: code,
                ) else { break }
                return event
            }
            throw ScenarioFailure("The keyboard layout has no key for \(character), with Shift or without")
        }
    }

    enum FilterScenarios {
        static let all: [Scenario] = [text, columns, sources, empty]

        private static let raws: Set<String> = ["arw", "raf", "cr3", "nef", "dng", "orf", "pef", "rw2", "3fr"]

        private static func isRaw(_ name: String) -> Bool {
            raws.contains((name as NSString).pathExtension.lowercased())
        }

        static let text = Scenario(
            "library.filter-text",
            "\\ shows the filter bar; its text finds photos as it's typed, completes terms from the index with Tab, "
                + "shows what can't be read, and Esc goes back to the grid",
            tiers: [.smoke, .full], claims: [.action(.toggleFilterBar), .feature("library.filter")],
        ) { app in
            try app.withFilterBar { names in
                app.covered(.action(.toggleFilterBar), via: .key)
                let raws = names.filter(isRaw)
                try app.expect(!raws.isEmpty && raws.count < names.count, "The folder needs raws and other photos")
                try app.typeQuery("type:")
                try app.wait("a field without its value to leave every photo") { $0.items.count == names.count }
                try app.typeQuery("raw")
                try app.wait("only the raws, as typed") { model in
                    model.library.isFiltered && model.items.count == raws.count
                        && model.items.allSatisfy { isRaw($0.name) }
                }
                try app.typeQuery(" label:re")
                try app.wait("a label offered") { $0.libraryFilters?.completions.first?.text == "label:red " }
                try app.pressInWindow(KeyCombo(.tab))
                try app.wait("Tab to take it") { $0.libraryFilters?.filter.text == "type:raw label:red " }
                try app.typeQuery("rating>=9 a")
                try app.wait("what can't be read said") { $0.libraryFilters?.error != nil }
                try app.expect(
                    try app.main { $0.libraryFilters?.error?.message.contains("rating") == true },
                    "The error names rating",
                )
                app.covered(.feature("library.filter"), via: .key)
                if try app.main({ $0.libraryFilters?.completions.isEmpty == false }) {
                    try app.pressInWindow(KeyCombo(.escape))
                    try app.wait("Esc to close the completions") { $0.libraryFilters?.completions.isEmpty == true }
                }
                try app.pressInWindow(KeyCombo(.escape))
                try app.wait("Esc to give the grid the keyboard") { _ in
                    Views.editorWindow?.firstResponder.map { "\(Swift.type(of: $0))" } == "LibraryGridContentView"
                }
                try app.press(.toggleFilterBar)
                try app.wait("\\ to hide the bar") { $0.libraryFilters?.isBarShown == false }
            }
        }

        static let columns = Scenario(
            "library.filter-columns",
            "The Attribute section's buttons and the Metadata columns' rows choose photos, each choice showing in "
                + "the text, the columns counting the photos of the choices before them",
            claims: [.feature("library.filter")],
        ) { app in
            try app.withFilterBar { names in
                let raws = names.filter(isRaw)
                try app.main { model in
                    model.libraryFilters?.setColumns([.kind, .camera])
                }
                try app.clickView("library.filter.attribute", modifiers: .shift)
                try app.clickView("library.filter.metadata", modifiers: .shift)
                try app.wait("the three sections") { model in
                    model.libraryFilters?.filter.sections == [.text, .attribute, .metadata]
                }
                try app.clickView("library.filter.kind.raw")
                try app.wait("the Raw button's filter in the text") { model in
                    model.libraryFilters?.filter.text == "ext:raw" && model.items.count == raws.count
                }
                try app.clickView("library.filter.kind.raw")
                try app.wait("Raw again to take it out") { $0.libraryFilters?.filter.text.isEmpty == true }
                try app.wait("the File Type column's counts", timeout: 20) { model in
                    model.libraryFilters?.columns[0]?.values.contains { $0.name == "raw" } == true
                }
                try app.wait("its row on screen") { _ in
                    Views.editorWindow.flatMap { Views.find("library.filter.column.0.value.raw", in: $0) } != nil
                }
                try app.clickView("library.filter.column.0.value.raw")
                try app.wait("the row's filter in the text, and the raws") { model in
                    model.libraryFilters?.filter.text == "ext:raw" && model.items.count == raws.count
                }
                try app.wait("the next column counting the raws alone", timeout: 20) { model in
                    model.libraryFilters?.columns[1]?.total == raws.count
                }
                try app.expect(
                    try app.main { $0.libraryFilters?.columns[0]?.total == names.count },
                    "The first column counts every photo",
                )
                try app.clickView("library.filter.offline")
                try app.wait("offline photos only: none") { model in
                    model.libraryFilters?.filter.text == "ext:raw offline:yes" && model.items.isEmpty
                }
                try app.clickView("library.filter.column.0.all")
                try app.wait("All to take the column's choice out") { $0.libraryFilters?.filter.text == "offline:yes" }
                app.covered(.feature("library.filter"), via: .mouse)
            }
        }

        static let sources = Scenario(
            "library.filter-sources",
            "Each source keeps its filter and sort, the lock keeps one filter across sources, sorts order the grid "
                + "both ways, and saved filters come back",
            claims: [
                .action(.lockFilters),
                .action(.sortByFileSize),
                .action(.reverseSort),
                .feature("library.filter"),
            ],
        ) { app in
            try app.withFilterBar { names in
                let raws = names.filter(isRaw)
                try app.typeQuery("type:raw")
                try app.wait("the raws") { $0.items.count == raws.count }
                try app.main { $0.setIncludesSubfolders(true) }
                try app.wait("the folder with its subfolders, with a filter of its own") { model in
                    model.library.includesSubfolders && model.libraryFilters?.filter.text.isEmpty == true
                }
                try app.main { $0.setIncludesSubfolders(false) }
                try app.wait("the folder alone, its filter back") { model in
                    !model.library.includesSubfolders && model.libraryFilters?.filter.text == "type:raw"
                        && model.items.count == raws.count
                }
                try app.choose(.lockFilters)
                try app.main { $0.setIncludesSubfolders(true) }
                try app.wait("the filter kept by the lock") { model in
                    model.library.includesSubfolders && model.libraryFilters?.filter.text == "type:raw"
                }
                try app.choose(.lockFilters)
                try app.main { $0.setIncludesSubfolders(false) }
                try app.wait("the folder alone") { !$0.library.includesSubfolders && !$0.library.isListing }

                try app.choose(.sortByFileSize)
                try app.wait("the raws by size, smallest first") { model in
                    model.items.count == raws.count && zip(model.items, model.items.dropFirst())
                        .allSatisfy { $0.size <= $1.size }
                }
                try app.choose(.reverseSort)
                try app.wait("largest first") { model in
                    model.items.count == raws.count && zip(model.items, model.items.dropFirst())
                        .allSatisfy { $0.size >= $1.size }
                }
                try app.main { model in
                    model.libraryFilters?.save(as: "E2E Raws")
                    model.libraryFilters?.clear()
                }
                try app.wait("every photo") { $0.items.count == names.count }
                try app.main { model in
                    if let preset = model.libraryFilters?.presets.first(where: { $0.name == "E2E Raws" }) {
                        model.libraryFilters?.choose(preset)
                    }
                }
                try app.wait("the saved filter back") { model in
                    model.libraryFilters?.filter.text == "type:raw" && model.items.count == raws.count
                }
                try app.main { model in
                    if let preset = model.libraryFilters?.preset {
                        model.libraryFilters?.delete(preset)
                    }
                }
                app.covered([.feature("library.filter"), .action(.lockFilters), .action(.sortByFileSize)], via: .menu)
            }
        }

        static let empty = Scenario(
            "library.filter-empty",
            "A filter that finds none of the folder's photos names the term whose removal brings the most back, and "
                + "its button takes that term out",
            claims: [.feature("library.filter")],
        ) { app in
            try app.withFilterBar { names in
                let raws = names.filter(isRaw)
                try app.typeQuery("type:raw kw:zzzz")
                try app.wait("no photos, and the keyword named") { model in
                    model.items.isEmpty && model.libraryFilters?.removal?.term == "kw:zzzz"
                        && model.libraryFilters?.removal?.count == raws.count
                }
                try app.wait("its button on screen") { _ in
                    Views.editorWindow.flatMap { Views.find("library.filter.removal", in: $0) } != nil
                }
                try app.clickView("library.filter.removal")
                try app.wait("the raws back, the keyword taken out") { model in
                    model.libraryFilters?.filter.text == "type:raw" && model.items.count == raws.count
                        && model.libraryFilters?.removal == nil
                }
                app.covered(.feature("library.filter"), via: .mouse)
            }
        }
    }
#endif
