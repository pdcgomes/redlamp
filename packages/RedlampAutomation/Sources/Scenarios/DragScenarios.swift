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
        static let all: [Scenario] = [toFolder]

        static let toFolder = Scenario(
            "library.drag-to-folder",
            "Photos dragged from the grid onto a folder of Folders move there as one batch, with their sidecars, and "
                + "⌘Z brings them back; onto the folder they're in the drop is refused, and with ⌥ held it says photos "
                + "aren't copied",
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
            try app.wait("A, its sidecar and C in Picked", timeout: 60) { model in
                scratch.files(in: scratch.picked) == ["A.jpg", "A.jpg.redlamp", "C.jpg"]
                    && model.fileUndoCount == moves + 1
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

            // With ⌥ held: photos aren't copied, and the drop says so.
            let mark = try app.mark()
            try app.dragGridPhoto("B.jpg", onto: "folders." + scratch.picked.path, modifiers: .option)
            try app.wait("the drop to say photos aren't copied") { _ in
                (try? app.activity(since: mark).contains { $0.text == EditorModel.notCopied }) == true
            }
            try app.dismissDropAlert()
            try app.expect(scratch.files(in: scratch.picked).isEmpty, "⌥ moved B to Picked")
        }
    }

    /// Small JPEGs of the run's own on the external disk's scratch folder, A to D, A with a sidecar, and an empty
    /// folder
    /// beside them, Picked, each added to Folders as a folder of its own so both rows are on screen; taken out of
    /// Folders and removed afterwards.
    struct DragScratch: Sendable {
        let base: URL
        let folder: URL
        let picked: URL
        let names = ["A.jpg", "B.jpg", "C.jpg", "D.jpg"]

        init() throws {
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
            try SidecarStore(locator: .besidePhotos).save(
                Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 2)), for: photo("A.jpg"),
            )
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
            let (folder, picked, count) = (folder, picked, names.count)
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
                return Views.find("grid.A.jpg", in: window) != nil
                    && Views.find("folders." + picked.path, in: window) != nil
            }
        }

        func remove(_ app: RunningApp) {
            let (folder, picked) = (folder, picked)
            try? app.main { model in
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

        /// Closes the alert a drop put up, as its OK button's Return does.
        func dismissDropAlert() throws {
            try waitForSheet("the drop's alert")
            if try !pressInSheet(KeyCombo(.character("\r"))) {
                try main { _ in
                    guard let window = Views.editorWindow, let sheet = window.attachedSheet else { return }
                    window.endSheet(sheet)
                }
            }
            try waitForNoSheet("the drop's alert")
        }
    }
#endif
