#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import RedlampDesign
    import RedlampDocument
    import RedlampEngineAPI
    import RedlampLibrary
    @_spi(Harness) import RedlampUI
    import Synchronization

    /// A folder removed from Folders (LIB-10) and Previous Import following a newer import (LIB-23, LIB-27), each
    /// through the input a person uses: a root row's menu, the palette and the import window's Import button.
    extension LibraryPanelScenarios {
        /// Remove from Folders, from a root's menu: its photos leave All Photographs (shown), a collection, Library
        /// Health and searches, nothing on disk changes, and the folder added again brings them back from their
        /// sidecars, its rating, keyword and collection with them.
        static let removedFolder = Scenario(
            "library.remove-folder",
            "Remove from Folders from a root's menu: its photos leave All Photographs, a collection, Library Health and "
                + "searches, and come back from their sidecars when the folder is added again",
            claims: [.feature("library.folders"), .feature("library.library-panel"), .feature("library.collections")],
        ) { app in
            let scratch = try SourcesScratch(
                app, photos: ["Removed A.jpg", "Removed B.jpg"], empty: ["Removed Empty.jpg"],
            )
            let tag = scratch.folder.lastPathComponent.suffix(8)
            let collection = "Picks \(tag)"
            let keyword = "Removed \(tag)"
            let rated = scratch.photo("Removed A.jpg")
            try SidecarStore().save(
                Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(
                    rating: 4, keywords: [keyword], collections: [collection],
                )),
                for: rated,
            )
            defer {
                app.removeCollectionsMade()
                scratch.remove(app)
            }
            try scratch.index(app)
            let names = scratch.names + ["Removed Empty.jpg"]
            try app.wait("the folder counted in the Library panel", timeout: 60) { model in
                model.librarySources.recount()
                return model.librarySources.count(of: .collection(CollectionPath(collection)!)) == 1
            }
            let all = try app.main { $0.librarySources.count(of: .allPhotographs) ?? 0 }
            try app.runFromPalette(.showAllPhotographs)
            try app.waitForSource("All Photographs with the folder's photos", timeout: 60) { model in
                model.librarySources.shown == .allPhotographs && !model.librarySources.isListing
                    && Set(names).isSubset(of: Set(model.items.map(\.name)))
            }
            try app.expect(
                try app.main { model in model.librarySources.healthEntries.contains(.health(.damaged)) },
                "Library Health's Damaged Files has the empty file",
            )
            let tagged = KeywordPath(keyword)!
            try app.main { model in
                if !model.libraryPanels.isExpanded(.keywordList) {
                    model.libraryPanels.toggle(.keywordList)
                }
            }
            try app.wait("the Keyword List counting the folder's keyword", timeout: 60) { model in
                model.libraryPanels.refreshKeywords()
                return model.libraryPanels.keywordList?.keywords[tagged]?.photos == 1
            }

            // The root's menu removes it: everything the library shows leaves its photos out, and the Library
            // panel and the Keyword List count again on their own, as they count from the index.
            let row = "folders." + scratch.folder.standardizedFileURL.path
            try app.main { model in model.expandedSidebarSections.insert(.folders) }
            try app.wait("the folder's row in the Folders panel") { _ in
                Views.editorWindow.flatMap { Views.find(row, in: $0) } != nil
            }
            try app.rightClickRow(row, choosing: "Remove from Folders")
            try app.waitForSource("All Photographs without the folder's photos", timeout: 30) { model in
                model.librarySources.shown == .allPhotographs
                    && Set(model.items.map(\.name)).isDisjoint(with: Set(names))
            }
            try app.wait("the Library panel and the Keyword List counting without them", timeout: 60) { model in
                let sources = model.librarySources
                return sources.count(of: .allPhotographs) == all - names.count
                    && sources.count(of: .collection(CollectionPath(collection)!)) ?? 0 == 0
                    && model.libraryPanels.keywordList?.keywords[tagged]?.photos ?? 0 == 0
            }
            let found = try app.photosFound("kw:\"\(keyword)\"")
            try app.expect(found == 0, "a search finds \(found) of the folder's photos")
            try app.expect(
                FileManager.default.fileExists(atPath: SidecarLocator.besidePhoto(rated).path),
                "the photo's sidecar is where it was",
            )
            try app.expect(
                try app.main { model in model.library.root(containing: scratch.folder) == nil },
                "the folder is out of Folders",
            )
            app.covered([.feature("library.folders"), .feature("library.library-panel")], via: .mouse)

            // Added again, the folder's sidecars bring back its rating, keyword and collection.
            try scratch.index(app)
            try app.runFromPalette(.showAllPhotographs)
            try app.wait("the folder's photos back, with their collection", timeout: 60) { model in
                model.librarySources.recount()
                return model.librarySources.count(of: .collection(CollectionPath(collection)!)) == 1
                    && Set(names).isSubset(of: Set(model.items.map(\.name)))
            }
            let back = try app.photosFound("kw:\"\(keyword)\" rating>=4")
            try app.expect(back == 1, "the rated photo with its keyword: \(back)")
            app.covered(.feature("library.collections"), via: .model)

            // As the run had it.
            let photos = app.photos
            try app.main { model in
                model.showFolder(photos)
                model.showModule(.develop)
            }
            try app.wait("the photos folder again", timeout: 20) { $0.folder == photos && !$0.library.isListing }
        }

        /// ⌘Z after Remove from Folders: a culling change made in a folder that then left the library from its root's
        /// menu reaches none of the photos of a folder added after it, which SQLite would have given its photos' IDs.
        static let removedFolderUndo = Scenario(
            "library.remove-folder-undo",
            "⌘Z after Remove from Folders and another folder added: the change made in the folder that left reaches "
                + "none of the new folder's photos",
            claims: [.action(.undo), .feature("library.folders")],
        ) { app in
            let left = try SourcesScratch(app, photos: ["Left A.jpg", "Left B.jpg"])
            let later = try SourcesScratch(app, photos: ["Later A.jpg", "Later B.jpg"])
            defer {
                left.remove(app)
                later.remove(app)
            }
            func rated(_ scratch: SourcesScratch) -> Bool {
                scratch.names.allSatisfy { SidecarStore().load(for: scratch.photo($0))?.metadata?.rating == 5 }
            }

            // Five stars on both of the first folder's photos from the keyboard: one culling change, on Undo.
            try left.index(app)
            try app.choose(.selectAllPhotos)
            try app.wait("both photos selected") { $0.selectedPhotos.count == 2 }
            try app.press(.rating5)
            try app.waitWritten()
            try app.wait("their sidecars rated", timeout: 15) { _ in rated(left) }

            // The folder leaves the library from its root's menu; its rows are swept.
            let row = "folders." + left.folder.standardizedFileURL.path
            try app.main { model in model.expandedSidebarSections.insert(.folders) }
            try app.wait("the folder's row in the Folders panel") { _ in
                Views.editorWindow.flatMap { Views.find(row, in: $0) } != nil
            }
            try app.rightClickRow(row, choosing: "Remove from Folders")
            try app.run("the folder's rows swept", timeout: 120) { model in
                await model.library.service?.removalsSwept()
            }

            // A folder whose photos have five stars already is added after it.
            for name in later.names {
                try SidecarStore().save(
                    Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 5)), for: later.photo(name),
                )
            }
            try later.index(app)
            try app.wait("the new folder's photos with their stars") { model in
                Set(model.items.map(\.name)) == Set(later.names) && model.items.allSatisfy { $0.metadata.rating == 5 }
            }

            // ⌘Z takes back the change made in the folder that left: the new folder's photos keep their stars.
            try app.wait("the change on Library's Undo") { $0.canPerform(.undo) }
            try app.press(.undo)
            try app.waitWritten()
            try app.run("the library caught up with the Undo", timeout: 60) { model in
                await model.library.service?.settled()
            }
            try app.expect(rated(later), "the new folder's sidecars kept their stars")
            try app.expect(
                try app.main { model in model.items.allSatisfy { $0.metadata.rating == 5 } },
                "the grid shows their stars",
            )
            app.covered(.action(.undo), via: .key)
            app.covered(.feature("library.folders"), via: .mouse)

            // As the run had it.
            let photos = app.photos
            try app.main { model in
                model.showFolder(photos)
                model.showModule(.develop)
            }
            try app.wait("the photos folder again", timeout: 20) { $0.folder == photos && !$0.library.isListing }
        }

        /// Previous Import, shown from the palette, while the import window imports another card: it shows that
        /// import's photos, selected, rather than giving way to the destination's folder.
        static let previousImportFollows = Scenario(
            "library.previous-import-follows",
            "Previous Import, shown, shows the photos of an import the import window finishes, as Lightroom Classic's does",
            claims: [.action(.showPreviousImport), .feature("library.import"), .feature("library.library-panel")],
        ) { app in
            let first = try FollowedImportScratch(app, photos: 1)
            let second = try FollowedImportScratch(app, photos: 2)
            defer {
                first.remove(app)
                second.remove(app)
            }
            try app.main { _ in ImportWindowController.ignoresVolumes = true }
            try first.importThroughWindow(app)
            try app.main { _ in ImportWindowController.current?.close() }
            try app.wait("the first import counted as Previous Import", timeout: 60) { model in
                model.librarySources.recount()
                return model.librarySources.count(of: .previousImport) == first.names.count
            }
            try app.runFromPalette(.showPreviousImport)
            try app.waitForSource("Previous Import with the first import's photo", timeout: 30) { model in
                model.librarySources.shown == .previousImport && model.items.map(\.name) == first.names
            }
            app.covered(.action(.showPreviousImport), via: .palette)

            // The import window imports the second card while Previous Import is shown.
            try second.importThroughWindow(app)
            try app.waitForSource("Previous Import with the second import's photos", timeout: 60) { model in
                model.librarySources.shown == .previousImport && !model.librarySources.isListing
                    && model.items.map(\.name).sorted() == second.names.sorted()
            }
            let (folder, selected) = try app.main { model in (model.folder, model.selection?.lastPathComponent) }
            try app.expect(folder == nil, "the destination's folder took Previous Import's place")
            try app.expect(selected.map(second.names.contains) == true, "the photo active is \(selected ?? "none")")
            app.covered([.feature("library.import"), .feature("library.library-panel")], via: .mouse)

            // As the run had it.
            let photos = app.photos
            try app.main { model in
                ImportWindowController.current?.close()
                model.showFolder(photos)
                model.showModule(.develop)
            }
            try app.wait("the photos folder again", timeout: 20) { $0.folder == photos && !$0.library.isListing }
        }
    }

    extension LibraryPanelScenarios {
        /// Removing a root of 150,000 photos, lib-1m's Clients, from a copy of its index split into a root per top
        /// folder as Folders would hold them, with Rejected shown: the time until the store and searches, the source
        /// shown and the Library panel's counts leave its photos out, the main thread meanwhile, and the sweep of its
        /// rows behind them. Only the copy is written; the fixture is listed by change tracking, nothing more.
        /// Skipped where the fixture or its index isn't.
        static let removeFolderPerformance = Scenario(
            "performance.remove-folder",
            "Removing a root of 150,000 photos from a copy of lib-1m's index, Rejected shown: the views leaving them "
                + "out, the main thread meanwhile, and the sweep",
            tiers: [.performance], claims: [],
        ) { app in
            try measureRemoval(app, showing: .rejected, named: "Rejected", within: "flag:reject", metric: "rejected")
        }

        /// The same with All Photographs shown, a million photos, where a change of 150,000 is the largest a source
        /// shown takes.
        static let removeFolderAllPerformance = Scenario(
            "performance.remove-folder-all",
            "Removing a root of 150,000 photos from a copy of lib-1m's index, All Photographs shown",
            tiers: [.performance], claims: [],
        ) { app in
            try measureRemoval(app, showing: .allPhotographs, named: "All Photographs", within: "", metric: "all")
        }

        /// Removes Clients with `source` shown, whose photos `query` narrows to, and notes and judges what it took.
        private static func measureRemoval(
            _ app: RunningApp, showing source: LibrarySource, named name: String, within query: String,
            metric: String,
        ) throws {
            let fixture = URL(
                fileURLWithPath: "/Volumes/SSD/redlamp-tmp/library-fixtures/lib-1m.noindex", isDirectory: true,
            )
            let master = URL(fileURLWithPath: "/Volumes/SSD/redlamp-tmp/indexfix/lib-1m-master/Index.sqlite")
            guard FileManager.default.fileExists(atPath: fixture.path),
                  FileManager.default.fileExists(atPath: master.path)
            else { throw ScenarioSkip("lib-1m and its index aren't on this Mac") }
            // A clone beside the master, on its volume, removed afterwards.
            let work = master.deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "remove-folder-\(UUID().uuidString)", directoryHint: .isDirectory)
            let paths = LibraryPaths(root: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.copyItem(at: master, to: paths.index)
            let clients = fixture.appending(path: "Clients", directoryHint: .isDirectory)
            let box = RemovalBenchBox()
            try app.run("a root per top folder written into the copy", timeout: 120) { _ in
                await box.split(paths, fixture: fixture, removing: clients)
            }
            try app.expect(box.tops.count > 20 && box.removing > 100_000, "\(box.tops.count) roots, \(box.removing)")

            try app.main { model in
                let library = FolderLibrary()
                library.add(box.tops)
                let service = LibraryService(paths: paths, sidecars: library.sidecars) { _, _ in nil }
                library.attach(service)
                let editor = EditorModel(engine: model.makeWorkerEngine?() ?? model.engine, library: library)
                editor.showModule(.library)
                let window = NSWindow(
                    contentRect: CGRect(x: 0, y: 0, width: 280, height: 900), styleMask: [.titled],
                    backing: .buffered, defer: false,
                )
                window.contentView = LibrarySourcesViews.make(model: editor)
                window.contentView?.layoutSubtreeIfNeeded()
                box.open(library: library, service: service, editor: editor, window: window)
            }
            defer { try? app.main { _ in box.close() } }
            try app.wait("lib-1m counted from its index", timeout: 300) { _ in
                box.editor?.librarySources.count(of: .allPhotographs) ?? 0 > 900_000
            }
            try app.run("change tracking's first pass over the fixture", timeout: 600) { _ in
                await box.caughtUp(clients, fixture.appending(path: "2024", directoryHint: .isDirectory))
            }
            let (total, holding) = try app.main { _ in
                (
                    box.editor?.librarySources.count(of: .allPhotographs) ?? 0,
                    box.editor?.librarySources.count(of: source) ?? 0,
                )
            }
            let inClients = try app.photosFound(
                in: box,
                (query + " folder:Clients").trimmingCharacters(in: .whitespaces),
            )
            try app.main { _ in _ = box.editor?.librarySources.show(source) }
            try app.wait("\(name) shown", timeout: 900) { _ in
                guard let editor = box.editor else { return false }
                return !editor.librarySources.isListing && editor.items.count == holding
            }
            let left = holding - inClients

            let views = try MainThread.run { () -> MainThreadMonitorBox in
                let monitor = MainThreadMonitor()
                monitor.start()
                return MainThreadMonitorBox(monitor)
            }
            let started = Date()
            try app.main { _ in
                box.watch(leaving: left, of: total - box.removing, since: started)
                box.remove(clients)
            }
            try app.wait("\(name) without Clients", timeout: 120) { _ in box.editor?.items.count == left }
            let shown = try app.main { _ in box.shownAt } ?? Date().timeIntervalSince(started) * 1000
            let call = try app.main { _ in box.removingTook } ?? 0
            try app.wait("the Library panel counting without Clients", timeout: 120) { _ in
                box.editor?.librarySources.count(of: .allPhotographs) == total - box.removing
            }
            let counted = Date().timeIntervalSince(started) * 1000
            let viewing = try MainThread.run { () -> MainThreadMonitor.Summary? in
                views.monitor.stop()
                return views.monitor.summary(seconds: counted / 1000)
            }
            let found = try app.photosFound(in: box, "folder:Clients")
            let sweeping = try MainThread.run { () -> MainThreadMonitorBox in
                let monitor = MainThreadMonitor()
                monitor.start()
                return MainThreadMonitorBox(monitor)
            }
            try app.wait("the sweep of Clients' rows", timeout: 900) { _ in box.swept != nil }
            let sweep = try MainThread.run { () -> MainThreadMonitor.Summary? in
                sweeping.monitor.stop()
                return sweeping.monitor.summary(seconds: max(box.swept ?? 0, 1) / 1000)
            }
            let store = box.storeLeft ?? .infinity
            let swept = box.swept ?? .infinity
            app.record("e2e-remove-folder-\(metric)-store", store)
            app.record("e2e-remove-folder-\(metric)-shown", shown)
            app.record("e2e-remove-folder-\(metric)-counted", counted)
            app.record("e2e-remove-folder-\(metric)-swept", swept)
            if let viewing {
                app.record("e2e-remove-folder-\(metric)-p99", viewing.p99)
                app.record("e2e-remove-folder-\(metric)-max", viewing.max)
            }
            if let sweep {
                app.record("e2e-remove-folder-\(metric)-sweep-p99", sweep.p99)
            }
            func turns(_ summary: MainThreadMonitor.Summary?) -> String {
                summary.map { "p50 \($0.p50) ms, p95 \($0.p95) ms, p99 \($0.p99) ms, max \($0.max) ms" } ?? "-"
            }
            app.recorder.write("note", [
                "remove-folder-\(metric)": "\(box.removing.formatted()) of \(total.formatted()) photos, \(name) "
                    + "shown (\(holding.formatted()), \(inClients.formatted()) of them in Clients): out of the store "
                    + "and searches in \(String(format: "%.0f", store)) ms, of \(name) in "
                    + "\(String(format: "%.0f", shown)) ms, of the Library panel's counts in "
                    + "\(String(format: "%.0f", counted)) ms, main thread \(turns(viewing)), Folders' own call "
                    + "\(String(format: "%.1f", call)) ms; swept in "
                    + "\(String(format: "%.1f", swept / 1000)) s, main thread \(turns(sweep)); load "
                    + "\(ProcessInfo.processInfo.loadAverage)",
            ])
            try app.expect(found == 0, "a search for its folder finds \(found) photos")
            try app.expect((viewing?.p99 ?? 0) < 8.3, "The main thread's p99 was \(viewing?.p99 ?? 0) ms")
            try app.expect(shown < 300, "\(name) took \(shown) ms to leave Clients out")
        }
    }

    /// The performance scenario's own library, panels and window, kept on the main thread, and when what it watches
    /// happened.
    @MainActor
    private final class RemovalBenchBox: @unchecked Sendable {
        private(set) var library: FolderLibrary?
        private(set) var service: LibraryService?
        private(set) var editor: EditorModel?
        private var window: NSWindow?
        /// The fixture's top folders, a root each, and the photos of the one removed.
        private(set) nonisolated(unsafe) var tops: [URL] = []
        private(set) nonisolated(unsafe) var removing = 0
        /// Milliseconds from the removal until the store left its photos out, until the photos shown did, and until
        /// its rows were swept.
        nonisolated(unsafe) var storeLeft: Double?
        private(set) var shownAt: Double?
        nonisolated(unsafe) var swept: Double?
        private var observation: LibraryObservation?

        /// Makes each of the fixture's top folders a root of its own in the copy's index, as Folders would hold them.
        nonisolated func split(_ paths: LibraryPaths, fixture: URL, removing removed: URL) async {
            guard let index = try? await LibraryIndex.open(at: paths.index, readers: 2) else { return }
            let (root, removedPath) = (Self.path(fixture), Self.path(removed))
            let split = try? await index.write { writer -> (tops: [String], removing: Int) in
                let listing = try writer.database.cached("""
                SELECT path FROM folders WHERE parent = (SELECT id FROM folders WHERE path = ?) ORDER BY path
                """)
                try listing.bind(root, at: 1)
                let tops = try listing.map { $0.string(at: 0) ?? "" }
                let volume = try writer.root(path: root)?.volume ?? 0
                let own = try writer.database.cached("""
                UPDATE folders SET root = ?4 WHERE path = ?1 OR (path >= ?2 AND path < ?3)
                """)
                let top = try writer.database.cached("UPDATE folders SET parent = NULL WHERE path = ?")
                for path in tops {
                    let id = try writer.upsertRoot(RootRecord(volume: volume, path: path))
                    try own.bind(path, at: 1)
                    try own.bind(path + "/", at: 2)
                    try own.bind(path + "0", at: 3)
                    try own.bind(id, at: 4)
                    try own.run()
                    try top.bind(path, at: 1)
                    try top.run()
                }
                let count = try writer.database.cached("""
                SELECT count(*) FROM photos WHERE folder IN
                  (SELECT id FROM folders WHERE root = (SELECT id FROM roots WHERE path = ?))
                """)
                try count.bind(removedPath, at: 1)
                return try (tops, count.first { $0.int(at: 0) } ?? 0)
            }
            await index.close()
            tops = (split?.tops ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
            removing = split?.removing ?? 0
        }

        func open(library: FolderLibrary, service: LibraryService, editor: EditorModel, window: NSWindow) {
            self.library = library
            self.service = service
            self.editor = editor
            self.window = window
        }

        /// Returns once change tracking has caught up with the roots of `folders`.
        func caughtUp(_ folders: URL...) async {
            guard let service else { return }
            for folder in folders {
                for _ in 0 ..< 6000 where await !service.canShow(folder, includingSubfolders: true) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }

        /// How long `remove` held the main thread, in milliseconds.
        private(set) var removingTook: Double?

        func remove(_ folder: URL) {
            guard let library, let root = library.root(containing: folder) else { return }
            let started = Date()
            library.remove(root)
            removingTook = Date().timeIntervalSince(started) * 1000
        }

        /// Notes when the photos shown come to `leaving`, and, off the main thread, when the store holds `kept`
        /// photos and when no root is marked removed.
        func watch(leaving: Int, of kept: Int, since started: Date) {
            guard let library, let engine = service?.engine, let index = library.libraryIndex else { return }
            observation = library.observe { [weak self, weak library] _ in
                guard let self, shownAt == nil, library?.count == leaving else { return }
                shownAt = Date().timeIntervalSince(started) * 1000
            }
            Task.detached(priority: .userInitiated) { [self] in
                while await (try? engine.list(.allPhotographs).count) != kept {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                storeLeft = Date().timeIntervalSince(started) * 1000
                while await (try? index.read { try $0.removedRoots().isEmpty }) != true {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                swept = Date().timeIntervalSince(started) * 1000
            }
        }

        func close() {
            window?.contentView = nil
            service?.close()
            window = nil
            editor = nil
            library = nil
            service = nil
        }

        private nonisolated static func path(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
    }

    fileprivate extension RunningApp {
        /// How many photos `box`'s library finds for `query`; -1 when it can't search.
        func photosFound(in box: RemovalBenchBox, _ query: String) throws -> Int {
            let found = Mutex(-1)
            let engine = try main { _ in box.service?.engine }
            try run("searching for \(query)", timeout: 30) { _ in
                guard let engine, let parsed = try? LibraryQuery(parsing: query),
                      let list = try? await engine.list(.query(parsed))
                else { return }
                found.withLock { $0 = list.count }
            }
            return found.withLock { $0 }
        }
    }

    extension RunningApp {
        /// Right-clicks the row carrying `identifier` where `frame(of:)` finds it, as the mouse does, and chooses
        /// `title` in the menu that opens. The menu tracks inside the press, so the main thread is asked nothing
        /// until the press has begun: a question queued with it would wait behind the menu, which waits for it.
        func rightClickRow(_ identifier: String, choosing title: String) throws {
            step("right-clicking \(identifier)")
            let frame = try frame(of: .identifier(identifier))
            let location = NSPoint(x: frame.midX, y: frame.midY)
            let opened = OpenedMenu()
            try main { _ in opened.watch() }
            defer { try? main { _ in opened.stop() } }
            let pressed = Flag()
            post { _ in
                pressed.set()
                guard let window = Views.editorWindow else { return }
                for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .rightMouseUp ? 0 : 1,
                    ) else { continue }
                    window.sendEvent(event)
                }
            }
            for _ in 0 ..< 1000 where !pressed.isSet {
                pause(0.01)
            }
            try wait("\(identifier)'s context menu to open") { _ in opened.menu != nil }
            try main { _ in
                guard let menu = opened.menu else { return }
                defer { menu.cancelTracking() }
                guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
                    throw ScenarioFailure("\(identifier)'s menu has no \(title): \(menu.items.map(\.title))")
                }
                menu.performActionForItem(at: index)
            }
            try wait("\(identifier)'s context menu to close") { _ in opened.closed }
        }

        /// How many photos the library finds for `query`; -1 when it can't search.
        func photosFound(_ query: String) throws -> Int {
            let found = Mutex(-1)
            try run("searching for \(query)", timeout: 30) { model in
                guard let engine = model.library.service?.engine, let parsed = try? LibraryQuery(parsing: query),
                      let list = try? await engine.list(.query(parsed))
                else { return }
                found.withLock { $0 = list.count }
            }
            return found.withLock { $0 }
        }
    }

    /// A card of copies of the run's raws, each made its own by bytes after its end of a length drawn for the card, so
    /// no
    /// earlier import or card has it, imported into a destination of its own; taken out of Folders and removed after.
    struct FollowedImportScratch: Sendable {
        let root: URL
        let card: URL
        let destination: URL
        let names: [String]

        init(_ app: RunningApp, photos count: Int) throws {
            root = app.runDirectory.appending(path: "followed-\(UUID().uuidString)", directoryHint: .isDirectory)
            card = root.appending(path: "Card", directoryHint: .isDirectory)
            destination = root.appending(path: "Pictures", directoryHint: .isDirectory)
            let raws = ["arw", "raf", "cr3", "nef", "dng"]
            let originals = try FileManager.default.contentsOfDirectory(atPath: app.photos.path)
                .filter { raws.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
            guard !originals.isEmpty else { throw ScenarioFailure("The run has no raws to copy") }
            try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
            // A content key is the size and the first 64 KiB: each copy gets a length of its own.
            let extra = Int.random(in: 1 ... 1 << 16)
            var names: [String] = []
            for number in 0 ..< count {
                let original = originals[number % originals.count]
                let name = String(format: "IMG_%04d.", number) + (original as NSString).pathExtension
                let copy = card.appending(path: name)
                try FileManager.default.copyItem(at: app.photos.appending(path: original), to: copy)
                let handle = try FileHandle(forWritingTo: copy)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(count: extra + number))
                try handle.close()
                names.append(name)
            }
            self.names = names
        }

        /// Opens the import window from the File menu, adds the card and presses Import, and waits for it to finish.
        func importThroughWindow(_ app: RunningApp) throws {
            try app.choose(.importPhotos)
            try app.waitForImportWindow()
            try app.inImportWindow { window in
                window.prepare(destination: destination, backup: nil, folders: "", names: "{name}")
            }
            let card = card
            try app
                .run("adding the card", timeout: 30) { _ in
                    try? await ImportWindowController.current?.add(folder: card)
                }
            let count = names.count
            try app.wait("the card browsed", timeout: 60) { _ in
                ImportWindowController.current.map { $0.isBrowsed && $0.photoCount == count } == true
            }
            try app.clickInImportWindow("import.import")
            try app.wait("the import", timeout: 120) { _ in ImportWindowController.current?.isFinished == true }
        }

        func remove(_ app: RunningApp) {
            let destination = destination
            try? app.main { model in
                ImportWindowController.current?.close()
                ImportWindowController.forget(destination, in: model)
                ImportWindowController.ignoresVolumes = false
            }
            try? FileManager.default.removeItem(at: root)
        }
    }
#endif
