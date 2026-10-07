#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// The sources the Folders panel chooses (LIB-10): folders counted with their subfolders' photos, and a
    /// folder of folders showing every photo beneath it.
    enum SourceScenarios {
        static let all: [Scenario] = [subfolders, folderCounts]

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
            try app.click(.identifier("folders." + outer.standardizedFileURL.path))
            try app.wait("the folder of folders showing the photo beneath it", timeout: 20) { model in
                model.folder == outer && !model.library.isListing && model.items.map(\.url) == [photo]
            }
            app.covered([.feature("library.subfolders"), .feature("library.folders")], via: .mouse)

            // Its own menu turns it off: the folder shows and counts only its own photos, none.
            try app.rightClick(
                .identifier("folders." + outer.standardizedFileURL.path),
                choosing: ShortcutAction.showPhotosInSubfolders.title,
            )
            try app.wait("the folder of folders empty without its subfolders", timeout: 20) { model in
                !model.library.includesSubfolders && !model.library.isListing && model.items.isEmpty
                    && model.library.photoCount(of: outer) == 0
            }
            app.covered(.action(.showPhotosInSubfolders), via: .mouse)

            // The palette turns it on again.
            try app.runFromPalette(.showPhotosInSubfolders)
            try app.wait("the photo beneath the folder again", timeout: 20) { model in
                model.library.includesSubfolders && !model.library.isListing && model.items.map(\.url) == [photo]
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
