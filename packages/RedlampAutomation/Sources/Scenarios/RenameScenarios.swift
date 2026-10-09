#if DEBUG || REDLAMP_PROFILING
    import AppKit
    import Carbon.HIToolbox
    import RedlampDesign
    import RedlampDocument
    import RedlampEngineAPI
    import RedlampLibrary
    @_spi(Harness) import RedlampUI

    /// Rename Photos and Move to Folder (LIB-25, LIB-26), on copies of the run's photos in a folder of the run's own,
    /// which the scenarios add to Folders and take out again: F2 and the menus, the sheet's template typed with a
    /// token put in from its menu, the preview, Rename, Move to Folder, and ⌘Z and ⇧⌘Z.
    enum RenameScenarios {
        static let all: [Scenario] = [renamePhotos, moveToFolder, undoOrder, performance]

        static let renamePhotos = Scenario(
            "library.rename-photos",
            "F2 opens Rename Photos on the selection, as Library › Rename Photos… does; a template typed with a token "
                + "from its menu names every photo in the preview, Rename renames each with its pair and sidecars, "
                + "and ⌘Z and ⇧⌘Z take it back and make it again, the selection following",
            claims: [.action(.renamePhotos), .feature("library.rename")],
        ) { app in
            let scratch = try RenameScratch(app)
            defer { scratch.remove(app) }
            try scratch.show(app)

            try app.explaining { try app.choose(.renamePhotos) }
            try app.waitForSheet("Rename Photos")
            try app.pressInSheet(KeyCombo(.escape))
            try app.waitForNoSheet("Rename Photos")

            try app.choose(.selectAllPhotos)
            try app.wait("every photo selected") { $0.selectedPhotos.count == scratch.names.count }
            try app.explaining { try app.pressF2() }
            try app.waitForSheet("Rename Photos")
            try app.wait("the photos read and named", timeout: 30) { $0.renameSheetNames != nil }
            try app.selectSheetField()
            try app.typeInAttachedSheet("Trip-")
            try app.chooseToken("{sequence:4:folder}")
            let renamed = scratch.names.map { name in
                let stem = name.hasPrefix("IMG_0001") ? "0001" : String(name.dropFirst(4).prefix(4))
                return "Trip-\(stem).\((name as NSString).pathExtension)"
            }
            try app.wait("the preview to follow the template") { model in
                model.renameSheetNames.map(Set.init) == Set(renamed)
            }
            try app.clickInSheet("rename.rename")
            try app.waitForNoSheet("Rename Photos", timeout: 120)
            try app.wait("the photos renamed, each with its sidecar", timeout: 60) { _ in
                scratch.photos() == renamed.sorted() && renamed.allSatisfy(scratch.hasSidecar)
            }
            try app.wait("the grid showing the new names, every photo still selected") { model in
                Set(model.items.map(\.name)) == Set(renamed) && model.selectedPhotos.count == renamed.count
            }
            app.covered(.action(.renamePhotos), via: .key)
            app.covered(.feature("library.rename"), via: .key)

            try app.press(.undo)
            try app.run("the Undo", timeout: 60) { await $0.filesMade() }
            try app.wait("⌘Z to put the names back", timeout: 30) { model in
                scratch.photos() == scratch.names.sorted() && Set(model.items.map(\.name)) == Set(scratch.names)
                    && model.selectedPhotos.count == scratch.names.count
            }
            try app.expectKeyBinding(.redo)
            try app.choose(.redo)
            try app.run("the Redo", timeout: 60) { await $0.filesMade() }
            try app.wait("⇧⌘Z to rename them again", timeout: 30) { _ in scratch.photos() == renamed.sorted() }
            try app.press(.undo)
            try app.run("the Undo", timeout: 60) { await $0.filesMade() }
            try app.wait("the names as they were", timeout: 30) { _ in scratch.photos() == scratch.names.sorted() }
        }

        static let moveToFolder = Scenario(
            "library.move-to-folder",
            "Photo › Move to Folder… moves the photos selected, with their pairs and sidecars, into a folder of the "
                + "library, the photo after them becoming active, and ⌘Z brings them back selected",
            claims: [.action(.moveToFolder), .feature("library.rename")],
        ) { app in
            let scratch = try RenameScratch(app)
            defer { scratch.remove(app) }
            try scratch.show(app)
            let moving = Array(scratch.names.prefix(2))
            try app.click(.identifier("grid.\(moving[0])"))
            try app.wait("\(moving[0]) alone") { $0.selectedPhotos.map(\.lastPathComponent) == [moving[0]] }
            try app.press(KeyCombo(.right, shift: true))
            try app.wait("the pair selected") { $0.selectedPhotos.map(\.lastPathComponent) == moving }
            try app.main { _ in EditorModel.moveToFolderAnswer = scratch.picked }
            try app.choose(.moveToFolder)
            try app.wait("the pair and its sidecar in Picked", timeout: 60) { _ in
                scratch.photos(in: scratch.picked) == moving.sorted()
                    && scratch.hasSidecar("IMG_0001.JPG", in: scratch.picked)
            }
            try app.wait("the grid without them, the photo after them active", timeout: 30) { model in
                model.items.map(\.name) == Array(scratch.names.dropFirst(2))
                    && model.selection?.lastPathComponent == scratch.names[2]
            }
            app.covered(.feature("library.rename"), via: .menu)

            try app.press(.undo)
            try app.run("the Undo", timeout: 60) { await $0.filesMade() }
            try app.wait("⌘Z to bring them back, selected", timeout: 30) { model in
                scratch.photos() == scratch.names.sorted() && scratch.photos(in: scratch.picked).isEmpty
                    && Set(model.selectedPhotos.map(\.lastPathComponent)) == Set(moving)
            }
        }

        static let undoOrder = Scenario(
            "library.undo-order",
            "A rating by its key, a keyword typed in the Keywording panel and Photo › Move to Folder…, made in turn, are "
                + "taken back by ⌘Z newest first, the move, the keyword, then the rating, and made again by ⇧⌘Z in the "
                + "order they were made; a keyword typed then reaches the photo the move's Undo brought back",
            claims: [.action(.undo), .action(.redo)],
        ) { app in
            let scratch = try RenameScratch(app)
            defer { scratch.remove(app) }
            try scratch.show(app)
            try app.main { model in
                model.rightPanelVisible = true
                if !model.libraryPanels.isExpanded(.keywording) {
                    model.libraryPanels.toggle(.keywording)
                }
            }
            try app.wait("the keyword list", timeout: 30) { $0.libraryPanels.keywordList != nil }
            // The column slides in.
            app.pause(0.6)
            let (rated, moved) = (scratch.names[2], scratch.names[3])
            let keyword = "E2E Order \(UUID().uuidString.prefix(6))"
            @MainActor func rating(_ model: EditorModel) -> Int? {
                model.items.first { $0.name == rated }?.metadata.rating
            }
            func written(_ name: String) -> PhotoMetadata? {
                SidecarStore(locator: .besidePhotos).load(for: scratch.folder.appending(path: name))?.metadata
            }
            func settled() throws {
                try app.run("the changes and their saves", timeout: 120) { model in
                    while model.isWritingCulling {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    await model.libraryPanels.written()
                    await model.filesMade()
                    await model.library.service?.settled()
                }
            }

            try app.click(.identifier("grid.\(rated)"))
            try app.wait("\(rated) alone") { $0.selectedPhotos.map(\.lastPathComponent) == [rated] }
            try app.press(.rating3)
            try app.wait("three stars on \(rated)") { rating($0) == 3 }
            try app.typeInField("keywording.entry", keyword)
            try app.wait("the keyword on \(rated)") { model in
                model.libraryPanels.selection.hasEverywhere(KeywordPath(keyword)!) == true
            }
            try app.click(.identifier("grid.\(moved)"))
            try app.wait("\(moved) alone") { $0.selectedPhotos.map(\.lastPathComponent) == [moved] }
            try app.main { _ in EditorModel.moveToFolderAnswer = scratch.picked }
            try app.choose(.moveToFolder)
            try app.wait("\(moved) in Picked", timeout: 60) { _ in scratch.photos(in: scratch.picked) == [moved] }
            try settled()
            try app.expect(written(rated)?.rating == 3, "\(rated)'s sidecar has its stars")
            try app.expect(written(rated)?.keywords == [keyword], "\(rated)'s sidecar has the keyword")

            try app.press(.undo)
            try settled()
            try app.wait("⌘Z to take back the move first", timeout: 30) { _ in
                scratch.photos(in: scratch.picked).isEmpty && scratch.photos().contains(moved)
            }
            try app.expect(written(rated)?.keywords == [keyword], "the keyword stays while the move goes back")
            try app.press(.undo)
            try settled()
            try app.wait("⌘Z to take back the keyword next", timeout: 30) { model in
                (written(rated)?.keywords ?? []).isEmpty && rating(model) == 3
            }
            try app.press(.undo)
            try settled()
            try app.wait("⌘Z to take back the stars last", timeout: 30) { rating($0) == 0 }

            // ⇧⌘Z, as the driver reaches a ⌘ key with ⇧: its menu item carrying it.
            try app.expectKeyBinding(.redo)
            try app.choose(.redo)
            try settled()
            try app.wait("⇧⌘Z to give the stars back first", timeout: 30) { model in
                rating(model) == 3 && (written(rated)?.keywords ?? []).isEmpty
            }
            try app.choose(.redo)
            try settled()
            try app.wait("⇧⌘Z to put the keyword back next", timeout: 30) { _ in
                written(rated)?.keywords == [keyword] && scratch.photos(in: scratch.picked).isEmpty
            }
            try app.choose(.redo)
            try settled()
            try app.wait("⇧⌘Z to move the photo again last", timeout: 30) { _ in
                scratch.photos(in: scratch.picked) == [moved]
            }

            // The photo the move's Undo brings back, selected, takes a keyword typed in the panel.
            try app.press(.undo)
            try settled()
            try app.wait("\(moved) back and selected", timeout: 30) { model in
                scratch.photos().contains(moved) && model.selectedPhotos.map(\.lastPathComponent) == [moved]
            }
            try app.wait("the panel on \(moved)", timeout: 30) { $0.libraryPanels.selection.ids.count == 1 }
            try app.typeInField("keywording.entry", keyword + " Back")
            try settled()
            try app.wait("the keyword on \(moved)'s sidecar", timeout: 30) { _ in
                written(moved)?.keywords == [keyword + " Back"]
            }
        }

        static let performance = Scenario(
            "library.rename-performance",
            "Rename Photos' preview of 10,000 photos following each key of a template typed, then 1,000 raws renamed, "
                + "moved to a folder and each taken back, the main thread watched throughout",
            tiers: [.performance], claims: [],
        ) { app in
            var started = Date()
            let scratch = try RenamePerformanceScratch(app)
            defer { scratch.remove(app) }
            app.record("e2e-rename-copies-seconds", Date().timeIntervalSince(started))
            started = Date()
            try scratch.show(scratch.big, count: RenamePerformanceScratch.previewed, app)
            app.record("e2e-rename-indexed-10000-seconds", Date().timeIntervalSince(started))
            try app.choose(.selectAllPhotos)
            try app.wait("every photo selected") { $0.selectedPhotos.count == RenamePerformanceScratch.previewed }
            try app.pressF2()
            try app.waitForSheet("Rename Photos")
            try app.wait("10,000 photos read and named", timeout: 300) { $0.renameSheetFollows }
            try app.selectSheetField()
            let template = "Wedding-{date:yyyyMMdd}-{sequence:5}"
            var latencies: [Double] = []
            let typing = try app.watchingMainThread("typing") {
                for end in template.indices {
                    let typed = String(template[...end])
                    let started = Date()
                    try app.typeInAttachedSheet(String(template[end]))
                    try app.wait("the names to follow \(typed)", timeout: 10) { model in
                        model.renameSheetTemplate == typed && model.renameSheetFollows
                    }
                    latencies.append(Date().timeIntervalSince(started) * 1000)
                    app.pause(0.05)
                }
            }
            try app.pressInSheet(KeyCombo(.escape))
            try app.waitForNoSheet("Rename Photos")

            started = Date()
            try scratch.show(scratch.thousand, count: RenamePerformanceScratch.renamed, app)
            app.record("e2e-rename-indexed-1000-seconds", Date().timeIntervalSince(started))
            try app.choose(.selectAllPhotos)
            try app.wait("every photo selected") { $0.selectedPhotos.count == RenamePerformanceScratch.renamed }
            try app.pressF2()
            try app.waitForSheet("Rename Photos")
            try app.wait("1,000 photos read and named", timeout: 120) { $0.renameSheetFollows }
            try app.selectSheetField()
            try app.typeInAttachedSheet("Trip-")
            try app.chooseToken("{sequence:4:folder}")
            try app.wait("the names to follow the template", timeout: 30) { model in
                model.renameSheetTemplate == "Trip-{sequence:4:folder}" && model.renameSheetFollows
            }
            // From Rename to the batch made, its progress on screen; the sheet's closing is AppKit's.
            let made = try app.main { $0.fileUndoCount }
            let renaming = try app.watchingMainThread("rename") {
                try app.clickInSheet("rename.rename")
                try app.wait("the rename to be asked for", timeout: 900) { $0.fileUndoCount > made }
                try app.run("the rename to be made", timeout: 900) { await $0.filesMade() }
            }
            try app.waitForNoSheet("Rename Photos", timeout: 60)
            try app.expect(
                scratch.photos(in: scratch.thousand).allSatisfy { $0.hasPrefix("Trip-") },
                "Not every photo renamed",
            )
            let undoRename = try app.watchingMainThread("rename-undo") {
                try app.press(.undo)
                try app.run("the rename's Undo", timeout: 900) { await $0.filesMade() }
            }
            try app.expect(
                scratch.photos(in: scratch.thousand).allSatisfy { $0.hasPrefix("IMG_") },
                "Not every name back",
            )

            if try app.main({ $0.selectedPhotos.count }) < RenamePerformanceScratch.renamed {
                try app.choose(.selectAllPhotos)
            }
            try app.wait("every photo selected") { $0.selectedPhotos.count == RenamePerformanceScratch.renamed }
            try app.main { _ in EditorModel.moveToFolderAnswer = scratch.moved }
            let moves = try app.main { $0.fileUndoCount }
            let mark = try app.mark()
            let moving = try app.watchingMainThread("move") {
                try app.choose(.moveToFolder)
                try app.explainingFiles(since: mark) {
                    try app.wait("the move to be asked for", timeout: 900) { $0.fileUndoCount > moves }
                    try app.run("the photos moved", timeout: 900) { await $0.filesMade() }
                }
            }
            try app.waitForNoSheet("the move's progress", timeout: 60)
            try app.expect(
                scratch.photos(in: scratch.moved).count == RenamePerformanceScratch.renamed, "Not every photo moved",
            )
            let undoMove = try app.watchingMainThread("move-undo") {
                try app.press(.undo)
                try app.run("the move's Undo", timeout: 900) { await $0.filesMade() }
            }
            try app.expect(scratch.photos(in: scratch.moved).isEmpty, "Not every photo moved back")

            latencies.sort()
            let keyP95 = latencies.isEmpty ? -1 : latencies[min(latencies.count - 1, latencies.count * 95 / 100)]
            let phases = [
                ("typing", typing), ("rename", renaming), ("rename-undo", undoRename), ("move", moving),
                ("move-undo", undoMove),
            ]
            for (name, phase) in phases {
                if let summary = phase.summary {
                    app.record("e2e-rename-\(name)-p99", summary.p99)
                }
                app.record("e2e-rename-\(name)-seconds", phase.seconds)
            }
            app.record("e2e-rename-typing-key-p95", keyP95)
            var lines = [String(
                format: "names following a key (10,000 photos, %d keys): p95 %.0f ms",
                latencies.count,
                keyP95,
            )]
            for (name, phase) in phases {
                lines.append(String(
                    format: "%@: %.1f s, main thread p99 %.2f ms, max %.1f ms, over a frame %d", name, phase.seconds,
                    phase.summary?.p99 ?? -1, phase.summary?.max ?? -1, phase.summary?.overFrame ?? -1,
                ))
            }
            try? (lines.joined(separator: "\n") + "\n").write(
                to: app.runDirectory.appending(path: "rename-performance.txt"), atomically: true, encoding: .utf8,
            )
        }
    }

    /// A folder of copies of the run's photos below the run's folder: three raws as IMG_0001 to IMG_0003, the first
    /// beside a JPEG of its name that has a sidecar, and Picked, an empty folder to move them to.
    struct RenameScratch: Sendable {
        let root: URL
        let folder: URL
        let picked: URL
        /// The photos, in the grid's order.
        let names: [String]

        init(_ app: RunningApp) throws {
            root = app.runDirectory.appending(path: "rename-\(UUID().uuidString)", directoryHint: .isDirectory)
            folder = root.appending(path: "Photos", directoryHint: .isDirectory)
            picked = folder.appending(path: "Picked", directoryHint: .isDirectory)
            let raws = ["arw", "raf", "cr3", "nef", "dng"]
            let originals = try FileManager.default.contentsOfDirectory(atPath: app.photos.path)
                .filter { raws.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
            guard originals.count >= 3 else { throw ScenarioFailure("The run has \(originals.count) raws to copy") }
            try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
            var names: [String] = []
            for (number, original) in originals.prefix(3).enumerated() {
                let name = String(format: "IMG_%04d.", number + 1) + (original as NSString).pathExtension
                try FileManager.default.copyItem(
                    at: app.photos.appending(path: original),
                    to: folder.appending(path: name),
                )
                names.append(name)
            }
            let jpeg = folder.appending(path: "IMG_0001.JPG")
            try FileManager.default.copyItem(at: app.photos.appending(path: "Bitmap.jpg"), to: jpeg)
            try SidecarStore(locator: .besidePhotos).save(
                Sidecar(recipe: EditRecipe(), metadata: PhotoMetadata(rating: 2)), for: jpeg,
            )
            self.names = (names + ["IMG_0001.JPG"]).sorted(by: FileOrder.precedes)
        }

        /// Adds the folder to Folders and shows it in Library's grid, from the library.
        func show(_ app: RunningApp) throws {
            let (folder, count) = (folder, names.count)
            if try app.main({ $0.module != .develop }) {
                try app.press(.developModule)
            }
            try app.main { $0.open([folder]) }
            try app.wait("the folder indexed and shown from the library", timeout: 180) { model in
                model.folder?.standardizedFileURL == folder.standardizedFileURL && model.library.isShownFromLibrary
                    && model.items.count == count
            }
            try app.settle()
            try app.press(.gridView)
            try app.wait("the grid to take the keyboard") { _ in
                Views.editorWindow?.firstResponder.map { "\(Swift.type(of: $0))" } == "LibraryGridContentView"
            }
            try app.wait("the grid's cells") { _ in
                Views.editorWindow.flatMap { Views.find("grid.IMG_0001.JPG", in: $0) } != nil
            }
        }

        /// The photos in `folder` (the scratch's own by default), without their sidecars, sorted.
        func photos(in folder: URL? = nil) -> [String] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: (folder ?? self.folder).path)) ?? []
            return names.filter { name in
                let ext = (name as NSString).pathExtension.lowercased()
                return !["redlamp", "xmp", ""].contains(ext)
            }.sorted()
        }

        func hasSidecar(_ name: String) -> Bool {
            hasSidecar(name, in: folder)
        }

        func hasSidecar(_ name: String, in folder: URL) -> Bool {
            FileManager.default.fileExists(atPath: folder.appending(path: name + ".redlamp").path)
        }

        /// Takes the folder out of Folders and away, and opens the run's working photo again.
        func remove(_ app: RunningApp) {
            let folder = folder
            try? app.main { model in
                EditorModel.moveToFolderAnswer = nil
                ImportWindowController.forget(folder, in: model)
            }
            try? FileManager.default.removeItem(at: root)
            try? app.openWorking()
        }
    }

    /// Copies for the performance tier, in a folder of their own where `REDLAMP_PERF_SCRATCH` says (the run's folder
    /// by default): 10,000 of a JPEG in Big, and 1,000 raws in Thousand, with Moved, an empty folder, in it. Each copy
    /// is a clone of one copied once to that volume, ending in bytes of its own so each has its own content key.
    struct RenamePerformanceScratch: Sendable {
        static let previewed = 10000
        static let renamed = 1000

        let root: URL
        let big: URL
        let thousand: URL
        let moved: URL

        init(_ app: RunningApp) throws {
            let base = ProcessInfo.processInfo.environment["REDLAMP_PERF_SCRATCH"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? app.runDirectory
            root = base.appending(path: "rename-performance-\(UUID().uuidString)", directoryHint: .isDirectory)
            big = root.appending(path: "Big", directoryHint: .isDirectory)
            thousand = root.appending(path: "Thousand", directoryHint: .isDirectory)
            moved = thousand.appending(path: "Moved", directoryHint: .isDirectory)
            let sources = root.appending(path: "_sources", directoryHint: .isDirectory)
            let manager = FileManager.default
            for folder in [sources, big, moved] {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let raws = try manager.contentsOfDirectory(atPath: app.photos.path)
                .filter { ["arw", "raf", "cr3", "nef", "dng"].contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted()
            guard !raws.isEmpty else { throw ScenarioFailure("The run has no raws to copy") }
            for name in raws + ["Bitmap.jpg"] {
                try manager.copyItem(at: app.photos.appending(path: name), to: sources.appending(path: name))
            }
            for number in 0 ..< Self.previewed {
                try Self.clone(
                    sources.appending(path: "Bitmap.jpg"),
                    to: big.appending(path: String(format: "IMG_%05d.JPG", number + 1)), ending: number,
                )
            }
            for number in 0 ..< Self.renamed {
                let raw = raws[number % raws.count]
                try Self.clone(
                    sources.appending(path: raw),
                    to: thousand
                        .appending(path: String(format: "IMG_%04d.", number + 1) + (raw as NSString).pathExtension),
                    ending: number,
                )
            }
        }

        /// A clone of `source` at `copy`, ending in a box of its own length.
        private static func clone(_ source: URL, to copy: URL, ending number: Int) throws {
            try FileManager.default.copyItem(at: source, to: copy)
            let handle = try FileHandle(forWritingTo: copy)
            try handle.seekToEnd()
            let length = 16 + number
            var box = Data([
                UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF),
            ])
            box.append(contentsOf: Array("free".utf8))
            box.append(Data(count: length - 8))
            try handle.write(contentsOf: box)
            try handle.close()
        }

        /// Adds `folder` to Folders and shows its `count` photos in Library's grid, from the library.
        func show(_ folder: URL, count: Int, _ app: RunningApp) throws {
            if try app.main({ $0.module != .develop }) {
                try app.press(.developModule)
            }
            try app.main { $0.open([folder]) }
            try app.wait("\(count) photos indexed and shown from the library", timeout: 1200) { model in
                model.folder?.standardizedFileURL == folder.standardizedFileURL && model.library.isShownFromLibrary
                    && model.items.count == count
            }
            try app.settle(timeout: 120)
            try app.press(.gridView)
            try app.wait("the grid to take the keyboard") { _ in
                Views.editorWindow?.firstResponder.map { "\(Swift.type(of: $0))" } == "LibraryGridContentView"
            }
        }

        func photos(in folder: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { name in
                !["redlamp", "xmp", ""].contains((name as NSString).pathExtension.lowercased())
            }
        }

        /// Takes the folders out of Folders and away, and opens the run's working photo again.
        func remove(_ app: RunningApp) {
            let (big, thousand) = (big, thousand)
            try? app.main { model in
                EditorModel.moveToFolderAnswer = nil
                ImportWindowController.forget(big, in: model)
                ImportWindowController.forget(thousand, in: model)
            }
            try? FileManager.default.removeItem(at: root)
            try? app.openWorking()
        }
    }

    extension RunningApp {
        /// Runs `body` with the main thread watched: its run loop's turns, and how long `body` took. The menu bar's
        /// rebuilds meanwhile go in the run's `menu-bar.txt`.
        func watchingMainThread(
            _ name: String = "", _ body: () throws -> Void,
        ) throws -> (summary: MainThreadMonitor.Summary?, seconds: Double) {
            let monitor = try MainThread.run { () -> MainThreadMonitorBox in
                let monitor = MainThreadMonitor()
                monitor.start()
                return MainThreadMonitorBox(monitor)
            }
            let menus = try menuMark()
            let started = Date()
            defer { try? MainThread.run { monitor.monitor.stop() } }
            try body()
            let seconds = Date().timeIntervalSince(started)
            noteMenus(name, since: menus)
            let summary = try MainThread.run { () -> MainThreadMonitor.Summary? in
                monitor.monitor.stop()
                return monitor.monitor.summary(seconds: seconds)
            }
            return (summary, seconds)
        }

        /// Runs `body`, saying in its failure what the activity log reported since `mark` and how the file steps stood.
        func explainingFiles(since mark: Mark, _ body: () throws -> Void) throws {
            do {
                try body()
            } catch {
                let logged = (try? activity(since: mark).map(\.text).suffix(8).joined(separator: "; ")) ?? ""
                let state = try main { model in
                    "\(model.fileUndoCount) on Undo, sheet \(Views.editorWindow?.attachedSheet?.title ?? "none"), "
                        + "dialog \(model.isModalDialogOpen), \(model.selectedPhotos.count) selected"
                }
                throw ScenarioFailure("\(error) (\(state); logged: \(logged))")
            }
        }

        /// Runs `body`, saying in its failure how the editor stood for Rename Photos.
        func explaining(_ body: () throws -> Void) throws {
            do {
                try body()
            } catch {
                let state = try main { model in
                    "module \(model.module), active \(model.selection?.lastPathComponent ?? "none"), "
                        + "\(model.selectedPhotos.count) selected, dialog \(model.isModalDialogOpen), "
                        + "library ready \(model.library.service?.isReady == true), "
                        + "Rename Photos available \(model.canPerform(.renamePhotos)), "
                        + "sheet \(Views.editorWindow?.attachedSheet?.title ?? "none"), "
                        + "key window \(NSApp.keyWindow?.title ?? "none"), menu items "
                        + (NSApp.mainMenu?.items ?? []).compactMap { top -> String? in
                            guard let menu = top.submenu else { return nil }
                            Menus.open(menu)
                            defer { Menus.close(menu) }
                            let items = menu.items.filter { $0.title.hasPrefix("Rename Photos") }
                            return items.isEmpty ? nil : items.map { item in
                                "\(top.title) › \(item.title) enabled \(item.isEnabled) action "
                                    + "\(item.action.map(NSStringFromSelector) ?? "none") target \(item.target.map { "\(Swift.type(of: $0))" } ?? "none")"
                            }.joined(separator: "; ")
                        }.joined(separator: "; ")
                }
                throw ScenarioFailure("\(error) (\(state))")
            }
        }

        /// F2, as the keyboard sends it: through the app's event dispatch to the key monitor.
        func pressF2() throws {
            let mark = try mark()
            post { _ in
                let key = String(UnicodeScalar(NSF2FunctionKey)!)
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.function],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: EditorWindowController.frontWindow?.windowNumber ?? 0, context: nil,
                    characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: UInt16(kVK_F2),
                ) else { return }
                NSApp.sendEvent(event)
            }
            try expectPerformed(.renamePhotos, since: mark)
        }

        /// Selects all of the text in the sheet's field that has the keyboard, as ⌘A does.
        func selectSheetField() throws {
            try main { _ in
                guard let editor = Views.editorWindow?.attachedSheet?.firstResponder as? NSTextView else {
                    throw ScenarioFailure("No field in the sheet has the keyboard")
                }
                editor.selectAll(nil)
            }
        }

        /// Types `text` in the sheet, a key at a time, through the sheet's window; a character this keyboard
        /// layout types with other keys goes in as the text system puts it in.
        func typeInAttachedSheet(_ text: String) throws {
            for character in text {
                try main { _ in
                    guard let sheet = Views.editorWindow?.attachedSheet else { throw ScenarioFailure("No sheet is up") }
                    let lower = Character(character.lowercased())
                    guard character.isLetter || character.isNumber || character == "-", Keyboard.hasKey(for: lower)
                    else {
                        let editor = sheet.firstResponder as? NSTextView
                        editor?.insertText(String(character), replacementRange: editor?.selectedRange() ?? NSRange())
                        return
                    }
                    let typed = try Keyboard.event(KeyCombo(.character(lower), shift: character.isUppercase))
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: typed.modifierFlags, timestamp: typed.timestamp,
                        windowNumber: sheet.windowNumber, context: nil, characters: typed.characters ?? "",
                        charactersIgnoringModifiers: typed.charactersIgnoringModifiers ?? "", isARepeat: false,
                        keyCode: typed.keyCode,
                    ) else { return }
                    sheet.sendEvent(event)
                }
                pause(0.03)
            }
        }

        /// Clicks the control carrying `identifier` in the sheet, through the sheet's window, as the mouse does.
        func clickInSheet(_ identifier: String) throws {
            let location = try main { _ -> NSPoint in
                guard let sheet = Views.editorWindow?.attachedSheet, let control = Self.view(
                    identifier,
                    in: sheet.contentView,
                )
                else { throw ScenarioFailure("\(identifier) isn't in the sheet") }
                let frame = control.convert(control.bounds, to: nil)
                return NSPoint(x: frame.midX, y: frame.midY)
            }
            post { _ in
                guard let sheet = Views.editorWindow?.attachedSheet else { return }
                let events = [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap { type in
                    NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1,
                    )
                }
                guard events.count == 2 else { return }
                // The button tracks the press, and takes the release from the queue as the mouse's.
                NSApp.postEvent(events[1], atStart: false)
                sheet.sendEvent(events[0])
            }
            pause(0.2)
        }

        /// Chooses `token` in the sheet's Insert Token menu, as a click on its item does.
        func chooseToken(_ token: String) throws {
            try main { _ in
                guard let sheet = Views.editorWindow?.attachedSheet,
                      let button = Self.view("rename.template.tokens", in: sheet.contentView) as? NSPopUpButton,
                      let (menu, index) = Self.item("rename.template.token.\(token)", in: button.menu)
                else { throw ScenarioFailure("The Insert Token menu has no \(token)") }
                menu.performActionForItem(at: index)
            }
            pause(0.1)
        }

        @MainActor private static func view(_ identifier: String, in view: NSView?) -> NSView? {
            guard let view else { return nil }
            if view.accessibilityIdentifier() == identifier {
                return view
            }
            return view.subviews.lazy.compactMap { Self.view(identifier, in: $0) }.first
        }

        @MainActor private static func item(_ identifier: String, in menu: NSMenu?) -> (NSMenu, Int)? {
            guard let menu else { return nil }
            for (index, item) in menu.items.enumerated() {
                if item.accessibilityIdentifier() == identifier {
                    return (menu, index)
                }
                if let found = Self.item(identifier, in: item.submenu) {
                    return found
                }
            }
            return nil
        }
    }
#endif
