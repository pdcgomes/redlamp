#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDocument
    import RedlampEngineAPI
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// Library's drags (LIB-21, LIB-23, LIB-26), on small JPEGs of the run's own: photos dragged from the grid onto a
    /// folder of Folders and onto a collection, and a keyword from the Keyword List onto photos. The press, the drag
    /// and the release go through the window as the mouse's do, to the grid's and the panels' own handlers and the
    /// drop targets' dragging destinations; only the window server's part of a drag, which doesn't follow a
    /// synthetic mouse, is the suite's (`LibraryDrags.simulates`).
    enum DragScenarios {
        static let all: [Scenario] = [toFolder, toCollection, keywordOntoPhotos, painter]

        static let toFolder = Scenario(
            "library.drag-to-folder",
            "Photos dragged from the grid onto a folder of Folders move there as one batch, with their sidecars, and "
                + "⌘Z brings them back; onto the folder they're in the drop is refused; with ⌥ held they're copied "
                + "there, ⌘Z moving the copies to the Trash and ⇧⌘Z copying them again",
            claims: [.feature("library.folders")],
        ) { app in
            let scratch = try DragScratch()
            defer { scratch.remove(app) }
            try scratch.show(app)
            try app.simulateLibraryDrags(true)
            defer { try? app.simulateLibraryDrags(false) }
            let (a, c) = (scratch.photo("A.jpg"), scratch.photo("C.jpg"))
            try app.main { model in
                model.select(a)
                model.click(c, toggling: true)
            }
            try app.wait("A and C selected") { Set($0.selectedPhotos) == [a, c] }
            let moves = try app.main { $0.fileUndoCount }

            try app.dragGridPhoto("A.jpg", onto: "folders." + scratch.picked.path)
            try app.wait("A, its sidecar and C in Picked, the move done", timeout: 60) { model in
                scratch.files(in: scratch.picked) == ["A.jpg", "A.jpg.redlamp", "C.jpg"]
                    && model.fileUndoCount == moves + 1 && !model.isModalDialogOpen
            }
            try app.wait("the grid without them") { $0.items.map(\.name) == ["B.jpg", "D.jpg"] }
            app.covered(.feature("library.folders"), via: .mouse)
            try app.press(.undo)
            try app.run("the Undo", timeout: 60) { await $0.filesMade() }
            try app.wait("⌘Z to bring them back", timeout: 30) { model in
                scratch.files(in: scratch.picked).isEmpty && model.items.count == scratch.names.count
            }

            // Onto the folder the photo is in: refused, and nothing moves.
            let before = scratch.files(in: scratch.folder)
            let undone = try app.main { $0.fileUndoCount }
            try app.main { $0.select(scratch.photo("B.jpg")) }
            try app.dragGridPhoto("B.jpg", onto: "folders." + scratch.folder.path)
            app.pause(0.5)
            try app.expect(scratch.files(in: scratch.folder) == before, "A drop onto B's own folder moved something")
            try app.expect(try app.main { $0.fileUndoCount } == undone, "A drop onto B's own folder made a batch")

            // With ⌥ held: copied, B staying where it is.
            let copies = try app.main { $0.fileUndoCount }
            try app.dragGridPhoto("B.jpg", onto: "folders." + scratch.picked.path, modifiers: .option)
            try app.wait("B copied to Picked, the copy done", timeout: 60) { model in
                scratch.files(in: scratch.picked) == ["B.jpg"] && model.fileUndoCount == copies + 1
                    && !model.isModalDialogOpen
            }
            try app.expect(scratch.files(in: scratch.folder).contains("B.jpg"), "⌥ moved B rather than copying it")
            try app.wait("the grid with B still in it") { $0.items.map(\.name).contains("B.jpg") }
            try app.press(.undo)
            try app.run("the Undo", timeout: 60) { await $0.filesMade() }
            try app.wait("⌘Z to move the copy to the Trash", timeout: 30) { _ in
                scratch.files(in: scratch.picked).isEmpty
            }
            try app.choose(.redo)
            try app.run("the Redo", timeout: 60) { await $0.filesMade() }
            try app.wait("⇧⌘Z to copy it again", timeout: 30) { _ in scratch.files(in: scratch.picked) == ["B.jpg"] }
            try app.press(.undo)
            try app.run("the Undo", timeout: 60) { await $0.filesMade() }
            try app.wait("⌘Z to take the copy away again", timeout: 30) { _ in
                scratch.files(in: scratch.picked).isEmpty
            }
        }

        static let toCollection = Scenario(
            "library.drag-to-collection",
            "Photos dragged from the grid onto a collection go in it as one change, and ⌘Z takes them out again; a "
                + "smart collection refuses them",
            claims: [.feature("library.collections")],
        ) { app in
            let scratch = try DragScratch()
            defer { scratch.remove(app) }
            try scratch.show(app)
            try app.simulateLibraryDrags(true)
            defer { try? app.simulateLibraryDrags(false) }
            let name = "Dragged \(UUID().uuidString.prefix(6))"
            guard let selects = CollectionPath(names: [name]), let picks = CollectionPath(names: [name + " Picks"])
            else { throw ScenarioFailure("No collection paths") }
            try app.main { model in
                model.librarySources.create(.collection, named: selects.name)
                model.librarySources.saveSmart("flag:pick", named: picks.name, inside: nil)
            }
            defer {
                try? app.run("the collections deleted") { model in
                    model.librarySources.delete(selects)
                    model.librarySources.delete(picks)
                    await model.libraryPanels.written()
                }
            }
            try app.waitForDropCounts("the two collections listed") { sources in
                sources.collections[selects] != nil && sources.collections[picks] != nil
            }
            try app.wait("their rows") { _ in
                Views.editorWindow.flatMap { Views.find("collections." + picks.text, in: $0) } != nil
            }
            let (a, c) = (scratch.photo("A.jpg"), scratch.photo("C.jpg"))
            try app.main { model in
                model.select(a)
                model.click(c, toggling: true)
            }
            try app.wait("A and C selected") { Set($0.selectedPhotos) == [a, c] }

            try app.dragGridPhoto("A.jpg", onto: "collections." + selects.text)
            try app.waitForDropCounts("A and C in the collection") { $0.count(of: .collection(selects)) == 2 }
            app.covered(.feature("library.collections"), via: .mouse)
            try app.press(.undo)
            try app.waitForDropCounts("⌘Z to take them out") { $0.count(of: .collection(selects)) == 0 }

            // A smart collection's photos are its query's.
            let changes = try app.main { $0.libraryPanels.undoCount }
            try app.dragGridPhoto("A.jpg", onto: "collections." + picks.text)
            app.pause(0.5)
            try app.expect(try app.main { $0.libraryPanels.undoCount } == changes, "The smart collection took photos")
        }

        static let keywordOntoPhotos = Scenario(
            "library.drag-keyword",
            "A keyword dragged by its name from the Keyword List onto a photo in the grid tags that photo, or the "
                + "selection when the photo is in it, each one change that ⌘Z takes back",
            claims: [.feature("library.keywords")],
        ) { app in
            let scratch = try DragScratch()
            defer { scratch.remove(app) }
            try scratch.show(app)
            try app.simulateLibraryDrags(true)
            defer { try? app.simulateLibraryDrags(false) }
            let text = "Dragged-\(UUID().uuidString.prefix(6))"
            guard let keyword = KeywordPath(text) else { throw ScenarioFailure("No keyword path") }
            try app.main { model in
                model.rightPanelVisible = true
                if !model.libraryPanels.isExpanded(.keywordList) {
                    model.libraryPanels.toggle(.keywordList)
                }
                model.libraryPanels.create(text)
            }
            defer {
                try? app.run("the keyword deleted") { model in
                    model.libraryPanels.delete(keyword)
                    await model.libraryPanels.written()
                }
            }
            try app.wait("the keyword in the Keyword List", timeout: 30) { _ in
                Views.editorWindow.flatMap { Views.find("keywordList.name." + text, in: $0) } != nil
            }
            let (a, b, c) = (scratch.photo("A.jpg"), scratch.photo("B.jpg"), scratch.photo("C.jpg"))
            try app.main { model in
                model.select(a)
                model.click(b, toggling: true)
            }
            try app.wait("A and B selected, as the panels have them") { model in
                Set(model.selectedPhotos) == [a, b] && model.libraryPanels.selection.ids.count == 2
            }
            func keywords(_ photo: URL) -> [String] {
                SidecarStore(locator: .besidePhotos).load(for: photo)?.metadata?.keywords ?? []
            }

            try app.dragKeyword(text, ontoPhoto: "C.jpg")
            try app.wait("C tagged alone", timeout: 30) { _ in
                keywords(c) == [text] && keywords(a).isEmpty && keywords(b).isEmpty
            }
            app.covered(.feature("library.keywords"), via: .mouse)
            try app.press(.undo)
            try app.wait("⌘Z to take it off C", timeout: 30) { _ in keywords(c).isEmpty }

            try app.dragKeyword(text, ontoPhoto: "B.jpg")
            try app.wait("A and B tagged, B being selected", timeout: 30) { _ in
                keywords(a) == [text] && keywords(b) == [text] && keywords(c).isEmpty
            }
            try app.press(.undo)
            try app.wait("⌘Z to take it off them", timeout: 30) { _ in keywords(a).isEmpty && keywords(b).isEmpty }
        }

        static let painter = Scenario(
            "library.keyword-painter",
            "Library › Keyword Painter (⌥⌘K) takes out the painter; a stroke across photos in the grid paints them with "
                + "the keyword typed in its field, one change ⌘Z takes back, the selection staying; ⌥ takes it off; Esc "
                + "and the toolbar's button put the painter away",
            claims: [.action(.keywordPainter), .feature("library.keywords")],
        ) { app in
            let scratch = try DragScratch()
            defer { scratch.remove(app) }
            try scratch.show(app)
            let text = "Painted-\(UUID().uuidString.prefix(6))"
            guard let keyword = KeywordPath(text) else { throw ScenarioFailure("No keyword path") }
            defer {
                try? app.run("the painter put away and its keyword deleted") { model in
                    model.keywordPainter.setOn(false)
                    model.keywordPainter.text = ""
                    model.libraryPanels.delete(keyword)
                    await model.libraryPanels.written()
                }
            }
            let (a, b, c, d) = (
                scratch.photo("A.jpg"), scratch.photo("B.jpg"), scratch.photo("C.jpg"), scratch.photo("D.jpg"),
            )
            try app.main { $0.select(a) }
            func keywords(_ photo: URL) -> [String] {
                SidecarStore(locator: .besidePhotos).load(for: photo)?.metadata?.keywords ?? []
            }

            try app.expectKeyBinding(.keywordPainter)
            try app.choose(.keywordPainter)
            try app.wait("the painter out") { $0.keywordPainter.isOn }
            try app.typeInField("library.toolbar.paints", text, returning: false)
            try app.wait("the painter's field to hold the keyword") { $0.keywordPainter.text == text }

            try app.dragGridPhoto("B.jpg", onto: "grid.C.jpg")
            try app.wait("B and C painted, A and D left alone", timeout: 30) { _ in
                keywords(b) == [text] && keywords(c) == [text] && keywords(a).isEmpty && keywords(d).isEmpty
            }
            try app.expect(try app.main { $0.selectedPhotos } == [a], "Painting changed the selection")
            app.covered(.feature("library.keywords"), via: .mouse)
            try app.press(.undo)
            try app.wait("⌘Z to take the stroke back", timeout: 30) { _ in keywords(b).isEmpty && keywords(c).isEmpty }
            try app.choose(.redo)
            try app.wait("⇧⌘Z to paint it again", timeout: 30) { _ in keywords(b) == [text] && keywords(c) == [text] }

            try app.drag(.identifier("grid.B.jpg"), by: CGVector(dx: 0, dy: 0), steps: 1, modifiers: .option)
            try app.wait("⌥ to take it off B", timeout: 30) { _ in keywords(b).isEmpty && keywords(c) == [text] }

            try app.press(.cancel)
            try app.wait("Esc to put the painter away") { !$0.keywordPainter.isOn }
            try app.click(.identifier("library.toolbar.painter"))
            try app.wait("the toolbar's button to take it out") { $0.keywordPainter.isOn }
            try app.click(.identifier("library.toolbar.painter"))
            try app.wait("and to put it away") { !$0.keywordPainter.isOn }
            app.covered(.action(.keywordPainter), via: .mouse)
        }
    }

    /// Small JPEGs of the run's own on the external disk's scratch folder, A to D (or `names`), the first with a
    /// sidecar, and an empty folder beside them, Picked, each added to Folders as a folder of its own so both rows are
    /// on screen; taken out of Folders and removed afterwards, with what the library's batches put in the Trash.
    struct DragScratch: Sendable {
        let base: URL
        let folder: URL
        let picked: URL
        let names: [String]

        init(names: [String] = ["A.jpg", "B.jpg", "C.jpg", "D.jpg"]) throws {
            self.names = names
            base = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp", isDirectory: true)
                .appending(path: "e2e-drags-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            folder = base.appending(path: "Photos", directoryHint: .isDirectory)
            picked = base.appending(path: "Picked", directoryHint: .isDirectory)
            for directory in [folder, picked] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            for (number, name) in names.enumerated() {
                try SourcesScratch.jpeg(number: number).write(to: photo(name))
            }
            if let first = names.first {
                try SidecarStore(locator: .besidePhotos).save(
                    Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 2)), for: photo(first),
                )
            }
        }

        func photo(_ name: String) -> URL {
            folder.appending(path: name, directoryHint: .notDirectory)
        }

        /// The files in `directory`, sorted.
        func files(in directory: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        }

        /// Adds both folders to Folders and shows the photos' in Library's grid, from the library.
        func show(_ app: RunningApp) throws {
            let service = try app.main { $0.library.service }
            guard let service else { throw ScenarioSkip("the library is off") }
            let (folder, picked, count, first) = (folder, picked, names.count, names.first ?? "")
            try app.main { model in
                model.open([folder, picked])
                model.showLibrary(.grid)
            }
            let indexed = Flag()
            try app.run("the library to index the photos", timeout: 90) { _ in
                for _ in 0 ..< 900 where await !service.canShow(folder, includingSubfolders: true) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if await service.canShow(folder, includingSubfolders: true) {
                    indexed.set()
                }
            }
            try app.expect(indexed.isSet, "the library didn't index \(folder.path)")
            try app.main { $0.showFolder(folder) }
            try app.wait("the photos from the library", timeout: 30) { model in
                model.folder == folder && !model.library.isListing && model.library.isShownFromLibrary
                    && model.items.count == count
            }
            try app.wait("the grid's cells and Picked in Folders", timeout: 20) { _ in
                guard let window = Views.editorWindow else { return false }
                return Views.find("grid." + first, in: window) != nil
                    && Views.find("folders." + picked.path, in: window) != nil
            }
        }

        func remove(_ app: RunningApp) {
            let (folder, picked) = (folder, picked)
            try? app.run("emptying what the batches put in the Trash", timeout: 60) { model in
                await model.filesMade()
                for place in await model.library.service?.trashedPlaces() ?? [] {
                    try? FileManager.default.removeItem(atPath: place)
                }
            }
            try? app.main { model in
                EditorModel.moveToFolderAnswer = nil
                LibraryService.pausePerStep = .zero
                for url in [folder, picked] {
                    if let root = model.library.root(containing: url) {
                        model.library.remove(root)
                    }
                }
            }
            try? FileManager.default.removeItem(at: base)
            try? app.openWorking()
        }
    }

    extension RunningApp {
        /// Library's drags follow the suite's synthetic mouse, or the window server again.
        func simulateLibraryDrags(_ on: Bool) throws {
            try main { _ in LibraryDrags.simulates = on }
        }

        /// Presses the grid's cell of `name`, drags it onto the view carrying `identifier` and lets go there, through
        /// the window as the mouse does, holding `modifiers`.
        func dragGridPhoto(_ name: String, onto identifier: String, modifiers: NSEvent.ModifierFlags = []) throws {
            let from = try frame(of: .identifier("grid.\(name)"))
            let to = try frame(of: .identifier(identifier))
            try drag(
                .identifier("grid.\(name)"), by: CGVector(dx: to.midX - from.midX, dy: to.midY - from.midY),
                steps: 12, modifiers: modifiers,
            )
        }

        /// Presses the name of `keyword` (its path) in the Keyword List, drags it onto the grid's cell of `name` and
        /// lets
        /// go there, through the window as the mouse does.
        func dragKeyword(_ keyword: String, ontoPhoto name: String) throws {
            // A change's progress bar in Keywording comes and goes as it's made, moving the Keyword List below it.
            try run("the panels to settle") { model in
                await model.libraryPanels.written()
                await model.libraryPanels.refreshed()
                await model.libraryPanels.keywordsRead()
            }
            pause(0.3)
            let label = Target.identifier("keywordList.name." + keyword)
            let from = try frame(of: label)
            let to = try frame(of: .identifier("grid.\(name)"))
            try drag(label, by: CGVector(dx: to.midX - from.midX, dy: to.midY - from.midY), steps: 12)
        }

        /// Counts the library again, and again, until `condition` holds of the left panel's sources: a drop's change
        /// reaches the query engine a moment after its batch.
        func waitForDropCounts(
            _ what: String, timeout: Double = 30, _ condition: @escaping @MainActor (LibrarySources) -> Bool,
        ) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                try run("counting the library") { model in
                    await model.libraryPanels.written()
                    model.librarySources.recount()
                    await model.librarySources.counted()
                }
                if try main({ condition($0.librarySources) }) {
                    return
                }
                guard Date() < deadline
                else { throw ScenarioFailure("Timed out after \(timeout) s waiting for \(what)") }
                pause(0.1)
            }
        }
    }
#endif
