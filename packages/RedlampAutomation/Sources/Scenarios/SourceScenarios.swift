#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    import RedlampLibrary
    @_spi(Harness) import RedlampUI
    import Synchronization

    /// The sources the Folders panel chooses: folders counted with their subfolders' photos, and a folder of
    /// folders showing every photo beneath it (LIB-10); and Recently Trashed, with Put Back (LIB-26).
    enum SourceScenarios {
        static let all: [Scenario] = [subfolders, recentlyTrashed, folderCounts]

        /// Photos a batch of the library's moved to the Trash: Recently Trashed from the palette, the photos put
        /// back from the grid's menu, by ⌘⌫, from the Photo menu and the palette, Develop off for them, and the
        /// Folders panel's line saying what it holds once it's empty. The photos are copies made on the
        /// external disk's scratch folder, which the Trash there holds while they're in it; none is left there.
        static let recentlyTrashed = Scenario(
            "library.recently-trashed",
            "Recently Trashed from the palette, and Put Back from the grid's menu, ⌘⌫, the Photo menu and the palette",
            claims: [
                .action(.showRecentlyTrashed),
                .action(.putBack),
                .action(.putBackBatch),
                .feature("library.folders"),
            ],
        ) { app in
            let token = UUID().uuidString.prefix(8)
            let folder = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp", isDirectory: true)
                .appending(path: "e2e-trashed-\(token)", directoryHint: .isDirectory)
            let names = ["A", "B", "C"].map { "Trashed \($0) \(token).jpg" }
            let photos = names.map { folder.appending(path: $0, directoryHint: .notDirectory) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for photo in photos {
                try FileManager.default.copyItem(at: app.photos.appending(path: "Bitmap.jpg"), to: photo)
            }
            let service = try app.main { model -> LibraryService? in model.library.service }
            guard let service else { throw ScenarioSkip("the library is off") }
            defer {
                try? app.run("emptying what's left in the Trash", timeout: 30) { model in
                    for place in await service.trashedPlaces() {
                        try? FileManager.default.removeItem(atPath: place)
                    }
                    if let root = model.library.root(containing: folder) {
                        model.library.remove(root)
                    }
                }
                try? FileManager.default.removeItem(at: folder)
            }
            try app.main { $0.open([folder]) }
            let indexed = Flag()
            try app.run("the library to index the folder", timeout: 90) { _ in
                for _ in 0 ..< 900 where await !service.canShow(folder, includingSubfolders: true) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if await service.canShow(folder, includingSubfolders: true) {
                    indexed.set()
                }
            }
            try app.expect(indexed.isSet, "the library didn't index \(folder.path)")
            let trashing = Mutex<String?>(nil)
            try app.run("moving the photos to the Trash, two batches", timeout: 60) { _ in
                do {
                    try await service.moveToTrash([photos[0], photos[1]])
                    try await service.moveToTrash([photos[2]])
                } catch {
                    trashing.withLock { $0 = "\(error)" }
                }
            }
            if let failure = trashing.withLock({ $0 }) {
                throw ScenarioFailure("The photos didn't go to the Trash: \(failure)")
            }

            // The palette shows Recently Trashed, in Library, where its photos don't open in Develop.
            try app.runFromPalette(.showRecentlyTrashed)
            try app.wait("Recently Trashed with the three photos", timeout: 20) { model in
                model.library.showsRecentlyTrashed && model.items.count == 3 && model.module == .library
            }
            try app.expect(try app.main { !$0.canPerform(.developModule) }, "Develop is on for photos in the Trash")
            @MainActor func place(_ index: Int) -> URL? {
                app.model.items.first { app.model.library.trashedPhoto(at: $0.url)?.original == photos[index].path }?
                    .url
            }

            // A photo's menu puts back A alone, the photo active being C, the newest batch's.
            try app.wait("A in the filmstrip") { _ in
                Views.editorWindow.flatMap { Views.find(Target.filmstrip(names[0]).identifier, in: $0) } != nil
            }
            try app.rightClick(.filmstrip(names[0]), choosing: ShortcutAction.putBack.title)
            try app.wait("A back where it was", timeout: 20) { model in
                FileManager.default.fileExists(atPath: photos[0].path) && model.items.count == 2
            }
            app.covered(.action(.putBack), via: .mouse)

            // ⌘⌫ puts back the active photo.
            try app.main { model in place(2).map { model.select($0) } }
            try app.press(.putBack)
            try app.wait("C back where it was", timeout: 20) { model in
                FileManager.default.fileExists(atPath: photos[2].path) && model.items.count == 1
            }

            // The Photo menu puts back the rest of B's batch.
            try app.click(.filmstrip(names[1]))
            try app.wait("B active") { $0.selection?.lastPathComponent == names[1] }
            try app.choose(.putBackBatch)
            try app.wait("B back where it was, Recently Trashed empty", timeout: 20) { model in
                FileManager.default.fileExists(atPath: photos[1].path) && model.items.isEmpty
                    && model.library.trashedCount == 0
            }
            try app.wait("the Folders panel saying what Recently Trashed holds") { _ in
                guard let root = Views.editorWindow?.contentView?.superview else { return false }
                return Views.all(NSTextField.self, in: root).contains {
                    $0.stringValue == RecentlyTrashedText.empty && !$0.isHiddenOrHasHiddenAncestor
                }
            }
            app.covered(.feature("library.folders"), via: .mouse)

            // All three to the Trash again as one batch: the palette puts back the selection.
            let trashingAgain = Mutex<String?>(nil)
            try app.run("moving the photos to the Trash again", timeout: 60) { _ in
                do {
                    try await service.moveToTrash(photos)
                } catch {
                    trashingAgain.withLock { $0 = "\(error)" }
                }
            }
            if let failure = trashingAgain.withLock({ $0 }) {
                throw ScenarioFailure("The photos didn't go to the Trash again: \(failure)")
            }
            try app.wait("the three in Recently Trashed again", timeout: 20) { $0.items.count == 3 }
            try app.main { $0.selectAllPhotos() }
            try app.runFromPalette(.putBack)
            try app.wait("every photo back where it was", timeout: 20) { model in
                photos.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } && model.items.isEmpty
            }

            // As the run had it.
            let folders = app.photos
            try app.main { model in
                model.showFolder(folders)
                model.showModule(.develop)
            }
            try app.wait("the photos folder again", timeout: 20) { $0.folder == folders && !$0.library.isListing }
            try app.openWorking()
        }

        /// A folder holding only a folder with a photo in it: counted and shown with Show Photos in Subfolders,
        /// turned on and off from the View menu, a folder's own menu and the palette. The run starts with it
        /// off (`scripts/e2e.py`), as its photos folder keeps photos that don't open in subfolders.
        static let subfolders = Scenario(
            "library.subfolder-counts",
            "Show Photos in Subfolders from the View menu, a folder's menu and the palette: a folder of folders counted and shown",
            claims: [.action(.showPhotosInSubfolders), .feature("library.subfolders"), .feature("library.folders")],
        ) { app in
            let outer = app.photos.appending(path: "Folder of Folders", directoryHint: .isDirectory)
            let inner = outer.appending(path: "Inner", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: outer)
            try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outer) }
            try app.openWorking()
            let photo = try inner.appending(path: app.workingPhoto())
            try FileManager.default.copyItem(at: app.photos.appending(path: app.workingPhoto()), to: photo)
            let folders = app.photos
            try app.main { model in
                model.expandedSidebarSections.insert(.folders)
                model.library.setExpanded(folders, true)
                model.library.setExpanded(outer, true)
            }
            if try app.main({ $0.library.includesSubfolders }) {
                try app.choose(.showPhotosInSubfolders)
            }
            try app.wait("the library to count the folder of folders, its own photos only", timeout: 60) { model in
                model.library.photoCount(of: outer) == 0 && model.library.photoCount(of: inner) == 1
            }

            // The View menu: the folder counts the photo below it, and opening it shows it.
            let own = try app.main { $0.library.photoCount(of: folders) ?? 0 }
            try app.choose(.showPhotosInSubfolders)
            try app.wait("the folder of folders counting the photo below it", timeout: 60) { model in
                model.library.includesSubfolders && model.library.photoCount(of: outer) == 1
                    && model.library.photoCount(of: folders) ?? 0 > own
            }
            try app.main { $0.showFolder(outer) }
            do {
                try app.wait("the folder of folders showing the photo beneath it", timeout: 20) { model in
                    model.folder == outer && !model.library.isListing && model.items.map(\.url) == [photo]
                }
            } catch {
                let state = try app.main { model in
                    "\(model.folder?.path ?? "no folder"), \(model.items.map(\.url.path)), listing \(model.library.isListing)"
                }
                throw ScenarioFailure("\(error) (\(state))")
            }
            app.covered([.feature("library.subfolders"), .feature("library.folders")], via: .model)

            // Its own menu turns it off: the folder shows and counts only its own photos, none.
            let row = "folders." + outer.standardizedFileURL.path
            try app.main { $0.library.listTree(folders, lane: .onScreen) }
            do {
                try app.wait("the folder of folders' row in the Folders panel") { _ in
                    Views.editorWindow.flatMap { Views.find(row, in: $0) } != nil
                }
            } catch {
                let rows = try app.main { _ -> [String] in
                    guard let root = Views.editorWindow?.contentView?.superview else { return [] }
                    return Views.all(NSView.self, in: root).compactMap { view in
                        view.accessibilityIdentifier().hasPrefix("folders.") && !view.isHiddenOrHasHiddenAncestor
                            ? view.accessibilityIdentifier() : nil
                    }
                }
                throw ScenarioFailure("\(error) (rows on screen: \(rows))")
            }
            try app.rightClick(.identifier(row), choosing: ShortcutAction.showPhotosInSubfolders.title)
            try app.wait("the folder of folders empty without its subfolders", timeout: 20) { model in
                !model.library.includesSubfolders && !model.library.isListing && model.items.isEmpty
                    && model.library.photoCount(of: outer) == 0
            }
            app.covered([.action(.showPhotosInSubfolders), .feature("library.folders")], via: .mouse)

            // The palette turns it on again.
            try app.runFromPalette(.showPhotosInSubfolders)
            do {
                try app.wait("the photo beneath the folder again", timeout: 20) { model in
                    model.library.includesSubfolders && !model.library.isListing && model.items.map(\.url) == [photo]
                }
            } catch {
                let state = try app.main { model in
                    "\(model.folder?.path ?? "no folder"), \(model.items.map(\.url.path)), listing \(model.library.isListing)"
                }
                throw ScenarioFailure("\(error) (\(state))")
            }

            // As the run had it.
            try app.choose(.showPhotosInSubfolders)
            try app.main { $0.showFolder(folders) }
            try app.wait("the photos folder again", timeout: 20) { $0.folder == folders && !$0.library.isListing }
            try app.openWorking()
        }

        /// The Folders panel counting lib-1m's top folders from a copy of its index while their counts change
        /// (each top folder gaining a photo, then losing it): the main thread's turns, which the budget wants
        /// under 8.3 ms at p99 (LIB-10). Skipped where the fixture or its index isn't.
        static let folderCounts = Scenario(
            "performance.folder-counts", "The Folders panel counting lib-1m's folders while their counts change",
            tiers: [.performance], claims: [],
        ) { app in
            let fixture = URL(
                fileURLWithPath: "/Volumes/SSD/redlamp-tmp/library-fixtures/lib-1m.noindex", isDirectory: true,
            )
            let master = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/indexfix/lib-1m-master/Index.sqlite")
            guard FileManager.default.fileExists(atPath: fixture.path),
                  FileManager.default.fileExists(atPath: master.path)
            else { throw ScenarioSkip("lib-1m and its index aren't on this Mac") }
            // A clone beside the master, on its volume, removed afterwards.
            let work = master.deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "folder-counts-\(UUID().uuidString)", directoryHint: .isDirectory)
            let paths = LibraryPaths(root: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.copyItem(at: master, to: paths.index)

            let counting = CountingBox()
            defer { try? app.main { _ in counting.close() } }
            try app.main { model in
                let library = FolderLibrary()
                library.add([fixture])
                library.setExpanded(fixture, true)
                let service = LibraryService(paths: paths, sidecars: library.sidecars) { _, _ in nil }
                library.attach(service)
                let editor = EditorModel(engine: model.makeWorkerEngine?() ?? model.engine, library: library)
                let window = NSWindow(
                    contentRect: CGRect(x: 0, y: 0, width: 280, height: 900), styleMask: [.titled],
                    backing: .buffered, defer: false,
                )
                window.contentView = SidebarListViews.make(model: editor)
                window.contentView?.layoutSubtreeIfNeeded()
                counting.open(library: library, service: service, editor: editor, window: window)
            }
            try app.wait("lib-1m counted from its index", timeout: 300) { _ in
                counting.library.map { $0.photoCount(of: fixture) ?? 0 > 900_000 } ?? false
            }
            let tops = try app.main { _ in counting.library?.node(for: fixture)?.subfolders ?? [] }
            try app.expect(tops.count > 20, "the panel lists \(tops.count) of lib-1m's top folders")
            try app.wait("every top folder counted", timeout: 30) { _ in
                tops.allSatisfy { counting.library?.photoCount(of: $0) != nil }
            }

            let monitor = try MainThread.run { () -> MainThreadMonitorBox in
                let monitor = MainThreadMonitor()
                monitor.start()
                return MainThreadMonitorBox(monitor)
            }
            let started = Date()
            var changes = 0
            for step in 0 ..< 24 {
                try app.run("changing the top folders' counts", timeout: 60) { _ in
                    await counting.change(adding: step.isMultiple(of: 2), to: tops)
                }
                changes += 1
                app.pause(0.5)
            }
            try app.run("the last counts", timeout: 30) { _ in await counting.library?.countedFolders() }
            let seconds = Date().timeIntervalSince(started)
            let summary = try MainThread.run { () -> MainThreadMonitor.Summary? in
                monitor.monitor.stop()
                return monitor.monitor.summary(seconds: seconds)
            }
            guard let summary else { throw ScenarioFailure("No main-thread turns while the counts changed") }
            app.record("e2e-folder-counts-p99", summary.p99)
            app.record("e2e-folder-counts-max", summary.max)
            app.recorder.write("note", [
                "folder-counts": "\(changes) changes to \(tops.count) top folders' counts in \(String(format: "%.1f", seconds)) s: "
                    + "p50 \(summary.p50) ms, p95 \(summary.p95) ms, p99 \(summary.p99) ms, max \(summary.max) ms, "
                    + "\(summary.overFrame) turns over 8.3 ms",
            ])
            try app.expect(summary.p99 < 8.3, "The main thread's p99 was \(summary.p99) ms while the counts changed")
        }
    }

    /// The performance scenario's own library and Folders panel, kept on the main thread.
    @MainActor
    private final class CountingBox: @unchecked Sendable {
        private(set) var library: FolderLibrary?
        private var service: LibraryService?
        private var editor: EditorModel?
        private var window: NSWindow?

        func open(library: FolderLibrary, service: LibraryService, editor: EditorModel, window: NSWindow) {
            self.library = library
            self.service = service
            self.editor = editor
            self.window = window
        }

        /// Gives each of `folders` a photo of its own, or takes it away again, then has the library count.
        func change(adding: Bool, to folders: [URL]) async {
            guard let library, let index = library.libraryIndex else { return }
            let paths = folders.map { LibraryCountingPaths.path($0) }
            _ = try? await index.write { writer in
                for path in paths {
                    if adding {
                        let insert = try writer.database.cached("""
                        INSERT INTO photos (folder, name, kind, size, modified)
                        SELECT id, 'folder-counts.jpg', 0, 1, 0 FROM folders WHERE path = ?
                        """)
                        try insert.bind(path, at: 1)
                        try insert.run()
                    } else {
                        let delete = try writer.database.cached("""
                        DELETE FROM photos WHERE name = 'folder-counts.jpg' AND folder = (SELECT id FROM folders WHERE path = ?)
                        """)
                        try delete.bind(path, at: 1)
                        try delete.run()
                    }
                }
            }
            library.countFolders()
        }

        func close() {
            window?.contentView = nil
            service?.close()
            window = nil
            editor = nil
            library = nil
            service = nil
        }
    }

    /// The paths the index keeps.
    private enum LibraryCountingPaths {
        static func path(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
    }
#endif
