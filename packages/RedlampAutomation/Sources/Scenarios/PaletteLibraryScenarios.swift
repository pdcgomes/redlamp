#if DEBUG || REDLAMP_PROFILING
    import Foundation
    import RedlampEngineAPI
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    extension RunningApp {
        /// Types `text` into the open palette's search, as its field hands each change over, and waits
        /// for the library's rows for it.
        func searchPalette(_ text: String) throws -> [PaletteItem] {
            try main { $0.commandPalette?.setText(text) }
            try wait("the library's rows for \(text)") { model in
                model.commandPalette.map { $0.library.text == text && !$0.library.isSearching } ?? false
            }
            return try main { $0.commandPalette?.library.items ?? [] }
        }

        /// Moves the palette's highlight to `item` with ↓ and presses ↵.
        func choosePaletteRow(_ item: PaletteItem) throws {
            try submitPaletteRow(item)
            try wait("the palette to close") { $0.commandPalette == nil }
        }

        /// Moves the palette's highlight from the first row to `item` with ↓ and presses ↵, the palette staying open
        /// or not.
        func submitPaletteRow(_ item: PaletteItem) throws {
            let index = try main { $0.commandPalette?.rows.firstIndex(of: item) ?? -1 }
            try expect(index >= 0, "\(item.title) isn't among the palette's rows")
            for _ in 0 ..< index {
                try paletteKey(.down)
            }
            try wait("\(item.title) highlighted") { $0.commandPalette?.selectedItem == item }
            try paletteKey(.submit)
        }
    }

    enum PaletteLibraryScenarios {
        static let all: [Scenario] = [names, terms]

        static let names = Scenario(
            "library.palette-names",
            "⌘K finds the library's names and photos as their names are typed, beside the commands: a camera's "
                + "name, typed with a typo, becomes the filter's term, and a photo found by its name is shown",
            claims: [.feature("workspace.palette"), .feature("library.filter")],
        ) { app in
            let names = try app.showGrid()
            try app.wait("the folder shown from the library", timeout: 90) { $0.library.isShownFromLibrary }
            try app.main { $0.libraryFilters?.setFilter(LibraryFilter()) }
            defer { try? app.resetFilter() }

            try app.press(.commandPalette)
            try app.wait("the palette") { $0.commandPalette != nil }
            var camera: PaletteItem?
            for typed in ["fujiflim", "nikkon", "canno", "sonny"] {
                camera = try app.searchPalette(typed).first { $0.context == "Camera" }
                if camera != nil {
                    break
                }
            }
            guard let found = camera, case let .libraryName(.camera, name) = found.kind else {
                throw ScenarioFailure("No camera of the folder's found by its name with a typo")
            }
            try app.choosePaletteRow(found)
            let term = QueryCompletion(field: .camera, value: name).term
            try app.wait("the camera's term in the filter, and its photos") { model in
                model.libraryFilters?.filter.text == term && !model.items.isEmpty && model.items.count < names.count
            }

            try app.main { $0.libraryFilters?.clear() }
            try app.wait("every photo back") { $0.items.count == names.count }
            let photo = names[names.count / 2]
            try app.press(.commandPalette)
            try app.wait("the palette") { $0.commandPalette != nil }
            let rows = try app.searchPalette((photo as NSString).deletingPathExtension)
            guard let row = rows.first(where: { $0.title == photo }) else {
                throw ScenarioFailure("\(photo) isn't found by its name")
            }
            try app.choosePaletteRow(row)
            try app.wait("the photo shown") { $0.selection?.lastPathComponent == photo }
            app.covered([.feature("workspace.palette"), .feature("library.filter")], via: .key)
        }

        static let terms = Scenario(
            "library.palette-terms",
            "⌘K completes the query's terms as the filter bar's text does: a field's row types the field, is: lists "
                + "the traits, Damaged Files with the folder's damaged file among them, and its row makes it the "
                + "filter's term",
            claims: [.feature("workspace.palette"), .feature("library.filter")],
        ) { app in
            let scratch = try SourcesScratch(app, photos: ["A.jpg", "B.jpg"], empty: ["Empty.jpg"])
            defer { app.removeScratch(scratch) }
            try scratch.index(app)
            try app.main { $0.libraryFilters?.setFilter(LibraryFilter()) }
            defer { try? app.resetFilter() }

            try app.press(.commandPalette)
            try app.wait("the palette") { $0.commandPalette != nil }
            guard let field = try app.searchPalette("orien").first(where: { $0.kind == .queryField("orientation:") })
            else { throw ScenarioFailure("No row for the orientation field") }
            try app.submitPaletteRow(field)
            try app.wait("↵ to type the field, and its values listed") { model in
                model.commandPalette.map { palette in
                    palette.text == "orientation:" && palette.library.text == "orientation:"
                        && !palette.library.isSearching && palette.library.items.count == 3
                } == true
            }

            let traits = try app.searchPalette("is:")
            guard let damaged = traits.first(where: { $0.kind == .queryTerm("is:damaged") }) else {
                throw ScenarioFailure("Damaged Files isn't among the traits: \(traits.map(\.title))")
            }
            try app.expect(damaged.context == "is:damaged · 1 photo", "Damaged Files counts \(damaged.context)")
            try app.choosePaletteRow(damaged)
            try app.wait("the term in the filter, and the empty file alone", timeout: 20) { model in
                model.libraryFilters?.filter.text == "is:damaged" && model.items.map(\.name) == ["Empty.jpg"]
            }
            app.covered([.feature("workspace.palette"), .feature("library.filter")], via: .key)
        }
    }
#endif
